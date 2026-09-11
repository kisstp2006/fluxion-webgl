// SPDX-License-Identifier: BSL-1.0

//! A WebGL that is not there.
//!
//! Every declaration in `imports.zig` appears here again, with the same name
//! and the same signature, implemented in Zig. `api` picks between the two at
//! compile time on the target: a wasm build gets the browser, everything else
//! gets this. Which means `zig build test` runs on Windows, on a build
//! server, and inside another package - none of which have a canvas.
//!
//! It is the same idea as `examples/driver.zig` in
//! [Fluxion GL](https://github.com/kisstp2006/fluxion-gl) and the `none`
//! backend in [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi): a
//! renderer is mostly arithmetic and bookkeeping, and the part of it that
//! needs a GPU is smaller than it looks. What this catches is everything up
//! to the draw - that objects are deleted, that a compile failure is reported
//! rather than drawn with, that the matrix handed over is sixteen floats in
//! the right order.
//!
//! What it cannot catch is whether the picture is right. That needs a
//! browser, and `examples/web` is where it goes.
//!
//! It also does one thing the browser will not: fail on demand. Set
//! `state.fail_compile` and the next `compileShader` reports an error with a
//! log attached, which is how the unhappy path gets a test at all - a real
//! driver has to be given a broken shader to produce one, and a broken shader
//! in a test file is a thing that gets quietly fixed.

const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");

const Boolean = types.Boolean;
const Enum = types.Enum;
const Float = types.Float;
const Int = types.Int;
const Sizei = types.Sizei;
const Uint = types.Uint;

const enums = @import("enums.zig");

/// What the fake has been told, for a test to look at afterwards.
pub const State = struct {
    /// The next object index to hand out. One, because zero is the null
    /// object and the glue reserves it.
    next_object: Uint = 1,
    /// Created minus deleted. A test that ends with this above zero leaked
    /// something the browser would have leaked too.
    live_objects: u32 = 0,
    /// Every call that reached the fake, in order of arrival.
    calls: u32 = 0,

    /// Set to make the next `compileShader` fail.
    fail_compile: bool = false,
    /// Set to make the next `linkProgram` fail.
    fail_link: bool = false,
    /// Handed back by `getError` once, then cleared.
    pending_error: Enum = enums.no_error,

    last_clear_color: [4]Float = .{ 0, 0, 0, 0 },
    last_viewport: [4]Int = .{ 0, 0, 0, 0 },
    last_scissor: [4]Int = .{ 0, 0, 0, 0 },
    last_depth_range: [2]Float = .{ 0, 1 },
    /// `src_rgb`, `dst_rgb`, `src_alpha`, `dst_alpha` of the last
    /// `blendFuncSeparate`.
    last_blend_func: [4]Enum = .{ 0, 0, 0, 0 },
    last_matrix: [16]f32 = @splat(0),
    /// `mode`, `count`, `instances` of the last draw of any kind, and the
    /// byte offset of the last indexed one.
    last_draw: struct { mode: Enum = 0, count: Sizei = 0, instances: Sizei = 0, offset: Int = 0 } = .{},
    draw_calls: u32 = 0,
    /// The last attribute pointer of either kind - where it reads from and
    /// whether the shader sees integers.
    last_attribute: struct {
        index: Uint = 0,
        size: Int = 0,
        kind: Enum = 0,
        integer: bool = false,
        stride: Sizei = 0,
        offset: Int = 0,
    } = .{},
    /// The last `texImage2D` or `texSubImage2D`, and the first texel of it -
    /// enough to see which way round the channels went.
    last_image: struct {
        internal_format: Int = 0,
        format: Enum = 0,
        kind: Enum = 0,
        width: Sizei = 0,
        height: Sizei = 0,
        len: u32 = 0,
        first: [4]u8 = .{ 0, 0, 0, 0 },
    } = .{},
    /// What the last `bufferDataSize` allocated.
    last_buffer_size: u32 = 0,
    /// What each uniform buffer slot, and each texture unit's sampler, is
    /// bound to now. Zero is nothing.
    uniform_buffers: [8]Uint = @splat(0),
    samplers: [16]Uint = @splat(0),
    /// The next index `getUniformBlockIndex` answers, and where the last
    /// `uniformBlockBinding` pointed one.
    next_block_index: Uint = 0,
    last_block_binding: struct { block: Uint = 0, binding: Uint = 0 } = .{},
    /// The most recent `bufferData`, copied - the pointer it came from is
    /// long gone by the time a test looks.
    last_upload: [256]u8 = @splat(0),
    last_upload_len: u32 = 0,
    /// The most recent shader source, by length only. Keeping the text would
    /// mean owning it, and the fake has no allocator.
    last_source_len: u32 = 0,
};

