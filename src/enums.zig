// SPDX-License-Identifier: BSL-1.0

//! The numbers the calls take, which GL calls enums even though they are one
//! flat numbering shared by every argument of every call.
//!
//! The names are the Khronos ones with `GL_` taken off and lowered, so
//! anything findable in the OpenGL ES 3.0 specification or on MDN is findable
//! here. The values are the same numbers desktop GL uses, because WebGL did
//! not renumber anything - `TRIANGLES` is 4 in a browser for the same reason
//! it is 4 on a workstation.
//!
//! What is here is what WebGL 2 accepts. WebGL 1 is a smaller set of the same
//! numbers, and where a token needs a context version to be legal the doc
//! comment says so. Two tokens are WebGL's own invention and appear in no
//! desktop header: `unpack_flip_y_webgl` and `unpack_premultiply_alpha_webgl`,
//! which exist because the thing being uploaded is usually an `<img>` and the
//! browser knows which way up it is.
//!
//! A token that is not here is a number like any other: pass it as a literal.

const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");

const Bitfield = types.Bitfield;
const Enum = types.Enum;
const Uint = types.Uint;

// -------------------------------------------------------------------------
// Errors
// -------------------------------------------------------------------------

pub const no_error: Enum = 0;
pub const invalid_enum: Enum = 0x0500;
pub const invalid_value: Enum = 0x0501;
pub const invalid_operation: Enum = 0x0502;
pub const out_of_memory: Enum = 0x0505;
pub const invalid_framebuffer_operation: Enum = 0x0506;

/// WebGL's own, and the one desktop GL has no equivalent for: the browser
/// took the drawing context away - the GPU reset, the tab was backgrounded
/// too long, another page needed the hardware. Every object made on the
/// context is gone and every call is a no-op until `webglcontextrestored`.
/// A program that means to survive it rebuilds its resources there.
pub const context_lost_webgl: Enum = 0x9242;

// -------------------------------------------------------------------------
// Primitives
// -------------------------------------------------------------------------

pub const points: Enum = 0x0000;
pub const lines: Enum = 0x0001;
pub const line_loop: Enum = 0x0002;
pub const line_strip: Enum = 0x0003;
pub const triangles: Enum = 0x0004;
pub const triangle_strip: Enum = 0x0005;
pub const triangle_fan: Enum = 0x0006;

// -------------------------------------------------------------------------
// Data types
// -------------------------------------------------------------------------

pub const byte: Enum = 0x1400;
pub const unsigned_byte: Enum = 0x1401;
pub const short: Enum = 0x1402;
pub const unsigned_short: Enum = 0x1403;
pub const int: Enum = 0x1404;
pub const unsigned_int: Enum = 0x1405;
pub const float: Enum = 0x1406;
/// WebGL 2.
pub const half_float: Enum = 0x140B;
/// WebGL 2. Twenty-four bits of depth and eight of stencil in one word: what
/// a `depth24_stencil8` texture is uploaded and read as.
pub const unsigned_int_24_8: Enum = 0x84FA;

// -------------------------------------------------------------------------
// Buffers
// -------------------------------------------------------------------------

pub const array_buffer: Enum = 0x8892;
pub const element_array_buffer: Enum = 0x8893;
/// WebGL 2.
pub const uniform_buffer: Enum = 0x8A11;
/// WebGL 2. What a `bindBufferRange` offset into a uniform buffer is a
/// multiple of.
pub const uniform_buffer_offset_alignment: Enum = 0x8A34;
/// WebGL 2.
pub const copy_read_buffer: Enum = 0x8F36;
/// WebGL 2.
pub const copy_write_buffer: Enum = 0x8F37;

pub const stream_draw: Enum = 0x88E0;
pub const static_draw: Enum = 0x88E4;
pub const dynamic_draw: Enum = 0x88E8;

// -------------------------------------------------------------------------
// Clearing
// -------------------------------------------------------------------------

pub const depth_buffer_bit: Bitfield = 0x00000100;
pub const stencil_buffer_bit: Bitfield = 0x00000400;
pub const color_buffer_bit: Bitfield = 0x00004000;

// -------------------------------------------------------------------------
// State to turn on and off
// -------------------------------------------------------------------------

