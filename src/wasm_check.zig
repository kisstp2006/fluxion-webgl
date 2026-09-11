// SPDX-License-Identifier: BSL-1.0

//! Every call in the library, compiled for the target it exists for.
//!
//! `zig build test` builds this for `wasm32-freestanding` and never runs it.
//! The suite itself runs on the host, against `stub`, and Zig analyses a
//! function only when something calls it - so on its own the suite compiles
//! the wasm half of `Context` not at all, and the examples compile only the
//! calls they draw with. A call that does not compile against the real
//! imports, or one nothing has called yet, would otherwise be found by the
//! first program that tried it.
//!
//! So this calls all of them. Not from a list: `callAll` walks `Context` and
//! `host` at compile time, and a call added tomorrow is compiled here without
//! anybody remembering to add it. The arguments are `undefined`, which is all
//! a compiler checking types needs and all a function nothing will ever run
//! deserves. Taking each function's address would not do: most of `Context`
//! is `inline`, and an inline function has no address, only call sites.
//!
//! A generic function cannot be called without choosing what to call it with,
//! so those few are called by hand at the bottom - and a new one is a compile
//! error here until it is added there too.

const std = @import("std");
const webgl = @import("root.zig");

const c = webgl.enums;

export fn callEverything() void {
    callAll(webgl.Context, &.{ "bufferData", "bufferSubData" });
    callAll(webgl.host, &.{"logFn"});

    // The generic ones, with what a program would hand them.
    const gl: webgl.Context = .init();
    gl.bufferData(c.array_buffer, &[_]f32{ 0, 1 }, c.static_draw);
    gl.bufferSubData(c.array_buffer, 4, &[_]u16{ 0, 1 });
    webgl.host.logFn(.info, .default, "{d}", .{1});

    // And the panic handler, last, because it does not come back.
    webgl.host.panic.call("unreachable", null);
}

/// Call every public function in `Namespace`, except the generic ones named
/// in `by_hand`, which `callEverything` calls itself.
fn callAll(comptime Namespace: type, comptime by_hand: []const []const u8) void {
    inline for (@typeInfo(Namespace).@"struct".decls) |decl| {
        const function = @field(Namespace, decl.name);
        const info = switch (@typeInfo(@TypeOf(function))) {
            .@"fn" => |f| f,
            else => continue,
        };

        if (info.is_generic) {
            if (!comptime isOneOf(decl.name, by_hand)) @compileError(@typeName(Namespace) ++ "." ++ decl.name ++
                " is generic: call it by hand in `callEverything`, with the types a program would");
            continue;
        }

        // A `var`, so the arguments are run-time values: a comptime-known
        // `undefined` would be caught the first time a body branched on it.
        var args: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
        _ = &args;
        if (@typeInfo(info.return_type.?) == .error_union) {
            _ = @call(.auto, function, args) catch {};
        } else {
            _ = @call(.auto, function, args);
        }
    }
}

fn isOneOf(comptime name: []const u8, comptime names: []const []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}