/// The one instance. A test that cares resets it first; see `reset`.
pub var state: State = .{};

/// Put the fake back to its starting condition. Tests run in one process and
/// in an order nobody promised, so a test that reads `state` starts here.
pub fn reset() void {
    state = .{};
}

fn object() Uint {
    const handed_out = state.next_object;
    state.next_object += 1;
    state.live_objects += 1;
    return handed_out;
}

fn release(name: Uint) void {
    if (name != 0 and state.live_objects > 0) state.live_objects -= 1;
}

fn tick() void {
    state.calls += 1;
}

// -------------------------------------------------------------------------
// State
// -------------------------------------------------------------------------

pub fn viewport(x: Int, y: Int, width: Sizei, height: Sizei) void {
    tick();
    state.last_viewport = .{ x, y, width, height };
}
pub fn scissor(x: Int, y: Int, width: Sizei, height: Sizei) void {
    tick();
    state.last_scissor = .{ x, y, width, height };
}
pub fn clearColor(r: Float, g: Float, b: Float, a: Float) void {
    tick();
    state.last_clear_color = .{ r, g, b, a };
}
pub fn clearDepth(_: Float) void {
    tick();
}
pub fn clearStencil(_: Int) void {
    tick();
}
pub fn clear(_: u32) void {
    tick();
}
pub fn enable(_: Enum) void {
    tick();
}
pub fn disable(_: Enum) void {
    tick();
}
pub fn depthFunc(_: Enum) void {
    tick();
}
pub fn depthMask(_: Boolean) void {
    tick();
}
pub fn depthRange(near: Float, far: Float) void {
    tick();
    state.last_depth_range = .{ near, far };
}
pub fn colorMask(_: Boolean, _: Boolean, _: Boolean, _: Boolean) void {
    tick();
}
pub fn cullFace(_: Enum) void {
    tick();
}
pub fn frontFace(_: Enum) void {
    tick();
}
pub fn blendFunc(_: Enum, _: Enum) void {
    tick();
}
pub fn blendEquation(_: Enum) void {
    tick();
}
pub fn blendFuncSeparate(src_rgb: Enum, dst_rgb: Enum, src_alpha: Enum, dst_alpha: Enum) void {
    tick();
    state.last_blend_func = .{ src_rgb, dst_rgb, src_alpha, dst_alpha };
}
pub fn blendEquationSeparate(_: Enum, _: Enum) void {
    tick();
}
pub fn pixelStorei(_: Enum, _: Int) void {
    tick();
}
pub fn finish() void {
    tick();
}
pub fn flush() void {
    tick();
}

pub fn getError() Enum {
    tick();
    const code = state.pending_error;
    state.pending_error = enums.no_error;
    return code;
}

pub fn getParameterInt(pname: Enum) Int {
    tick();
    // The floors WebGL 2 guarantees, which is what a program that asks is
    // usually deciding against.
    return switch (pname) {
        enums.max_texture_size => 2048,
        enums.max_cube_map_texture_size => 2048,
        enums.max_renderbuffer_size => 2048,
        enums.max_vertex_attribs => 16,
        enums.max_texture_image_units => 16,
        enums.max_combined_texture_image_units => 32,
        enums.max_uniform_buffer_bindings => 24,
        enums.max_array_texture_layers => 256,
        enums.max_samples => 4,
        else => 0,
    };
}

pub fn getParameterString(pname: Enum, ptr: [*]u8, cap: u32) u32 {
    tick();
    const text: []const u8 = switch (pname) {
        enums.vendor => "Fluxion",
        enums.renderer => "Fluxion WebGL stub",
        enums.version => "WebGL 2.0 (OpenGL ES 3.0 Fluxion)",
        enums.shading_language_version => "WebGL GLSL ES 3.00 (OpenGL ES GLSL ES 3.0 Fluxion)",
        else => "",
    };
    const n = @min(text.len, cap);
    @memcpy(ptr[0..n], text[0..n]);
    return @intCast(text.len);
}

// -------------------------------------------------------------------------
// Buffers
// -------------------------------------------------------------------------

pub fn createBuffer() Uint {
    tick();
    return object();
}
pub fn deleteBuffer(buffer: Uint) void {
    tick();
    release(buffer);
}
pub fn bindBuffer(_: Enum, _: Uint) void {
    tick();
}