pub const cull_face: Enum = 0x0B44;
pub const depth_test: Enum = 0x0B71;
pub const stencil_test: Enum = 0x0B90;
pub const dither: Enum = 0x0BD0;
pub const blend: Enum = 0x0BE2;
pub const scissor_test: Enum = 0x0C11;
pub const polygon_offset_fill: Enum = 0x8037;
pub const sample_alpha_to_coverage: Enum = 0x809E;
pub const sample_coverage: Enum = 0x80A0;
/// WebGL 2.
pub const rasterizer_discard: Enum = 0x8C89;

// -------------------------------------------------------------------------
// Depth and stencil comparison
// -------------------------------------------------------------------------

pub const never: Enum = 0x0200;
pub const less: Enum = 0x0201;
pub const equal: Enum = 0x0202;
pub const lequal: Enum = 0x0203;
pub const greater: Enum = 0x0204;
pub const notequal: Enum = 0x0205;
pub const gequal: Enum = 0x0206;
pub const always: Enum = 0x0207;

// -------------------------------------------------------------------------
// Culling and winding
// -------------------------------------------------------------------------

pub const front: Enum = 0x0404;
pub const back: Enum = 0x0405;
pub const front_and_back: Enum = 0x0408;

pub const cw: Enum = 0x0900;
pub const ccw: Enum = 0x0901;

// -------------------------------------------------------------------------
// Blending
// -------------------------------------------------------------------------

pub const zero: Enum = 0;
pub const one: Enum = 1;
pub const src_color: Enum = 0x0300;
pub const one_minus_src_color: Enum = 0x0301;
pub const src_alpha: Enum = 0x0302;
pub const one_minus_src_alpha: Enum = 0x0303;
pub const dst_alpha: Enum = 0x0304;
pub const one_minus_dst_alpha: Enum = 0x0305;
pub const dst_color: Enum = 0x0306;
pub const one_minus_dst_color: Enum = 0x0307;
pub const src_alpha_saturate: Enum = 0x0308;
pub const constant_color: Enum = 0x8001;
pub const one_minus_constant_color: Enum = 0x8002;
pub const constant_alpha: Enum = 0x8003;
pub const one_minus_constant_alpha: Enum = 0x8004;

pub const func_add: Enum = 0x8006;
pub const func_subtract: Enum = 0x800A;
pub const func_reverse_subtract: Enum = 0x800B;
/// WebGL 2.
pub const min: Enum = 0x8007;
/// WebGL 2.
pub const max: Enum = 0x8008;

// -------------------------------------------------------------------------
// Shaders and programs
// -------------------------------------------------------------------------

pub const fragment_shader: Enum = 0x8B30;
pub const vertex_shader: Enum = 0x8B31;

pub const compile_status: Enum = 0x8B81;
pub const link_status: Enum = 0x8B82;
pub const validate_status: Enum = 0x8B83;
pub const info_log_length: Enum = 0x8B84;
pub const shader_type: Enum = 0x8B4F;
pub const delete_status: Enum = 0x8B80;
pub const attached_shaders: Enum = 0x8B85;
pub const active_uniforms: Enum = 0x8B86;
pub const active_attributes: Enum = 0x8B89;

/// WebGL 2. What `getUniformBlockIndex` answers for a block the program has
/// not got - never declared, or removed by the linker because nothing reads
/// it. All ones, so it can never be mistaken for a real index.
pub const invalid_index: Uint = 0xFFFFFFFF;

// -------------------------------------------------------------------------
// Textures
// -------------------------------------------------------------------------

pub const texture_2d: Enum = 0x0DE1;
pub const texture_cube_map: Enum = 0x8513;
/// WebGL 2.
pub const texture_3d: Enum = 0x806F;
/// WebGL 2.
pub const texture_2d_array: Enum = 0x8C1A;

pub const texture_cube_map_positive_x: Enum = 0x8515;

pub const texture_min_filter: Enum = 0x2801;
pub const texture_mag_filter: Enum = 0x2800;
pub const texture_wrap_s: Enum = 0x2802;
pub const texture_wrap_t: Enum = 0x2803;
/// WebGL 2.
pub const texture_wrap_r: Enum = 0x8072;
/// WebGL 2.
pub const texture_base_level: Enum = 0x813C;
/// WebGL 2.
pub const texture_max_level: Enum = 0x813D;

