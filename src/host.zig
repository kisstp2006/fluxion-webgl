// SPDX-License-Identifier: BSL-1.0

//! The page: a clock, a canvas size, and somewhere for text to go.
//!
//! `wasm32-freestanding` is the most freestanding target Zig has. There is no
//! operating system beneath it, so there is no clock, no console, no files
//! and no stack trace - and that is not a gap in Zig's support, it is what
//! the target *is*. A wasm module is a set of functions and a block of
//! memory; everything else is something the host chose to hand it.
//!
//! So `std.time.milliTimestamp` will not link, `std.debug.print` has nowhere
//! to print, and an unhandled panic traps with no message at all. Each of
//! those has a one-line replacement here, and each is imported from the page
//! rather than provided by the standard library.
//!
//! ```zig
//! // Somewhere near the top of a program that runs in a browser:
//! pub const std_options: std.Options = .{ .logFn = webgl.host.logFn };
//! pub const panic = webgl.host.panic;
//! ```
//!
//! With those two lines, `std.log.info` reaches the browser console and a
//! failed `unreachable` prints its message before it traps. Without them the
//! first is a compile error and the second is silence.
//!
//! Off a wasm target the same declarations are ordinary Zig - the console is
//! stderr, the clock is a counter - so a program written against this builds
//! and runs on the desktop as well, which is what makes the tests below
//! possible.

const std = @import("std");
const testing = std.testing;

const api = @import("api.zig");

/// Where the page's answers come from: the browser on wasm, the operating
/// system everywhere else. Chosen the same way and for the same reason as
/// `api.raw` - see the note there about `extern "host"` naming an import
/// module on one target and a library to link against on every other.
const raw = if (api.is_wasm) @import("host_imports.zig") else struct {
    /// A fake 60 Hz clock: every call is one frame later than the last.
    ///
    /// Deliberately not a real clock. Zig 0.16 put the monotonic one behind
    /// `std.Io`, which would mean threading an `Io` through a stub whose
    /// whole purpose is to not be the real thing - and a test that animates
    /// wants a clock that gives the same answer twice anyway. A frame is
    /// exactly 16.667 ms here, for ever, which makes an animation test a
    /// matter of counting rather than of timing.
    var frame: f64 = 0;

    pub fn now() f64 {
        defer frame += 1;
        return frame * (1000.0 / 60.0);
    }

    pub fn canvasWidth() i32 {
        return 800;
    }

    pub fn canvasHeight() i32 {
        return 600;
    }

    pub fn consoleWrite(level: u32, ptr: [*]const u8, len: u32) void {
        _ = level;
        std.debug.print("{s}\n", .{ptr[0..len]});
    }
};

/// Milliseconds since the page loaded. Monotonic, sub-millisecond, and not
/// wall-clock time - there is no wall clock in a wasm module.
///
/// This is what an animation advances on. Take the difference between two
/// calls rather than the value itself: the number is large enough that
/// `f32` arithmetic on it loses precision within a minute of loading, which
/// is a bug that looks like the animation getting jerky and is not.
pub inline fn now() f64 {
    return raw.now();
}

/// The size of the drawing buffer, in device pixels.
///
/// Not the CSS size of the canvas element. On a display with a device pixel
/// ratio of two those differ by a factor of two, and the glue is what
/// reconciles them - it sets `canvas.width` from `clientWidth * dpr` when the
/// page resizes. A renderer that passes this straight to `viewport` gets
/// sharp output; one that uses the CSS size gets a blurry upscale.
pub fn canvasSize() struct { width: i32, height: i32 } {
    return .{ .width = raw.canvasWidth(), .height = raw.canvasHeight() };
}

/// How loudly to say something. The numbers are the wire format, and the glue
/// turns them into the four `console` methods.
pub const Level = enum(u32) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    fn from(level: std.log.Level) Level {
        return switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err => .err,
        };
    }
};

/// Write one line to the console.
pub fn write(level: Level, text: []const u8) void {
    raw.consoleWrite(@intFromEnum(level), text.ptr, @intCast(text.len));
}

/// The longest line this will format before truncating it. A fixed buffer,
/// because the alternative is an allocator and a log line is not worth one.
pub const line_limit = 1024;

/// A `std.log` backend that writes to the browser console.
///
/// Install it with:
///
/// ```zig
/// pub const std_options: std.Options = .{ .logFn = webgl.host.logFn };
/// ```
///
/// `std.log` is the right thing to route rather than `std.debug.print`,
/// because the levels and scopes survive: `std.log.scoped(.renderer).warn`
/// arrives as a `console.warn` with `(renderer)` in it, and the release-mode
/// filtering happens in Zig rather than in the browser.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    var text: [line_limit]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);

    // A line too long to format is still worth sending: `print` stops at the
    // end of the buffer and `buffered()` is what fitted. Dropping the whole
    // line because the tail did not fit would lose the part that says what
    // went wrong.
    w.writeAll(prefix) catch {};
    w.print(format, args) catch {};

    write(.from(level), w.buffered());
}

/// A panic handler that says what happened before it traps.
///
/// Install it with:
///
/// ```zig
/// pub const panic = webgl.host.panic;
/// ```
///
/// Without it, a panic in a wasm module executes `unreachable`, the browser
/// raises `RuntimeError: unreachable`, and the message - the whole reason
/// panics have messages - is never seen. There is no stack trace either way:
/// unwinding needs DWARF and a way to read its own memory as code, and
/// neither is available here.
pub const panic = std.debug.FullPanic(struct {
    fn handler(message: []const u8, first_trace_address: ?usize) noreturn {
        _ = first_trace_address;
        write(.err, "panic: ");
        write(.err, message);
        // `@trap` rather than a loop: the browser reports it as a
        // RuntimeError with a stack pointing at the wasm frame, and a spinning
        // module would take the tab down with it.
        @trap();
    }
}.handler);

test "the clock moves forwards and starts near zero" {
    const first = now();
    try testing.expect(first >= 0);
    try testing.expect(now() >= first);
}

test "the canvas has a size on either target" {
    const size = canvasSize();
    try testing.expect(size.width > 0);
    try testing.expect(size.height > 0);
}

test "log levels map onto the wire in the order the glue expects" {
    try testing.expectEqual(0, @intFromEnum(Level.debug));
    try testing.expectEqual(3, @intFromEnum(Level.err));
    try testing.expectEqual(Level.warn, Level.from(.warn));
}