pub fn bufferData(_: Enum, ptr: [*]const u8, len: u32, _: Enum) void {
    tick();
    // Copy, because the caller's bytes are usually a stack local and this is
    // exactly what the glue has to do on the other side.
    const n = @min(len, state.last_upload.len);
    @memcpy(state.last_upload[0..n], ptr[0..n]);
    state.last_upload_len = len;
}

pub fn bufferSubData(_: Enum, _: Int, _: [*]const u8, _: u32) void {
    tick();
}

pub fn bufferDataSize(_: Enum, size: u32, _: Enum) void {
    tick();
    state.last_buffer_size = size;
}

pub fn bindBufferBase(target: Enum, index: Uint, buffer: Uint) void {
    tick();
    if (target == enums.uniform_buffer and index < state.uniform_buffers.len) {
        state.uniform_buffers[index] = buffer;
    }
}

// -------------------------------------------------------------------------
// Vertex arrays and attributes
// -------------------------------------------------------------------------

pub fn createVertexArray() Uint {
    tick();
    return object();
}
pub fn deleteVertexArray(array: Uint) void {
    tick();
    release(array);
}
pub fn bindVertexArray(_: Uint) void {
    tick();
}
pub fn enableVertexAttribArray(_: Uint) void {
    tick();
}
pub fn disableVertexAttribArray(_: Uint) void {
    tick();
}
pub fn vertexAttribPointer(index: Uint, size: Int, kind: Enum, _: Boolean, stride: Sizei, offset: Int) void {
    tick();
    state.last_attribute = .{ .index = index, .size = size, .kind = kind, .stride = stride, .offset = offset };
}
pub fn vertexAttribIPointer(index: Uint, size: Int, kind: Enum, stride: Sizei, offset: Int) void {
    tick();
    state.last_attribute = .{ .index = index, .size = size, .kind = kind, .integer = true, .stride = stride, .offset = offset };
}
pub fn vertexAttribDivisor(_: Uint, _: Uint) void {
    tick();
}

// -------------------------------------------------------------------------
// Shaders and programs
// -------------------------------------------------------------------------

pub fn createShader(_: Enum) Uint {
    tick();
    return object();
}
pub fn deleteShader(shader: Uint) void {
    tick();
    release(shader);
}
pub fn shaderSource(_: Uint, _: [*]const u8, len: u32) void {
    tick();
    state.last_source_len = len;
}
pub fn compileShader(_: Uint) void {
    tick();
}

pub fn getShaderParameter(_: Uint, pname: Enum) Int {
    tick();
    if (pname == enums.compile_status) return if (state.fail_compile) 0 else 1;
    return 0;
}

pub fn getShaderInfoLog(_: Uint, ptr: [*]u8, cap: u32) u32 {
    tick();
    const text: []const u8 = if (state.fail_compile)
        "ERROR: 0:1: syntax error, unexpected NEW_IDENTIFIER"
    else
        "";
    const n = @min(text.len, cap);
    @memcpy(ptr[0..n], text[0..n]);
    return @intCast(text.len);
}

pub fn createProgram() Uint {
    tick();
    return object();
}
pub fn deleteProgram(program: Uint) void {
    tick();
    release(program);
}
pub fn attachShader(_: Uint, _: Uint) void {
    tick();
}
pub fn linkProgram(_: Uint) void {
    tick();
}

pub fn getProgramParameter(_: Uint, pname: Enum) Int {
    tick();
    if (pname == enums.link_status) return if (state.fail_link) 0 else 1;
    return 0;
}

pub fn getProgramInfoLog(_: Uint, ptr: [*]u8, cap: u32) u32 {
    tick();
    const text: []const u8 = if (state.fail_link)
        "ERROR: vertex shader output not read by fragment shader"
    else
        "";
    const n = @min(text.len, cap);
    @memcpy(ptr[0..n], text[0..n]);
    return @intCast(text.len);
}

pub fn useProgram(_: Uint) void {
    tick();
}
pub fn bindAttribLocation(_: Uint, _: Uint, _: [*]const u8, _: u32) void {
    tick();
}

pub fn getAttribLocation(_: Uint, ptr: [*]const u8, len: u32) Int {
    tick();
    // A name starting with an underscore is the one nothing uses, so a test
    // can ask for a location that is not there.
    if (len > 0 and ptr[0] == '_') return -1;
    return 0;
}