pub const nearest: Enum = 0x2600;
pub const linear: Enum = 0x2601;
pub const nearest_mipmap_nearest: Enum = 0x2700;
pub const linear_mipmap_nearest: Enum = 0x2701;
pub const nearest_mipmap_linear: Enum = 0x2702;
pub const linear_mipmap_linear: Enum = 0x2703;

pub const repeat: Enum = 0x2901;
pub const clamp_to_edge: Enum = 0x812F;
pub const mirrored_repeat: Enum = 0x8370;

pub const texture0: Enum = 0x84C0;

// -------------------------------------------------------------------------
// Pixel formats
// -------------------------------------------------------------------------

pub const alpha: Enum = 0x1906;
pub const rgb: Enum = 0x1907;
pub const rgba: Enum = 0x1908;
pub const luminance: Enum = 0x1909;
pub const luminance_alpha: Enum = 0x190A;
pub const depth_component: Enum = 0x1902;
pub const depth_stencil: Enum = 0x84F9;
/// WebGL 2.
pub const red: Enum = 0x1903;
/// WebGL 2.
pub const rg: Enum = 0x8227;

/// Sized internal formats. WebGL 2 only: WebGL 1 takes the unsized names
/// above for `internalformat` as well, and infers the rest.
pub const r8: Enum = 0x8229;
pub const rg8: Enum = 0x822B;
pub const rgb8: Enum = 0x8051;
pub const rgba8: Enum = 0x8058;
pub const srgb8: Enum = 0x8C41;
pub const srgb8_alpha8: Enum = 0x8C43;
pub const rgba16f: Enum = 0x881A;
pub const rgba32f: Enum = 0x8814;
pub const depth_component16: Enum = 0x81A5;
pub const depth_component24: Enum = 0x81A6;
pub const depth_component32f: Enum = 0x8CAC;
pub const depth24_stencil8: Enum = 0x88F0;

pub const unpack_alignment: Enum = 0x0CF5;
pub const pack_alignment: Enum = 0x0D05;
/// WebGL 2. How many pixels one row of an upload is, when that is more than
/// the width being uploaded - a rectangle cut out of a larger image. Zero,
/// the default, means the width.
pub const unpack_row_length: Enum = 0x0CF2;

/// WebGL's own. The browser is usually uploading an `<img>`, a `<canvas>` or
/// a `<video>`, all of which count rows from the top, and GL counts from the
/// bottom. Setting this makes the flip the implementation's problem rather
/// than yours - and it has no effect on a plain array of bytes you packed
/// yourself, which is why an upload from memory usually leaves it alone.
pub const unpack_flip_y_webgl: Enum = 0x9240;

/// WebGL's own. Multiplies colour by alpha on upload, for a texture that will
/// be blended with `one, one_minus_src_alpha` rather than
/// `src_alpha, one_minus_src_alpha`.
pub const unpack_premultiply_alpha_webgl: Enum = 0x9241;

// -------------------------------------------------------------------------
// Framebuffers and renderbuffers
// -------------------------------------------------------------------------

pub const framebuffer: Enum = 0x8D40;
pub const renderbuffer: Enum = 0x8D41;
/// WebGL 2.
pub const read_framebuffer: Enum = 0x8CA8;
/// WebGL 2.
pub const draw_framebuffer: Enum = 0x8CA9;

pub const color_attachment0: Enum = 0x8CE0;
pub const depth_attachment: Enum = 0x8D00;
pub const stencil_attachment: Enum = 0x8D20;
pub const depth_stencil_attachment: Enum = 0x821A;

pub const framebuffer_complete: Enum = 0x8CD5;
pub const framebuffer_incomplete_attachment: Enum = 0x8CD6;
pub const framebuffer_incomplete_missing_attachment: Enum = 0x8CD7;
pub const framebuffer_incomplete_dimensions: Enum = 0x8CD9;
pub const framebuffer_unsupported: Enum = 0x8CDD;

// -------------------------------------------------------------------------
// Strings and limits
// -------------------------------------------------------------------------

pub const vendor: Enum = 0x1F00;
pub const renderer: Enum = 0x1F01;
pub const version: Enum = 0x1F02;
pub const shading_language_version: Enum = 0x8B8C;

