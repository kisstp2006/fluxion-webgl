// SPDX-License-Identifier: BSL-1.0

//! The smallest thing that draws: one triangle, three colours, no matrices.
//!
//! Everything a WebGL program has to do, once each, with nothing else in the
//! way - a shader pair, a vertex buffer, an attribute layout, a draw. If the
//! cube is not working, this is the file to get running first.
//!
//! It has no matrices, and that is visible: the triangle stretches with the
//! window, because the positions below are already in clip space and clip
//! space is square whatever shape the canvas is. Fixing that is what a
//! projection matrix is *for*, and `cube.zig` is the same program with one.
//!
//! It is also the shape every wasm module takes, and that shape is worth
//! naming because it is not the shape of a program that has a `main`:
//!
//!   * **The exports are the entry points.** `init` and `frame` are called by
//!     the page, in that order, whenever the page decides. Nothing here runs
//!     on its own.
//!   * **The state is global.** A `main` would own it on its stack and pass a
//!     pointer around, but there is no `main` and no stack that lives between
//!     two calls from JavaScript. A module-scope `var` is the honest way to
//!     say "this lasts as long as the page does".
//!   * **Nothing allocates.** The geometry is comptime-known, the shaders are
//!     string literals, and the one buffer is the shader log.

const std = @import("std");
const webgl = @import("fluxion_webgl");

const c = webgl.enums;

/// Send `std.log` to the browser console. Without this line the module still
/// builds and `std.log.info` goes nowhere.
pub const std_options: std.Options = .{ .logFn = webgl.host.logFn };

/// Say what happened before trapping.
///
/// Guarded, because this file is also compiled for the host by
/// `zig build test`, and there the test runner's own panic handler is the one
/// that prints the failure and the stack. Overriding it would trade a useful
/// message for `@trap`.
pub const panic = if (webgl.is_wasm)
    webgl.host.panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

/// One corner: where it is, and what colour it is.
///
/// `extern` so the field order is the one written here. A plain Zig struct
/// may be reordered by the compiler, and the offsets below - 0 for the
/// position, 8 for the colour - would then be describing a layout that is not
/// there. This is the bug that draws a triangle with the colours in the
/// vertex positions.
const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
};

const triangle = [_]Vertex{
    .{ .x = 0.0, .y = 0.6, .r = 1, .g = 0.2, .b = 0.3 },
    .{ .x = -0.6, .y = -0.5, .r = 0.2, .g = 0.9, .b = 0.4 },
    .{ .x = 0.6, .y = -0.5, .r = 0.3, .g = 0.5, .b = 1.0 },
};

const vertex_source =
    \\#version 300 es
    \\layout(location = 0) in vec2 a_position;
    \\layout(location = 1) in vec3 a_colour;
    \\out vec3 v_colour;
    \\void main() {
    \\    v_colour = a_colour;
    \\    gl_Position = vec4(a_position, 0.0, 1.0);
    \\}
;

const fragment_source =
    \\#version 300 es
    \\precision highp float;
    \\in vec3 v_colour;
    \\out vec4 o_colour;
    \\void main() {
    \\    o_colour = vec4(v_colour, 1.0);
    \\}
;

/// What lasts between calls from the page.
const State = struct {
    gl: webgl.Context,
    program: webgl.Program,
    vao: webgl.VertexArray,
    vbo: webgl.Buffer,
};

var state: State = undefined;

