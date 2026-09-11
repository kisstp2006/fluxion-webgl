// SPDX-License-Identifier: BSL-1.0

//! The WebGL calls, as WebAssembly imports.
//!
//! This is the file `fluxion-gl` does not have, and the reason the two
//! libraries are shaped differently.
//!
//! On the desktop, a GL command is found at run time: the driver is a shared
//! library, `getProcAddress` hands back an address, and a table of function
//! pointers is filled in from it. None of that exists here. A wasm module
//! cannot open a library, cannot take the address of something outside its
//! own memory, and cannot call an address it was given - `call_indirect` only
//! reaches functions the module itself put in its table. What it *can* do is
//! declare, at compile time, that it needs a function from the outside, and
//! refuse to instantiate until the host provides one.
//!
//! That is what `extern "webgl"` says. Each declaration below becomes an
//! entry in the module's import section, under the module name `webgl` and
//! its own field name, and the browser must hand over a matching JavaScript
//! function in `WebAssembly.instantiate`. A missing one is not a null pointer
//! to check for - it is a `LinkError` before a single instruction runs.
//!
//! So the version policy inverts. `fluxion-gl` spells an optional command as
//! `?*const fn`, because a driver either has it or does not. Here every
//! import is required and the *glue* decides what to provide: a WebGL 1
//! context has no `createVertexArray`, so `webgl.js` supplies one backed by
//! the `OES_vertex_array_object` extension, or by a function that throws.
//! The check moved from the type system to the loader, because that is where
//! the browser put it.
//!
//! Three rules the signatures follow, all of them forced by the ABI:
//!
//!   * **Four types cross.** WebAssembly has `i32`, `i64`, `f32` and `f64`.
//!     Everything here is one of those or narrows to one: a `bool` is an
//!     `i32`, an enum backed by `u32` is an `i32`, a `[*]const u8` is the
//!     `i32` address of a byte in linear memory.
//!
//!   * **A slice is two arguments.** Zig's `[]const u8` is an address and a
//!     length together, and there is no such thing on the wire. Every call
//!     that takes bytes takes `ptr` and `len` separately, and the glue reads
//!     them back out of the module memory with a view over that range.
//!
//!   * **Nothing is returned by value but a number.** A JavaScript string
//!     cannot be handed back, so the calls that produce text - the two info
//!     logs, `getParameterString` - are given a buffer to fill and answer
//!     with how many bytes they wrote.
//!
//! The sharp edge is the second rule. The glue is reading *your* linear
//! memory, by address, while the calling function is still on the stack -
//! and if the module grows its memory mid-call the JavaScript view is
//! detached and silently useless. Every call here is written so the glue
//! copies what it needs and keeps no range, and none of them allocate on the
//! Zig side while a pointer is out.
//!
//! Nothing in this file is meant to be called directly. `Context` wraps it in
//! slices, error unions and distinct object types; this is the wire.

const types = @import("types.zig");

const Boolean = types.Boolean;
const Enum = types.Enum;
const Float = types.Float;
const Int = types.Int;
const Sizei = types.Sizei;
const Uint = types.Uint;

// -------------------------------------------------------------------------
// State
// -------------------------------------------------------------------------

pub extern "webgl" fn viewport(x: Int, y: Int, width: Sizei, height: Sizei) void;
pub extern "webgl" fn scissor(x: Int, y: Int, width: Sizei, height: Sizei) void;
pub extern "webgl" fn clearColor(r: Float, g: Float, b: Float, a: Float) void;
pub extern "webgl" fn clearDepth(depth: Float) void;
pub extern "webgl" fn clearStencil(s: Int) void;
pub extern "webgl" fn clear(mask: u32) void;
pub extern "webgl" fn enable(cap: Enum) void;
pub extern "webgl" fn disable(cap: Enum) void;
pub extern "webgl" fn depthFunc(func: Enum) void;
pub extern "webgl" fn depthMask(flag: Boolean) void;
pub extern "webgl" fn depthRange(near: Float, far: Float) void;
pub extern "webgl" fn colorMask(r: Boolean, g: Boolean, b: Boolean, a: Boolean) void;
pub extern "webgl" fn cullFace(mode: Enum) void;
pub extern "webgl" fn frontFace(mode: Enum) void;
pub extern "webgl" fn blendFunc(src: Enum, dst: Enum) void;
pub extern "webgl" fn blendEquation(mode: Enum) void;
pub extern "webgl" fn blendFuncSeparate(src_rgb: Enum, dst_rgb: Enum, src_alpha: Enum, dst_alpha: Enum) void;
pub extern "webgl" fn blendEquationSeparate(mode_rgb: Enum, mode_alpha: Enum) void;
pub extern "webgl" fn pixelStorei(pname: Enum, param: Int) void;
pub extern "webgl" fn finish() void;
pub extern "webgl" fn flush() void;

/// The oldest error still in the queue, or `no_error`. See
/// `Context.checkError`, which drains it.
pub extern "webgl" fn getError() Enum;