pub fn getUniformLocation(_: Uint, ptr: [*]const u8, len: u32) Uint {
    tick();
    if (len > 0 and ptr[0] == '_') return 0;
    // Handed out like an object and not counted as a live one. A location
    // is looked up rather than made, and WebGL has no call to give one back,
    // so it is not something a program can leak - and counting it would make
    // every correct program look like one that does.
    const handed_out = state.next_object;
    state.next_object += 1;
    return handed_out;
}

pub fn getUniformBlockIndex(_: Uint, ptr: [*]const u8, len: u32) Uint {
    tick();
    // The same convention as a location: an underscore is the block the
    // linker removed.
    if (len > 0 and ptr[0] == '_') return enums.invalid_index;
    defer state.next_block_index += 1;
    return state.next_block_index;
}

pub fn uniformBlockBinding(_: Uint, block: Uint, binding: Uint) void {
    tick();
    state.last_block_binding = .{ .block = block, .binding = binding };
}

// -------------------------------------------------------------------------
// Uniforms
// -------------------------------------------------------------------------

pub fn uniform1i(_: Uint, _: Int) void {
    tick();
}
pub fn uniform1f(_: Uint, _: Float) void {
    tick();
}
pub fn uniform2f(_: Uint, _: Float, _: Float) void {
    tick();
}
pub fn uniform3f(_: Uint, _: Float, _: Float, _: Float) void {
    tick();
}
pub fn uniform4f(_: Uint, _: Float, _: Float, _: Float, _: Float) void {
    tick();
}

pub fn uniformMatrix3fv(_: Uint, _: Sizei, _: Boolean, _: [*]const f32) void {
    tick();
}

pub fn uniformMatrix4fv(_: Uint, count: Sizei, _: Boolean, ptr: [*]const f32) void {
    tick();
    if (count > 0) @memcpy(&state.last_matrix, ptr[0..16]);
}

// -------------------------------------------------------------------------
// Textures
// -------------------------------------------------------------------------

pub fn createTexture() Uint {
    tick();
    return object();
}
pub fn deleteTexture(texture: Uint) void {
    tick();
    release(texture);
}
pub fn bindTexture(_: Enum, _: Uint) void {
    tick();
}
pub fn activeTexture(_: Enum) void {
    tick();
}
pub fn texParameteri(_: Enum, _: Enum, _: Int) void {
    tick();
}
pub fn generateMipmap(_: Enum) void {
    tick();
}

pub fn texImage2D(_: Enum, _: Int, internal_format: Int, width: Sizei, height: Sizei, _: Int, format: Enum, kind: Enum, ptr: [*]const u8, len: u32) void {
    tick();
    recordImage(internal_format, width, height, format, kind, ptr, len);
}

pub fn texSubImage2D(_: Enum, _: Int, _: Int, _: Int, width: Sizei, height: Sizei, format: Enum, kind: Enum, ptr: [*]const u8, len: u32) void {
    tick();
    recordImage(state.last_image.internal_format, width, height, format, kind, ptr, len);
}

fn recordImage(internal_format: Int, width: Sizei, height: Sizei, format: Enum, kind: Enum, ptr: [*]const u8, len: u32) void {
    var first: [4]u8 = .{ 0, 0, 0, 0 };
    const n = @min(len, first.len);
    @memcpy(first[0..n], ptr[0..n]);
    state.last_image = .{
        .internal_format = internal_format,
        .format = format,
        .kind = kind,
        .width = width,
        .height = height,
        .len = len,
        .first = first,
    };
}

// -------------------------------------------------------------------------
// Samplers
// -------------------------------------------------------------------------

pub fn createSampler() Uint {
    tick();
    return object();
}
pub fn deleteSampler(sampler: Uint) void {
    tick();
    release(sampler);
}
pub fn bindSampler(unit: Uint, sampler: Uint) void {
    tick();
    if (unit < state.samplers.len) state.samplers[unit] = sampler;
}
pub fn samplerParameteri(_: Uint, _: Enum, _: Int) void {
    tick();
}

// -------------------------------------------------------------------------
// Framebuffers
// -------------------------------------------------------------------------

pub fn createFramebuffer() Uint {
    tick();
    return object();
}
pub fn deleteFramebuffer(fbo: Uint) void {
    tick();
    release(fbo);
}
pub fn bindFramebuffer(_: Enum, _: Uint) void {
    tick();
}
pub fn framebufferTexture2D(_: Enum, _: Enum, _: Enum, _: Uint, _: Int) void {
    tick();
}

