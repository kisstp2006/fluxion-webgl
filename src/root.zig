// SPDX-License-Identifier: BSL-1.0

//! Fluxion WebGL - WebGL 2, from Zig compiled to WebAssembly.
//!
//! Seven pieces:
//!
//!   `types`    the types WebGL is written in, and `Object`, which is the
//!              one that shapes everything else
//!   `enums`    the tokens the calls take
//!   `imports`  the calls, as WebAssembly imports the browser must supply
//!   `stub`     the same calls, implemented in Zig, for building and testing
//!              anywhere else
//!   `api`      which of those two this build is talking to
//!   `context`  the calls as Zig: slices, error unions, typed objects
//!   `host`     the page - a clock, a canvas size, a console, a panic handler
//!
//! ```zig
//! const webgl = @import("fluxion_webgl");
//! const c = webgl.enums;
//!
//! const gl: webgl.Context = .init();
//!
//! var log_text: [1024]u8 = undefined;
//! var log: std.Io.Writer = .fixed(&log_text);
//! const program = try gl.buildProgram(vertex_source, fragment_source, &log);
//!
//! gl.clearColor(0.1, 0.1, 0.12, 1);
//! gl.clear(c.color_buffer_bit | c.depth_buffer_bit);
//! gl.useProgram(program);
//! gl.drawArrays(c.triangles, 0, 3);
//! ```
//!
//! **There is no context creation here, and there will not be.** The canvas
//! and its `WebGLRenderingContext` are the page's, made in JavaScript before
//! the module was instantiated, and handed over as the imports this library
//! declares. `examples/web/fluxion-webgl.js` is a complete implementation of
//! them, in four hundred lines with no dependencies, and it is the only
//! JavaScript needed.
//! This library starts where that file ends - which is the same relationship
//! [Fluxion GL](https://github.com/kisstp2006/fluxion-gl) has with GLFW.
//!
//! **Nothing here allocates.** Info logs go to a writer the caller owns,
//! object names are integers, and the one buffer in the library is 2 KiB of
//! stack in `Context.writeLog`. A renderer built on this needs an allocator
//! for its own scene; the binding does not.
//!
//! **It builds for the desktop too**, against `stub`, and that is what makes
//! `zig build test` mean anything on a machine with no browser: the bindings
//! are compiled, the objects are counted, the error paths are taken, and the
//! matrices are checked to be the sixteen floats they claim to be. What a
//! stub cannot check is whether the picture is right, and `examples/web` is
//! where that goes.

const std = @import("std");
const testing = std.testing;

pub const api = @import("api.zig");
pub const context = @import("context.zig");
pub const enums = @import("enums.zig");
pub const host = @import("host.zig");
pub const stub = @import("stub.zig");
pub const types = @import("types.zig");

/// A WebGL context: what it is, and everything you can ask it to do. See
/// `context`.
pub const Context = context.Context;

/// What can go wrong that is worth stopping for. See `context`.
pub const Error = context.Error;

/// Which WebGL the page got. See `context`.
pub const Version = context.Version;

/// The numbers a renderer has to plan around. See `context`.
pub const Limits = context.Limits;

/// The constructor every object kind comes from - a function returning a
/// type, so `Buffer` and `Texture` are genuinely different types rather than
/// two names for `u32`. See `types.Object`.
pub const Object = types.Object;

pub const Buffer = types.Buffer;
pub const Framebuffer = types.Framebuffer;
pub const Program = types.Program;
pub const Renderbuffer = types.Renderbuffer;
pub const Shader = types.Shader;
pub const Texture = types.Texture;
pub const UniformLocation = types.UniformLocation;
pub const VertexArray = types.VertexArray;

/// Whether this build talks to a real WebGL context, or to `stub`. See `api`.
pub const is_wasm = api.is_wasm;

/// Milliseconds since the page loaded. See `host.now`.
pub const now = host.now;

/// The size of the drawing buffer, in device pixels. See `host.canvasSize`.
pub const canvasSize = host.canvasSize;

test {
    // Pull each module in so `zig build test` runs its tests too.
    _ = api;
    _ = context;
    _ = enums;
    _ = host;
    _ = stub;
    _ = types;

    // And check the imports against the stub. A no-op off wasm - see
    // `api.verify` for why, and for what runs it where it counts.
    api.verify();
}

const c = enums;

test "the pieces compose: a frame, from nothing to a draw" {
    stub.reset();
    defer stub.reset();

    // The page made the context; this is everything after that.
    const gl: Context = .init();
    try testing.expect(gl.version.atLeast(.webgl2));

    var log_text: [512]u8 = undefined;
    var log: std.Io.Writer = .fixed(&log_text);

    const program = try gl.buildProgram(
        \\#version 300 es
        \\layout(location = 0) in vec2 position;
        \\uniform mat4 mvp;
        \\void main() { gl_Position = mvp * vec4(position, 0.0, 1.0); }
    ,
        \\#version 300 es
        \\precision highp float;
        \\out vec4 colour;
        \\void main() { colour = vec4(1.0); }
    , &log);
    defer gl.deleteProgram(program);

    const mvp = gl.uniformLocation(program, "mvp");

    // One triangle, in a buffer, described once and drawn.
    const vertices = [_]f32{ -0.5, -0.5, 0.5, -0.5, 0.0, 0.5 };
    const vbo = try gl.createBuffer();
    defer gl.deleteBuffer(vbo);

    const vao = try gl.createVertexArray();
    defer gl.deleteVertexArray(vao);

    gl.bindVertexArray(vao);
    gl.bindBuffer(c.array_buffer, vbo);
    gl.bufferData(c.array_buffer, &vertices, c.static_draw);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, c.float, false, 8, 0);

    gl.viewport(0, 0, 800, 600);
    gl.clearColor(0.1, 0.1, 0.12, 1);
    gl.clear(c.color_buffer_bit | c.depth_buffer_bit);
    gl.useProgram(program);
    gl.uniformMatrix4(mvp, &[16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 });
    gl.drawArrays(c.triangles, 0, 3);

    // Which is a frame, and the fake watched all of it.
    try testing.expectEqual(1, stub.state.draw_calls);
    try testing.expectEqual(c.triangles, stub.state.last_draw.mode);
    try testing.expectEqual(24, stub.state.last_upload_len);
    try testing.expectEqual(.{ 0, 0, 800, 600 }, stub.state.last_viewport);
    try testing.expectEqual(null, gl.checkError());
}

test "the shorthands are the things they are short for" {
    try testing.expectEqual(context.Context, Context);
    try testing.expectEqual(types.Buffer, Buffer);
    try testing.expect(Buffer != Texture);
    try testing.expectEqual(api.is_wasm, is_wasm);
    try testing.expect(!is_wasm);
}