/// One integer of context state. The `getParameter` of WebGL answers a
/// different JavaScript type per token - number, boolean, array, string - and
/// only the numeric ones come through here; the glue coerces and the string
/// ones go to `getParameterString`.
pub extern "webgl" fn getParameterInt(pname: Enum) Int;

/// One string of context state - `vendor`, `renderer`, `version`,
/// `shading_language_version` - written as UTF-8 into `ptr[0..cap]`.
/// Answers the full length, which may be longer than `cap`.
pub extern "webgl" fn getParameterString(pname: Enum, ptr: [*]u8, cap: u32) u32;

// -------------------------------------------------------------------------
// Buffers
// -------------------------------------------------------------------------

pub extern "webgl" fn createBuffer() Uint;
pub extern "webgl" fn deleteBuffer(buffer: Uint) void;
pub extern "webgl" fn bindBuffer(target: Enum, buffer: Uint) void;
pub extern "webgl" fn bufferData(target: Enum, ptr: [*]const u8, len: u32, usage: Enum) void;
pub extern "webgl" fn bufferSubData(target: Enum, offset: Int, ptr: [*]const u8, len: u32) void;

/// `size` bytes of storage for the buffer bound to `target`, zeroed.
///
/// WebGL's `bufferData(target, size, usage)`: the overload that takes a size
/// where the other takes data. JavaScript tells the two apart by the type of
/// the second argument, and the wire has no types to tell them apart by, so
/// here they are two names.
pub extern "webgl" fn bufferDataSize(target: Enum, size: u32, usage: Enum) void;

/// WebGL 2. Bind `buffer` to slot `index` of an indexed target - for
/// `uniform_buffer`, the slot a block was pointed at by `uniformBlockBinding`.
pub extern "webgl" fn bindBufferBase(target: Enum, index: Uint, buffer: Uint) void;

// -------------------------------------------------------------------------
// Vertex arrays and attributes
// -------------------------------------------------------------------------

pub extern "webgl" fn createVertexArray() Uint;
pub extern "webgl" fn deleteVertexArray(array: Uint) void;
pub extern "webgl" fn bindVertexArray(array: Uint) void;
pub extern "webgl" fn enableVertexAttribArray(index: Uint) void;
pub extern "webgl" fn disableVertexAttribArray(index: Uint) void;
pub extern "webgl" fn vertexAttribPointer(
    index: Uint,
    size: Int,
    kind: Enum,
    normalized: Boolean,
    stride: Sizei,
    offset: Int,
) void;

/// WebGL 2. As `vertexAttribPointer`, for an attribute the shader declares as
/// `int` or `uint`: the values arrive as integers, where the other call would
/// have turned them into floats on the way in.
pub extern "webgl" fn vertexAttribIPointer(index: Uint, size: Int, kind: Enum, stride: Sizei, offset: Int) void;
pub extern "webgl" fn vertexAttribDivisor(index: Uint, divisor: Uint) void;

// -------------------------------------------------------------------------
// Shaders and programs
// -------------------------------------------------------------------------

pub extern "webgl" fn createShader(kind: Enum) Uint;
pub extern "webgl" fn deleteShader(shader: Uint) void;
pub extern "webgl" fn shaderSource(shader: Uint, ptr: [*]const u8, len: u32) void;
pub extern "webgl" fn compileShader(shader: Uint) void;
pub extern "webgl" fn getShaderParameter(shader: Uint, pname: Enum) Int;
pub extern "webgl" fn getShaderInfoLog(shader: Uint, ptr: [*]u8, cap: u32) u32;

pub extern "webgl" fn createProgram() Uint;
pub extern "webgl" fn deleteProgram(program: Uint) void;
pub extern "webgl" fn attachShader(program: Uint, shader: Uint) void;
pub extern "webgl" fn linkProgram(program: Uint) void;
pub extern "webgl" fn getProgramParameter(program: Uint, pname: Enum) Int;
pub extern "webgl" fn getProgramInfoLog(program: Uint, ptr: [*]u8, cap: u32) u32;
pub extern "webgl" fn useProgram(program: Uint) void;

pub extern "webgl" fn bindAttribLocation(program: Uint, index: Uint, ptr: [*]const u8, len: u32) void;
pub extern "webgl" fn getAttribLocation(program: Uint, ptr: [*]const u8, len: u32) Int;

/// The location object for a uniform, or 0 where the linker removed it.
/// Unlike every other object here this one is looked up rather than created,
/// and `.none` is an ordinary answer rather than a failure.
pub extern "webgl" fn getUniformLocation(program: Uint, ptr: [*]const u8, len: u32) Uint;

/// WebGL 2. Which uniform block of `program` is called `ptr[0..len]`, or
/// `invalid_index` where there is none by that name - never declared, or
/// removed by the linker because nothing reads it.
pub extern "webgl" fn getUniformBlockIndex(program: Uint, ptr: [*]const u8, len: u32) Uint;

/// WebGL 2. Point block `block` of `program` at uniform buffer slot
/// `binding`. GLSL ES 3.00 has no `layout(binding = n)`, so this is where a
/// block learns its slot.
pub extern "webgl" fn uniformBlockBinding(program: Uint, block: Uint, binding: Uint) void;

