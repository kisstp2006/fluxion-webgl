// SPDX-License-Identifier: BSL-1.0

//! Which WebGL this build is talking to, decided at compile time.
//!
//! A wasm build gets `imports`, and every call is a WebAssembly import the
//! browser has to supply. Everything else gets `stub`, and every call is
//! ordinary Zig that records what it was told. There is no run-time branch
//! and no function pointer: `raw` is a *type*, chosen by the target, and the
//! calls through it inline exactly as if the other module did not exist.
//!
//! That is Zig's answer to a `#ifdef`, and it is worth being precise about
//! how it differs. A preprocessor deletes the branch it does not take before
//! the compiler ever sees it, so the unused half rots - it stops parsing,
//! then it stops compiling, and nobody finds out until somebody builds for
//! that target. Here both files are always parsed and always syntax-checked.
//! Only the *bodies* of the branch not taken go unanalysed.
//!
//! ```zig
//! const api = @import("api.zig");
//! api.raw.clear(c.color_buffer_bit);   // an import in a browser, a counter here
//! ```
//!
//! ## Why the branch is written the long way
//!
//! `imports` is reached through `if (is_wasm)` and never named outside it,
//! and that is load-bearing rather than tidy. `extern "webgl" fn` says two
//! different things depending on who is reading it. To the wasm backend it
//! names the *import module* - the key the browser hangs its functions off in
//! `WebAssembly.instantiate`. To every other backend it names a *library to
//! link against*, and on Windows that is `webgl.dll`, which does not exist.
//!
//! Analysing those declarations at all is enough to put `-lwebgl` on the link
//! line, whether or not anything calls them - so a host build must never look
//! inside that file, not even to read a type off it. An untaken comptime
//! branch is never analysed, which is exactly the tool for the job, and it is
//! why `verify` below is inside one too.
//!
//! Nothing outside this library should call `raw` directly. `Context` is the
//! same calls with slices, error unions and typed objects; this is the seam.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// The declarations that stand in for the browser everywhere else. See
/// `stub`. Always safe to name: it is ordinary Zig.
pub const stub = @import("stub.zig");

/// Whether this build talks to a real WebGL context.
///
/// `wasm32-freestanding` and `wasm32-wasi` both reach a browser through the
/// same import mechanism, so the architecture settles it and the OS does not.
pub const is_wasm = switch (builtin.target.cpu.arch) {
    .wasm32, .wasm64 => true,
    else => false,
};

/// The WebGL calls, whichever kind this build has.
///
/// On wasm this is `imports.zig` and every call leaves the module. Everywhere
/// else it is `stub.zig` and every call is a counter.
pub const raw = if (is_wasm) @import("imports.zig") else stub;

// -------------------------------------------------------------------------
// Keeping the two in step
// -------------------------------------------------------------------------

/// Check that `stub` implements every declaration `imports.zig` asks for,
/// with the same parameters and the same result.
///
/// The two files are written out by hand, so they can drift - and the drift
/// would otherwise be invisible, because a wasm build never compiles `stub`
/// and a host build never compiles the imports. A signature changed on one
/// side alone would be found by a browser, at run time, as an argument of the
/// wrong type quietly coerced to another.
///
/// This walks the declarations at compile time and compares each one against
/// the same name in `stub`. A mismatch is a compile error naming the
/// function; a match costs nothing, because there is no run time for it to
/// cost.
///
/// It can only run where the imports can be looked at, which is a wasm build
/// - see the note above about `-lwebgl`. That is not the hole it sounds like:
/// `zig build test` builds `wasm_check.zig` for `wasm32-freestanding` as one
/// of its steps precisely so that this runs, and so that every call is
/// compiled for the target it exists for rather than merely parsed.
///
/// Calling convention is deliberately not compared. An `extern` declaration
/// is `callconv(.c)` and a Zig function is `callconv(.auto)`, and they should
/// be: the point of the stub is that it is not going through a foreign ABI.
/// What has to match is the shape - what goes in and what comes back.
pub fn verify() void {
    if (!is_wasm) return;

    comptime {
        const imports = @import("imports.zig");

        for (@typeInfo(imports).@"struct".decls) |decl| {
            if (!@hasDecl(stub, decl.name)) {
                @compileError("stub is missing '" ++ decl.name ++ "', which imports declares");
            }

            const wanted = @typeInfo(@TypeOf(@field(imports, decl.name))).@"fn";
            const given = @typeInfo(@TypeOf(@field(stub, decl.name))).@"fn";

            if (wanted.params.len != given.params.len) {
                @compileError("stub." ++ decl.name ++ " takes the wrong number of arguments");
            }
            if (wanted.return_type != given.return_type) {
                @compileError("stub." ++ decl.name ++ " returns the wrong type");
            }
            for (wanted.params, given.params, 0..) |want, got, i| {
                if (want.type != got.type) {
                    @compileError(std.fmt.comptimePrint(
                        "stub.{s} argument {d} is the wrong type",
                        .{ decl.name, i },
                    ));
                }
            }
        }
    }
}

test "the choice is the target's, and it is made in the compiler" {
    // On the machine running these tests it is the stub, and `raw` is a type
    // rather than a value - so this comparison happens at compile time.
    try testing.expect(!is_wasm);
    try testing.expectEqual(stub, raw);

    // The check is a no-op here and a comparison there; calling it costs a
    // compile error or nothing.
    verify();

    // And the calls go through under whichever name.
    raw.reset();
    defer raw.reset();
    raw.clearColor(0.25, 0.5, 0.75, 1);
    try testing.expectEqual(@as(f32, 0.5), stub.state.last_clear_color[1]);
}