pub const max_texture_size: Enum = 0x0D33;
pub const max_viewport_dims: Enum = 0x0D3A;
pub const max_vertex_attribs: Enum = 0x8869;
pub const max_texture_image_units: Enum = 0x8872;
pub const max_combined_texture_image_units: Enum = 0x8B4D;
pub const max_cube_map_texture_size: Enum = 0x851C;
pub const max_renderbuffer_size: Enum = 0x84E8;
/// WebGL 2.
pub const max_uniform_buffer_bindings: Enum = 0x8A2F;
/// WebGL 2.
pub const max_array_texture_layers: Enum = 0x88FF;
/// WebGL 2.
pub const max_samples: Enum = 0x8D57;
/// WebGL 2. The supported renderbuffer sample counts returned by
/// `getInternalformatParameter`.
pub const samples: Enum = 0x80A9;

// -------------------------------------------------------------------------
// The ones that are defined as a sum
// -------------------------------------------------------------------------

/// The texture unit `index` counts from, for `activeTexture`.
///
/// A function rather than a table, because WebGL 2 guarantees at least 32
/// combined units and an implementation may offer far more - and because the
/// sampler uniform that goes with it takes the *index*, not this number,
/// which is the mistake this shape is trying to make visible:
///
/// ```zig
/// gl.activeTexture(c.textureUnit(1));   // 0x84C1
/// gl.bindTexture(c.texture_2d, atlas);
/// gl.uniform1i(atlas_location, 1);      // 1, and never 0x84C1
/// ```
pub fn textureUnit(index: Uint) Enum {
    return texture0 + index;
}

/// The colour attachment point `index` names, for `framebufferTexture2D` and
/// `drawBuffers`. WebGL 1 has only `color_attachment0` unless
/// `WEBGL_draw_buffers` is present; WebGL 2 has at least eight.
pub fn colorAttachment(index: Uint) Enum {
    return color_attachment0 + index;
}

/// The cube map face `index` names, in the order GL numbers them: +X, -X, +Y,
/// -Y, +Z, -Z. That order is also the order the six faces of a cross-shaped
/// image are usually stored in, which is why a loop is worth having.
pub fn cubeFace(index: Uint) Enum {
    return texture_cube_map_positive_x + index;
}

test "the sums count from their base" {
    try testing.expectEqual(0x84C0, textureUnit(0));
    try testing.expectEqual(0x84C3, textureUnit(3));
    try testing.expectEqual(0x8CE0, colorAttachment(0));
    try testing.expectEqual(0x8CE1, colorAttachment(1));
    try testing.expectEqual(0x8515, cubeFace(0));
    try testing.expectEqual(0x851A, cubeFace(5));
}

test "the numbers are the ones the specification prints" {
    // Spot checks against the OpenGL ES 3.0 registry, because a token with a
    // digit wrong is a bug that draws nothing and says invalid_enum.
    try testing.expectEqual(0x0004, triangles);
    try testing.expectEqual(0x1406, float);
    try testing.expectEqual(0x8892, array_buffer);
    try testing.expectEqual(0x8B31, vertex_shader);
    try testing.expectEqual(0x8B30, fragment_shader);
    try testing.expectEqual(0x2601, linear);
    try testing.expectEqual(0x812F, clamp_to_edge);
    try testing.expectEqual(0x8CD5, framebuffer_complete);
    try testing.expectEqual(0x8D40, framebuffer);
    try testing.expectEqual(0x8D41, renderbuffer);
    try testing.expectEqual(0x8CA8, read_framebuffer);
    try testing.expectEqual(0x8CA9, draw_framebuffer);
    try testing.expectEqual(0x84FA, unsigned_int_24_8);
    try testing.expectEqual(0x8CAC, depth_component32f);
    try testing.expectEqual(0x0CF2, unpack_row_length);
    try testing.expectEqual(0xFFFFFFFF, invalid_index);
}

test "the clear bits or together without overlapping" {
    const all = color_buffer_bit | depth_buffer_bit | stencil_buffer_bit;
    try testing.expectEqual(0x4500, all);
    try testing.expectEqual(0, color_buffer_bit & depth_buffer_bit);
}