pub fn checkFramebufferStatus(_: Enum) Enum {
    tick();
    return enums.framebuffer_complete;
}

pub fn createRenderbuffer() Uint {
    tick();
    return object();
}
pub fn deleteRenderbuffer(rbo: Uint) void {
    tick();
    release(rbo);
}
pub fn bindRenderbuffer(_: Enum, _: Uint) void {
    tick();
}
pub fn renderbufferStorage(_: Enum, _: Enum, _: Sizei, _: Sizei) void {
    tick();
}
pub fn framebufferRenderbuffer(_: Enum, _: Enum, _: Enum, _: Uint) void {
    tick();
}

pub fn readPixels(_: Int, _: Int, width: Sizei, height: Sizei, _: Enum, _: Enum, ptr: [*]u8, len: u32) void {
    tick();
    // The clear colour, in every pixel, so a test that draws nothing and
    // reads back gets what a real context would have given it.
    const w: u32 = @intCast(@max(width, 0));
    const h: u32 = @intCast(@max(height, 0));
    const pixels = @min(w * h, len / 4);
    for (0..pixels) |i| {
        for (0..4) |channel| {
            const value = state.last_clear_color[channel];
            ptr[i * 4 + channel] = @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
        }
    }
}

// -------------------------------------------------------------------------
// Drawing
// -------------------------------------------------------------------------

pub fn drawArrays(mode: Enum, _: Int, count: Sizei) void {
    tick();
    state.draw_calls += 1;
    state.last_draw = .{ .mode = mode, .count = count, .instances = 1 };
}

pub fn drawElements(mode: Enum, count: Sizei, _: Enum, offset: Int) void {
    tick();
    state.draw_calls += 1;
    state.last_draw = .{ .mode = mode, .count = count, .instances = 1, .offset = offset };
}

pub fn drawArraysInstanced(mode: Enum, _: Int, count: Sizei, instances: Sizei) void {
    tick();
    state.draw_calls += 1;
    state.last_draw = .{ .mode = mode, .count = count, .instances = instances };
}

pub fn drawElementsInstanced(mode: Enum, count: Sizei, _: Enum, offset: Int, instances: Sizei) void {
    tick();
    state.draw_calls += 1;
    state.last_draw = .{ .mode = mode, .count = count, .instances = instances, .offset = offset };
}

test "objects are handed out from one, and zero stays the null object" {
    reset();
    defer reset();

    const first = createBuffer();
    const second = createTexture();
    try testing.expectEqual(1, first);
    try testing.expectEqual(2, second);
    try testing.expectEqual(2, state.live_objects);

    deleteBuffer(first);
    deleteTexture(second);
    try testing.expectEqual(0, state.live_objects);
}

test "a compile can be made to fail, which is the path a real driver hides" {
    reset();
    defer reset();

    const shader = createShader(enums.vertex_shader);
    compileShader(shader);
    try testing.expectEqual(1, getShaderParameter(shader, enums.compile_status));

    state.fail_compile = true;
    compileShader(shader);
    try testing.expectEqual(0, getShaderParameter(shader, enums.compile_status));

    var log: [128]u8 = undefined;
    const n = getShaderInfoLog(shader, &log, log.len);
    try testing.expect(n > 0);
    try testing.expect(std.mem.startsWith(u8, log[0..n], "ERROR:"));
}

test "an upload is copied, because the caller's bytes will not last" {
    reset();
    defer reset();

    {
        var vertices = [_]f32{ -0.5, -0.5, 0.5, -0.5, 0, 0.5 };
        bufferData(enums.array_buffer, @ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), enums.static_draw);
        // `vertices` dies at the end of this block, exactly as a stack local
        // in a caller would.
    }

    try testing.expectEqual(24, state.last_upload_len);
    const read_back = std.mem.bytesAsSlice(f32, state.last_upload[0..24]);
    try testing.expectEqual(@as(f32, -0.5), read_back[0]);
    try testing.expectEqual(@as(f32, 0.5), read_back[5]);
}

test "readPixels answers the clear colour" {
    reset();
    defer reset();

    clearColor(1, 0, 0.5, 1);
    var pixels: [16]u8 = undefined;
    readPixels(0, 0, 2, 2, enums.rgba, enums.unsigned_byte, &pixels, pixels.len);

    try testing.expectEqual(255, pixels[0]);
    try testing.expectEqual(0, pixels[1]);
    try testing.expectEqual(128, pixels[2]);
    try testing.expectEqual(255, pixels[3]);
}