/// Build everything that does not change. Called once, from the page, after
/// the canvas and its context exist.
///
/// Answers `false` rather than trapping, so the page can put the reason on
/// screen instead of showing a blank canvas: a WebGL failure people can read
/// is worth more than a stack trace they cannot.
export fn init() bool {
    // Two kilobytes is more than any driver has ever needed to say what is
    // wrong on line 1. The buffer lives here rather than in `start` because
    // this is the function that decides what to do with what is in it.
    var log_text: [2048]u8 = undefined;
    var log: std.Io.Writer = .fixed(&log_text);

    start(&log) catch |err| {
        if (log.buffered().len > 0) std.log.err("{s}", .{log.buffered()});
        std.log.err("could not start: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

/// Everything `init` does, with the reporting left to the caller.
///
/// The split is worth the extra parameter: `start` says what went wrong by
/// returning an error and filling `log`, and `init` decides that the browser
/// console is where that goes. A test decides differently - see the bottom of
/// this file - and neither has to know about the other.
fn start(log: *std.Io.Writer) !void {
    const gl: webgl.Context = .init();
    std.log.info("{f}, up to {d}x{d} textures", .{ gl.version, gl.limits.max_texture_size, gl.limits.max_texture_size });

    const program = try gl.buildProgram(vertex_source, fragment_source, log);

    const vao = try gl.createVertexArray();
    const vbo = try gl.createBuffer();

    // The vertex array remembers all of this, so the frame does not have to.
    gl.bindVertexArray(vao);
    gl.bindBuffer(c.array_buffer, vbo);
    gl.bufferData(c.array_buffer, &triangle, c.static_draw);

    const stride = @sizeOf(Vertex);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, c.float, false, stride, @offsetOf(Vertex, "x"));
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 3, c.float, false, stride, @offsetOf(Vertex, "r"));

    state = .{ .gl = gl, .program = program, .vao = vao, .vbo = vbo };
}

/// Draw one frame. Called from `requestAnimationFrame`.
export fn frame() void {
    const gl = state.gl;

    // Read the size every frame rather than remembering it. The canvas
    // changes size when the window does, and the page has already resized the
    // drawing buffer by the time this runs.
    const size = webgl.canvasSize();
    gl.viewport(0, 0, size.width, size.height);

    gl.clearColor(0.07, 0.07, 0.09, 1);
    gl.clear(c.color_buffer_bit);

    gl.useProgram(state.program);
    gl.bindVertexArray(state.vao);
    gl.drawArrays(c.triangles, 0, triangle.len);
}

/// Give back what `init` made. The page calls this on `webglcontextlost`;
/// a page that never does is not leaking, because the objects die with it.
export fn deinit() void {
    const gl = state.gl;
    gl.deleteBuffer(state.vbo);
    gl.deleteVertexArray(state.vao);
    gl.deleteProgram(state.program);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const stub = webgl.stub;

test "the vertex layout is the one the attribute pointers describe" {
    // Five floats, in the order written, with the colour starting after the
    // position. If a future edit reorders the struct, this is what says so
    // rather than the picture going wrong in a browser.
    try testing.expectEqual(20, @sizeOf(Vertex));
    try testing.expectEqual(0, @offsetOf(Vertex, "x"));
    try testing.expectEqual(8, @offsetOf(Vertex, "r"));
}

test "init builds a program and a triangle, and frame draws it" {
    stub.reset();
    defer stub.reset();

    try testing.expect(init());

    // Three vertices of twenty bytes went over.
    try testing.expectEqual(60, stub.state.last_upload_len);

    frame();
    try testing.expectEqual(1, stub.state.draw_calls);
    try testing.expectEqual(c.triangles, stub.state.last_draw.mode);
    try testing.expectEqual(3, stub.state.last_draw.count);
    try testing.expectEqual(null, state.gl.checkError());

    // And everything made is given back.
    deinit();
}

test "a shader that will not compile is reported, not drawn with" {
    stub.reset();
    defer stub.reset();

    stub.state.fail_compile = true;

    // `start` rather than `init`. A line logged at error level is exactly how
    // Zig's test runner is told that a test failed, so calling the wrapper
    // whose job is to log one would fail this test for working correctly.
    // Taking the writer instead means the message is something to assert on.
    var log_text: [512]u8 = undefined;
    var log: std.Io.Writer = .fixed(&log_text);
    try testing.expectError(error.CompileFailed, start(&log));

    // The driver said which line, and the example said which stage.
    try testing.expect(std.mem.startsWith(u8, log.buffered(), "ERROR:"));
    try testing.expect(std.mem.endsWith(u8, log.buffered(), "(in the vertex shader)\n"));

    // And nothing was left behind by the attempt.
    try testing.expectEqual(0, stub.state.live_objects);
}
