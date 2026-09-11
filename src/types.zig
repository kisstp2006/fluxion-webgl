// SPDX-License-Identifier: BSL-1.0

//! The types WebGL is written in, spelled as Zig types.
//!
//! `fluxion-gl` aliases the C types - `c_int`, `c_uint` - because a desktop
//! table has to match the widths the *driver* was compiled with, and only the
//! C compiler knows what those are. Here there is no driver and no C
//! compiler. The other side of every call is JavaScript, and what sits
//! between the two is the WebAssembly import ABI, which has exactly four
//! types: `i32`, `i64`, `f32`, `f64`. So these are fixed widths, written
//! down, and that is not a simplification - it is the actual contract.
//!
//! WebGL's own IDL says `GLenum` is an `unsigned long`, which in Web IDL is
//! 32 bits and not the `long` of any C compiler. `u32` is the whole story.
//!
//! The one type with anything to it is `Object`, and it is worth reading
//! twice. Desktop GL hands out integers: `glGenBuffers` writes a `GLuint` and
//! that number *is* the buffer. WebGL hands out garbage-collected JavaScript
//! objects - a `WebGLBuffer` - and an object cannot cross into linear memory.
//! So the glue keeps them in an array and hands back the index. See `Object`.

const std = @import("std");
const testing = std.testing;

/// `GLenum`: a token from `enums`. One flat numbering shared by every
/// argument of every call, inherited from OpenGL ES 2.0 - which is why
/// `linear` is a texture filter and `nearest` is one too, and nothing but the
/// spelling keeps either out of a blend equation.
pub const Enum = u32;

/// `GLbitfield`: an or-ing of the `_bit` constants.
pub const Bitfield = u32;

/// `GLint`.
pub const Int = i32;

/// `GLuint`.
pub const Uint = u32;

/// `GLsizei`: a count or a size. Signed, because GL says so and WebGL kept
/// it; negative raises `invalid_value` in the browser rather than failing to
/// compile here.
pub const Sizei = i32;

/// `GLintptr`: a byte offset into a bound buffer.
pub const Intptr = i32;

/// `GLsizeiptr`: the size of a buffer's contents.
pub const Sizeiptr = i32;

/// `GLfloat`.
pub const Float = f32;

/// `GLclampf`: a float the implementation clamps to 0..1.
pub const Clampf = f32;

/// `GLboolean`.
///
/// Desktop GL returns 0 or 1 in a byte, and `fluxion-gl` calls that a `u8`
/// because Zig's `bool` has no defined size in a C signature. Across the wasm
/// boundary there are no bytes to disagree about: a JavaScript boolean
/// becomes the `i32` 0 or 1, and that is exactly what the WebAssembly spec
/// says an imported `i32` narrows to. So this one is a real `bool`, and
/// `isTrue` is a function nobody needs.
pub const Boolean = bool;

// -------------------------------------------------------------------------
// Objects
// -------------------------------------------------------------------------

/// A WebGL object - a buffer, a texture, a program, a shader, a vertex array,
/// a uniform location - as one number.
///
/// This is the difference that shapes the whole library. In desktop GL a
/// buffer name is a `GLuint` the driver made up, and passing it back is
/// passing an integer. In WebGL `gl.createBuffer()` returns a `WebGLBuffer`:
/// a live JavaScript object, owned by the garbage collector, with no numeric
/// value and no address. WebAssembly linear memory holds bytes, so there is
/// nothing an object could be stored *as*.
///
/// The glue solves it the way every wasm binding solves it: it keeps a
/// JavaScript array of the objects it has made, and hands back the index.
/// That index is what this type wraps. It means nothing to WebGL and
/// everything to the glue - which is the reverse of desktop GL, where the
/// number means nothing to the program and everything to the driver.
///
/// `none` is zero, and the glue reserves slot zero, so an object that was
/// never assigned is the null object rather than somebody else's texture.
///
/// ## Why this is a function
///
/// Every kind of object is a `u32`, and if they were all spelled `u32` - or
/// all spelled as one `Object` type with seven aliases - then binding a
/// texture where a buffer belongs would compile. It is a real mistake, it is
/// easy to make while typing, and WebGL answers it with `invalid_operation`
/// on a later call and a black screen on the frame after that.
///
/// So each kind gets a type of its own. Zig makes types by calling functions
/// that return them, and a function called twice with different comptime
/// arguments returns two *different* types - which is the whole mechanism
/// here. `Buffer` and `Texture` have identical layouts, identical methods and
/// no relationship the compiler will accept.
///
/// There is no run-time cost to any of it. All seven are a `u32` in the wasm
/// module, and the distinction exists only where mistakes are made.
pub fn Object(comptime label: []const u8) type {
    return enum(u32) {
        /// The null object. `bindBuffer(array_buffer, .none)` unbinds,
        /// exactly as `glBindBuffer(GL_ARRAY_BUFFER, 0)` does.
        none = 0,
        _,

        /// What this kind of object is called, for `format` and for a message
        /// that would otherwise have to say "object".
        pub const kind = label;

        /// The index, for handing to the glue.
        pub inline fn index(self: @This()) u32 {
            return @intFromEnum(self);
        }

        /// Whether the object is anything at all. A failed `createShader`
        /// comes back `.none`, and so does a uniform the linker removed.
        pub inline fn valid(self: @This()) bool {
            return self != .none;
        }

        pub fn format(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self == .none) return w.print("{s} none", .{label});
            try w.print("{s}#{d}", .{ label, @intFromEnum(self) });
        }
    };
}

