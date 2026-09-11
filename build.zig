// SPDX-License-Identifier: BSL-1.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The importable module. Consumers do:
    //   const webgl = @import("fluxion_webgl");
    //
    // No imports of its own. See build.zig.zon for why a WebGL binding needs
    // no loader where a desktop one does.
    const mod = b.addModule("fluxion_webgl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-webgl-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // The tests above run on the host, against `src/stub.zig`, and so never
    // compile `src/imports.zig` at all - the whole point of that file is that
    // it only exists for one target. Nor, because Zig analyses a function only
    // when something calls it, do they compile one call in `Context` the way a
    // browser gets it. So the suite also *builds* for wasm32-freestanding,
    // without running anything.
    //
    // That is not a formality. What it builds is `src/wasm_check.zig`, which
    // calls every function in `Context` and `host`, so each is compiled
    // against the real imports - the ones nothing else calls yet included.
    // And compiling for wasm is what runs `api.verify`, which is what proves
    // the stub the tests just used has the same signatures as the browser
    // will be handed. A mismatch is a compile error here rather than an
    // argument silently coerced in somebody's tab.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_check = b.addLibrary(.{
        .name = "fluxion-webgl-wasm-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_check.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    test_step.dependOn(&wasm_check.step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-webgl",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // -------------------------------------------------------------------
    // Examples
    // -------------------------------------------------------------------

    // The example needs matrices, and those are not this library's business:
    // they are `fluxion-math`. A lazy dependency, so it is fetched only when
    // the examples are actually wanted - which is when this is the package
    // being built, not when it is somebody else's dependency.
    // `-Dexamples=false` builds the library and its tests alone.
    const examples_wanted = b.option(
        bool,
        "examples",
        "Build the examples (pulls fluxion-math)",
    ) orelse (b.pkg_hash.len == 0);
    if (!examples_wanted) return;

    // On the first run after a clean checkout this comes back null and the
    // build runner fetches it and starts again, so returning here is not
    // giving up - it is the first half of the fetch.
    const math_dep = b.lazyDependency("fluxion_math", .{
        .target = wasm_target,
        .optimize = optimize,
    }) orelse return;
    const math_mod = math_dep.module("fluxion_math");

    // Every example is one wasm module and the same two files of page around
    // it. The library is rebuilt for wasm here rather than reusing `mod`,
    // because `mod` was built for whatever `-Dtarget` said and a browser will
    // not take that.
    const webgl_wasm = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const examples = [_]struct {
        name: []const u8,
        step: []const u8,
        about: []const u8,
    }{
        .{
            .name = "cube",
            .step = "example-cube",
            .about = "3D: a lit, spinning cube with a depth buffer",
        },
        .{
            .name = "triangle",
            .step = "example-triangle",
            .about = "The smallest thing that draws: one triangle, no matrices",
        },
    };

    const all_examples = b.step("examples", "Build every example into zig-out/web");
    // `zig build example` is the one to start with, and for a library whose
    // output is a web page that means the one worth opening.
    const default_example = b.step("example", "Build the cube example into zig-out/web");

    for (examples) |example| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluxion_webgl", .module = webgl_wasm },
                .{ .name = "fluxion_math", .module = math_mod },
            },
        });

        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = example_mod,
        });

        // Three settings that turn a Zig executable into a wasm module a page
        // can instantiate, and all three are easy to leave out and hard to
        // diagnose afterwards.
        //
        //   `entry = .disabled` - there is no `main`. A browser calls the
        //   exports when it is ready, and a start function that ran before
        //   the page had a canvas would have nothing to draw into.
        //
        //   `rdynamic` - without it the `export fn`s are compiled and then
        //   dropped by the linker as unreachable, and `instance.exports` is
        //   empty for reasons the console does not explain.
        //
        //   `import_memory = false` - the module makes its own memory and
        //   hands it out. The glue reads strings from it, so it has to be
        //   reachable, and this is the direction that needs the least
        //   arranging on the JavaScript side.
        exe.entry = .disabled;
        exe.rdynamic = true;
        exe.import_memory = false;

        // Everything the page needs, in one directory: the module, the glue
        // that implements its imports, and an index.html to open.
        const install_wasm = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "web" } },
        });
        const install_page = b.addInstallDirectory(.{
            .source_dir = b.path("examples/web"),
            .install_dir = .prefix,
            .install_subdir = "web",
        });

        const step = b.step(example.step, example.about);
        step.dependOn(&install_wasm.step);
        step.dependOn(&install_page.step);

        all_examples.dependOn(step);
        if (std.mem.eql(u8, example.name, "cube")) default_example.dependOn(step);

        // The examples carry their own tests, and they run with the library's
        // - against the stub, on the host, where a browser is not needed to
        // find out whether the cube has eight corners and the matrix that
        // places them is finite.
        const host_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluxion_webgl", .module = mod },
                .{ .name = "fluxion_math", .module = b.lazyDependency("fluxion_math", .{
                    .target = target,
                    .optimize = optimize,
                }).?.module("fluxion_math") },
            },
        });
        const example_tests = b.addTest(.{
            .name = b.fmt("fluxion-webgl-{s}-tests", .{example.name}),
            .root_module = host_mod,
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);

        // And the module itself is built too, for the browser rather than the
        // host: tests that ran against the stub say nothing about whether the
        // example compiles for the one target it exists for.
        test_step.dependOn(&exe.step);
    }
}