// -------------------------------------------------------------------------
// Uniforms
// -------------------------------------------------------------------------

pub extern "webgl" fn uniform1i(location: Uint, v: Int) void;
pub extern "webgl" fn uniform1f(location: Uint, v: Float) void;
pub extern "webgl" fn uniform2f(location: Uint, x: Float, y: Float) void;
pub extern "webgl" fn uniform3f(location: Uint, x: Float, y: Float, z: Float) void;
pub extern "webgl" fn uniform4f(location: Uint, x: Float, y: Float, z: Float, w: Float) void;

/// `count` matrices of nine floats, column-major, from `ptr`.
pub extern "webgl" fn uniformMatrix3fv(location: Uint, count: Sizei, transpose: Boolean, ptr: [*]const f32) void;

/// `count` matrices of sixteen floats, column-major, from `ptr`.
///
/// `transpose` is `false` for anything `fluxion-math` produced: a `Mat4`
/// there is column-major already, which is the layout GL has always wanted
/// and the reason `&m.cols[0].x` can be handed over as it is. WebGL 1 rejects
/// a `true` here outright; WebGL 2 allows it.
pub extern "webgl" fn uniformMatrix4fv(location: Uint, count: Sizei, transpose: Boolean, ptr: [*]const f32) void;

// -------------------------------------------------------------------------
// Textures
// -------------------------------------------------------------------------

pub extern "webgl" fn createTexture() Uint;
pub extern "webgl" fn deleteTexture(texture: Uint) void;
pub extern "webgl" fn bindTexture(target: Enum, texture: Uint) void;
pub extern "webgl" fn activeTexture(unit: Enum) void;
pub extern "webgl" fn texParameteri(target: Enum, pname: Enum, param: Int) void;
pub extern "webgl" fn generateMipmap(target: Enum) void;

/// Upload. `len` of zero with any `ptr` means the null upload that allocates
/// storage without filling it - what a render target wants.
pub extern "webgl" fn texImage2D(
    target: Enum,
    level: Int,
    internal_format: Int,
    width: Sizei,
    height: Sizei,
    border: Int,
    format: Enum,
    kind: Enum,
    ptr: [*]const u8,
    len: u32,
) void;

pub extern "webgl" fn texSubImage2D(
    target: Enum,
    level: Int,
    x: Int,
    y: Int,
    width: Sizei,
    height: Sizei,
    format: Enum,
    kind: Enum,
    ptr: [*]const u8,
    len: u32,
) void;

// -------------------------------------------------------------------------
// Samplers
// -------------------------------------------------------------------------

/// WebGL 2. A sampler object: filtering and wrapping, kept apart from any
/// one texture.
pub extern "webgl" fn createSampler() Uint;
pub extern "webgl" fn deleteSampler(sampler: Uint) void;
/// WebGL 2. Read texture unit `unit` through `sampler`. The unit is the
/// index, not `texture0 + unit` - the same number a sampler uniform is set
/// to.
pub extern "webgl" fn bindSampler(unit: Uint, sampler: Uint) void;
pub extern "webgl" fn samplerParameteri(sampler: Uint, pname: Enum, param: Int) void;

// -------------------------------------------------------------------------
// Framebuffers
// -------------------------------------------------------------------------

pub extern "webgl" fn createFramebuffer() Uint;
pub extern "webgl" fn deleteFramebuffer(fbo: Uint) void;
pub extern "webgl" fn bindFramebuffer(target: Enum, fbo: Uint) void;
pub extern "webgl" fn framebufferTexture2D(target: Enum, attachment: Enum, tex_target: Enum, texture: Uint, level: Int) void;
pub extern "webgl" fn checkFramebufferStatus(target: Enum) Enum;

pub extern "webgl" fn createRenderbuffer() Uint;
pub extern "webgl" fn deleteRenderbuffer(rbo: Uint) void;
pub extern "webgl" fn bindRenderbuffer(target: Enum, rbo: Uint) void;
pub extern "webgl" fn renderbufferStorage(target: Enum, format: Enum, width: Sizei, height: Sizei) void;
pub extern "webgl" fn framebufferRenderbuffer(target: Enum, attachment: Enum, rb_target: Enum, rbo: Uint) void;

/// Read back into `ptr[0..len]`. The rows come back bottom-up, as they do
/// everywhere in GL; `Context.readPixels` says so and leaves them that way.
pub extern "webgl" fn readPixels(
    x: Int,
    y: Int,
    width: Sizei,
    height: Sizei,
    format: Enum,
    kind: Enum,
    ptr: [*]u8,
    len: u32,
) void;

// -------------------------------------------------------------------------
// Drawing
// -------------------------------------------------------------------------

pub extern "webgl" fn drawArrays(mode: Enum, first: Int, count: Sizei) void;
pub extern "webgl" fn drawElements(mode: Enum, count: Sizei, kind: Enum, offset: Int) void;
pub extern "webgl" fn drawArraysInstanced(mode: Enum, first: Int, count: Sizei, instances: Sizei) void;
pub extern "webgl" fn drawElementsInstanced(mode: Enum, count: Sizei, kind: Enum, offset: Int, instances: Sizei) void;