/// A `WebGLBuffer`. See `Object`.
pub const Buffer = Object("Buffer");
/// A `WebGLTexture`. See `Object`.
pub const Texture = Object("Texture");
/// A `WebGLShader`. See `Object`.
pub const Shader = Object("Shader");
/// A `WebGLProgram`. See `Object`.
pub const Program = Object("Program");
/// A `WebGLVertexArrayObject`. WebGL 2, or `OES_vertex_array_object` on
/// WebGL 1. See `Object`.
pub const VertexArray = Object("VertexArray");
/// A `WebGLFramebuffer`. See `Object`.
pub const Framebuffer = Object("Framebuffer");
/// A `WebGLRenderbuffer`. See `Object`.
pub const Renderbuffer = Object("Renderbuffer");
/// A `WebGLSampler`: how a texture is filtered and wrapped, kept apart from
/// the texture so one picture can be read two ways. WebGL 2 only. See
/// `Object`.
pub const Sampler = Object("Sampler");

/// A `WebGLUniformLocation`.
///
/// The one object that is not a handle to something you created, and the one
/// that is routinely `.none` on purpose: a uniform the shader declares but
/// never reads is removed by the linker, and `getUniformLocation` answers
/// null for it. That is not an error, and setting a `.none` location is
/// defined to do nothing - so the usual shape is to look them all up after
/// linking and set them without checking.
pub const UniformLocation = Object("UniformLocation");

test "an object is a number with a null" {
    // The null object is what unbinding passes, and what a failed create
    // comes back as.
    const nothing: Buffer = .none;
    try testing.expect(!nothing.valid());
    try testing.expectEqual(0, nothing.index());

    // A real one is the glue's array index, unchanged.
    const buffer: Buffer = @enumFromInt(7);
    try testing.expect(buffer.valid());
    try testing.expectEqual(7, buffer.index());
}

test "the seven kinds are seven types, not seven names for one" {
    // Same layout, same methods, and no relationship the compiler accepts.
    // This is what stops a texture being bound where a buffer belongs.
    try testing.expect(Buffer != Texture);
    try testing.expect(Program != Shader);
    try testing.expect(Framebuffer != Renderbuffer);
    try testing.expect(VertexArray != UniformLocation);
    try testing.expect(Sampler != Texture);

    // Calling the constructor twice the same way gives one type back, which
    // is what makes the aliases above usable at all.
    try testing.expectEqual(Buffer, Object("Buffer"));

    // And all of them are a u32 in the module.
    try testing.expectEqual(4, @sizeOf(Buffer));
    try testing.expectEqual(4, @sizeOf(UniformLocation));
}

test "objects format as what they are" {
    var text: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text);

    try w.print("{f}", .{@as(Buffer, .none)});
    try testing.expectEqualStrings("Buffer none", w.buffered());

    w = .fixed(&text);
    try w.print("{f}", .{@as(Texture, @enumFromInt(3))});
    try testing.expectEqualStrings("Texture#3", w.buffered());
}

test "the widths are the ABI's, not a C compiler's" {
    // Fixed on every target this can be built for, which is the point: the
    // other side is JavaScript, not a driver somebody else compiled.
    try testing.expectEqual(4, @sizeOf(Enum));
    try testing.expectEqual(4, @sizeOf(Int));
    try testing.expectEqual(4, @sizeOf(Float));
}
