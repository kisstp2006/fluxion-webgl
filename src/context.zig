// SPDX-License-Identifier: BSL-1.0

//! The WebGL calls, as Zig rather than as wire.
//!
//! `api.raw` is the boundary exactly as WebAssembly defines it: numbers,
//! loose pointers, lengths passed beside them, and failure reported the way
//! GL has always reported it, which is not at all until you ask. This is the
//! same calls with Zig's own machinery over them, and there are four things
//! it adds:
//!
//!   * **Slices stay slices.** `bufferData` takes `[]const f32` or a slice of
//!     any struct and does the pointer-and-length split itself, so the one
//!     place a length can be wrong is not in your program.
//!   * **Objects have types.** A `Buffer` is not a `Texture` is not a
//!     `Program`, though all three are a `u32` underneath. Passing one where
//!     another belongs is a compile error rather than an `invalid_operation`
//!     three frames later.
//!   * **Failure is an error union.** A shader that does not compile comes
//!     back as `error.CompileFailed` with the driver's log written to a
//!     writer you own, rather than as a program that links to nothing and
//!     draws black.
//!   * **The context knows what it is.** `init` asks once, and `version`,
//!     `limits` and `has` answer without going back across the boundary.
//!
//! What it does not add is state tracking. There is no shadow copy of what is
//! bound, no attempt to skip a redundant call, and no ordering rules beyond
//! WebGL's own. That belongs a layer up, in whatever draws.

const std = @import("std");
const testing = std.testing;

const api = @import("api.zig");
const enums = @import("enums.zig");
const types = @import("types.zig");

const Buffer = types.Buffer;
const Enum = types.Enum;
const Float = types.Float;
const Framebuffer = types.Framebuffer;
const Int = types.Int;
const Program = types.Program;
const Renderbuffer = types.Renderbuffer;
const Sampler = types.Sampler;
const Shader = types.Shader;
const Sizei = types.Sizei;
const Texture = types.Texture;
const Uint = types.Uint;
const UniformLocation = types.UniformLocation;
const VertexArray = types.VertexArray;

const raw = api.raw;

/// What can go wrong that is worth stopping for.
///
/// GL's own errors are not in here, because GL does not raise them - it
/// records them and carries on, and a program that checked after every call
/// would spend more time asking than drawing. Those come from `checkError`,
/// when you want them. These are the failures that make the next call
/// pointless.
pub const Error = error{
    /// A shader did not compile. The log says why.
    CompileFailed,
    /// A program did not link. The log says why.
    LinkFailed,
    /// The implementation would not make the object - out of memory, or the
    /// context is gone.
    OutOfObjects,
    /// A framebuffer was assembled that the implementation will not render
    /// to. `checkFramebufferStatus` says which way.
    FramebufferIncomplete,
};

/// Which WebGL the page got.
pub const Version = enum {
    webgl1,
    webgl2,

    /// Whether this is at least `wanted`. `.webgl2` is a superset of
    /// `.webgl1` in every way that matters here.
    pub inline fn atLeast(self: Version, wanted: Version) bool {
        return @intFromEnum(self) >= @intFromEnum(wanted);
    }

    pub fn format(self: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(switch (self) {
            .webgl1 => "WebGL 1.0",
            .webgl2 => "WebGL 2.0",
        });
    }
};

/// The numbers a renderer has to plan around, asked once at `init`.
///
/// Every one of these has a floor the specification guarantees, and the floor
/// is lower than people expect: WebGL 1 promises a 64-pixel texture and eight
/// vertex attributes. Real hardware is far above that, and the phone in
/// somebody's pocket is closer to the floor than the desktop it was developed
/// on - which is the reason to read them rather than assume them.
pub const Limits = struct {
    max_texture_size: u32,
    max_cube_map_texture_size: u32,
    max_renderbuffer_size: u32,
    max_vertex_attribs: u32,
    max_texture_image_units: u32,
    max_combined_texture_image_units: u32,
    /// What a `bindBufferRange` offset into a uniform buffer is a multiple
    /// of. WebGL 2; nought on WebGL 1, which has no uniform buffers.
    uniform_buffer_offset_alignment: u32,
};

/// A WebGL context: what it is, and everything you can ask it to do.
///
/// The struct holds what was asked once and cached. The context itself lives
/// in JavaScript - there is only ever one per module, made by the glue before
/// the module was instantiated - so this is not a handle to it, and copying a
/// `Context` copies the cache rather than the canvas.
pub const Context = struct {
    version: Version,
    limits: Limits,

    /// How much of an info log this will carry back in one go. Longer logs
    /// are truncated with a line saying so, because the alternative is an
    /// allocator, and a shader log that runs past two kilobytes has already
    /// told you what is wrong in its first line.
    pub const log_limit = 2048;

    /// Ask the context what it is.
    ///
    /// Cheap, and worth doing once at startup rather than at the first draw:
    /// every call here crosses into JavaScript, and the answers do not change
    /// for the life of the context.
    pub fn init() Context {
        const version = detectVersion();
        return .{
            .version = version,
            .limits = .{
                .max_texture_size = intParameter(enums.max_texture_size),
                .max_cube_map_texture_size = intParameter(enums.max_cube_map_texture_size),
                .max_renderbuffer_size = intParameter(enums.max_renderbuffer_size),
                .max_vertex_attribs = intParameter(enums.max_vertex_attribs),
                .max_texture_image_units = intParameter(enums.max_texture_image_units),
                .max_combined_texture_image_units = intParameter(enums.max_combined_texture_image_units),
                // A WebGL 1 context answers an enum it has not got with an error.
                .uniform_buffer_offset_alignment = if (version == .webgl2) intParameter(enums.uniform_buffer_offset_alignment) else 0,
            },
        };
    }

    fn intParameter(pname: Enum) u32 {
        const value = raw.getParameterInt(pname);
        return if (value < 0) 0 else @intCast(value);
    }

    fn detectVersion() Version {
        // `GL_VERSION` on a WebGL context reads "WebGL 2.0 (OpenGL ES 3.0
        // Chromium)" or "WebGL 1.0 (OpenGL ES 2.0 Chromium)". The digit after
        // the space is the whole question, and there is no integer query that
        // answers it on WebGL 1 - `getParameter(VERSION)` is the only way.
        var text: [64]u8 = undefined;
        const n = @min(raw.getParameterString(enums.version, &text, text.len), text.len);
        const reported = text[0..n];

        const prefix = "WebGL ";
        if (std.mem.indexOf(u8, reported, prefix)) |at| {
            const rest = reported[at + prefix.len ..];
            if (rest.len > 0 and rest[0] >= '2') return .webgl2;
        }
        return .webgl1;
    }

    /// One of the four strings a context will describe itself with -
    /// `vendor`, `renderer`, `version`, `shading_language_version` - copied
    /// into `buffer`.
    ///
    /// Answers the part of it that fitted. `renderer` is the interesting one
    /// and the one browsers lie about: without `WEBGL_debug_renderer_info` it
    /// is a generic string chosen to stop pages fingerprinting the machine.
    pub fn string(self: Context, name: Enum, buffer: []u8) []const u8 {
        _ = self;
        const full = raw.getParameterString(name, buffer.ptr, @intCast(buffer.len));
        return buffer[0..@min(full, buffer.len)];
    }

    /// Whether a call needs a version this context has not got.
    ///
    /// The one that matters in practice is vertex array objects: WebGL 2 has
    /// them, WebGL 1 has them only through `OES_vertex_array_object`, and the
    /// glue papers over the difference where the extension is present. This
    /// is how a program asks before it depends on it.
    pub inline fn has(self: Context, feature: Feature) bool {
        return switch (feature) {
            .vertex_arrays, .instancing, .sized_formats, .uniform_blocks, .samplers => self.version.atLeast(.webgl2),
        };
    }

    pub const Feature = enum {
        /// `createVertexArray` and friends.
        vertex_arrays,
        /// `drawArraysInstanced`, `vertexAttribDivisor`.
        instancing,
        /// `rgba8` and the rest, rather than `rgba` inferring its own size.
        sized_formats,
        /// `uniform_buffer`, `uniformBlockIndex`, `bindBufferBase`.
        uniform_blocks,
        /// `createSampler` and friends. WebGL 1 has no extension for them:
        /// filtering is a property of the texture there, and that is all.
        samplers,
    };

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    pub inline fn viewport(_: Context, x: i32, y: i32, width: i32, height: i32) void {
        raw.viewport(x, y, width, height);
    }

    pub inline fn scissor(_: Context, x: i32, y: i32, width: i32, height: i32) void {
        raw.scissor(x, y, width, height);
    }

    pub inline fn clearColor(_: Context, r: f32, g: f32, b: f32, a: f32) void {
        raw.clearColor(r, g, b, a);
    }

    pub inline fn clearDepth(_: Context, depth: f32) void {
        raw.clearDepth(depth);
    }

    pub inline fn clearStencil(_: Context, s: i32) void {
        raw.clearStencil(s);
    }

    pub inline fn clear(_: Context, mask: u32) void {
        raw.clear(mask);
    }

    pub inline fn enable(_: Context, cap: Enum) void {
        raw.enable(cap);
    }

    pub inline fn disable(_: Context, cap: Enum) void {
        raw.disable(cap);
    }

    pub inline fn depthFunc(_: Context, func: Enum) void {
        raw.depthFunc(func);
    }

    pub inline fn depthMask(_: Context, writable: bool) void {
        raw.depthMask(writable);
    }

    /// Which part of the depth buffer clip space's -1 to 1 lands in. Zero to
    /// one, the default, is the whole of it.
    pub inline fn depthRange(_: Context, near: f32, far: f32) void {
        raw.depthRange(near, far);
    }

    pub inline fn colorMask(_: Context, r: bool, g: bool, b: bool, a: bool) void {
        raw.colorMask(r, g, b, a);
    }

    pub inline fn cullFace(_: Context, mode: Enum) void {
        raw.cullFace(mode);
    }

    pub inline fn frontFace(_: Context, mode: Enum) void {
        raw.frontFace(mode);
    }

    pub inline fn blendFunc(_: Context, src: Enum, dst: Enum) void {
        raw.blendFunc(src, dst);
    }

    pub inline fn blendEquation(_: Context, mode: Enum) void {
        raw.blendEquation(mode);
    }

    /// `blendFunc`, with colour and alpha given factors of their own.
    ///
    /// What straight alpha actually wants: colour weighted by the source's
    /// alpha, and the alpha channel itself accumulated with `one`, so that
    /// drawing onto an opaque target leaves it opaque. `blendFunc` would
    /// weight the alpha by itself too and leave holes a compositor can see.
    pub inline fn blendFuncSeparate(_: Context, src_rgb: Enum, dst_rgb: Enum, src_alpha: Enum, dst_alpha: Enum) void {
        raw.blendFuncSeparate(src_rgb, dst_rgb, src_alpha, dst_alpha);
    }

    pub inline fn blendEquationSeparate(_: Context, mode_rgb: Enum, mode_alpha: Enum) void {
        raw.blendEquationSeparate(mode_rgb, mode_alpha);
    }

    pub inline fn pixelStorei(_: Context, pname: Enum, param: i32) void {
        raw.pixelStorei(pname, param);
    }

    pub inline fn finish(_: Context) void {
        raw.finish();
    }

    pub inline fn flush(_: Context) void {
        raw.flush();
    }

    /// Drain the error queue and answer the first thing in it, or null.
    ///
    /// Draining rather than reading one, for the same reason `fluxion-gl`
    /// does: GL records errors and hands them back one call at a time, so a
    /// program that reads a single `getError` after a frame is reading the
    /// oldest mistake and leaving the rest to surprise the next frame.
    pub fn checkError(_: Context) ?Enum {
        var first: ?Enum = null;
        // Bounded, because a context that has been lost answers
        // `context_lost_webgl` for ever and a `while (true)` here would hang
        // the page rather than report it.
        for (0..16) |_| {
            const code = raw.getError();
            if (code == enums.no_error) break;
            if (first == null) first = code;
        }
        return first;
    }

    // ---------------------------------------------------------------------
    // Buffers
    // ---------------------------------------------------------------------

    pub fn createBuffer(_: Context) Error!Buffer {
        const name = raw.createBuffer();
        if (name == 0) return error.OutOfObjects;
        return @enumFromInt(name);
    }

    pub inline fn deleteBuffer(_: Context, buffer: Buffer) void {
        raw.deleteBuffer(buffer.index());
    }

    pub inline fn bindBuffer(_: Context, target: Enum, buffer: Buffer) void {
        raw.bindBuffer(target, buffer.index());
    }

    /// Fill the buffer bound to `target` from a slice of anything.
    ///
    /// The element type is whatever you pass - `f32`, `u16`, a vertex struct -
    /// and the bytes are its bytes. This is where Zig earns its place over
    /// the C spelling of the same call: `glBufferData` takes a `void*` and a
    /// size in bytes, and every renderer ever written has at some point
    /// passed the element count where the byte count belonged and got a
    /// quarter of a mesh. Here the length is not a parameter at all.
    ///
    /// The slice must be alive for the duration of the call and need not be
    /// afterwards - the implementation copies. A `packed` or `extern` struct
    /// is worth using for the element type, because a plain Zig struct may be
    /// reordered and the shader is expecting the order you wrote down.
    pub fn bufferData(_: Context, target: Enum, data: anytype, usage: Enum) void {
        const bytes = std.mem.sliceAsBytes(data);
        raw.bufferData(target, bytes.ptr, @intCast(bytes.len), usage);
    }

    /// Overwrite part of the buffer bound to `target`, starting `offset`
    /// bytes in. The buffer must already be at least that large.
    pub fn bufferSubData(_: Context, target: Enum, offset: usize, data: anytype) void {
        const bytes = std.mem.sliceAsBytes(data);
        raw.bufferSubData(target, @intCast(offset), bytes.ptr, @intCast(bytes.len));
    }

    /// Give the buffer bound to `target` room for `size` bytes, zeroed, and
    /// nothing in them yet.
    ///
    /// What a buffer written every frame is made with, and a uniform buffer:
    /// the storage now, the contents from `bufferSubData` later. WebGL
    /// spells it as `bufferData` with a number where the data would go; the
    /// wire cannot tell the two apart, so here it has a name of its own.
    pub inline fn bufferDataSize(_: Context, target: Enum, size: usize, usage: Enum) void {
        raw.bufferDataSize(target, @intCast(size), usage);
    }

    /// Bind `buffer` to slot `index` of an indexed target. For
    /// `uniform_buffer` that is the slot a block reads from - see
    /// `uniformBlockBinding` for how a block is pointed at one. WebGL 2.
    pub inline fn bindBufferBase(_: Context, target: Enum, index: u32, buffer: Buffer) void {
        raw.bindBufferBase(target, index, buffer.index());
    }

    /// Bind `size` bytes of `buffer` from `offset` to slot `index` of an
    /// indexed target. For `uniform_buffer` the offset is a multiple of
    /// `uniform_buffer_offset_alignment`. WebGL 2.
    pub inline fn bindBufferRange(_: Context, target: Enum, index: u32, buffer: Buffer, offset: u32, size: u32) void {
        raw.bindBufferRange(target, index, buffer.index(), offset, size);
    }

    // ---------------------------------------------------------------------
    // Vertex arrays and attributes
    // ---------------------------------------------------------------------

    /// A vertex array object: the whole of what is bound where, remembered,
    /// so a draw is one call rather than a dozen.
    ///
    /// WebGL 2 has these; WebGL 1 has them only through
    /// `OES_vertex_array_object`. Ask `has(.vertex_arrays)` first if the page
    /// might get either.
    pub fn createVertexArray(_: Context) Error!VertexArray {
        const name = raw.createVertexArray();
        if (name == 0) return error.OutOfObjects;
        return @enumFromInt(name);
    }

    pub inline fn deleteVertexArray(_: Context, array: VertexArray) void {
        raw.deleteVertexArray(array.index());
    }

    pub inline fn bindVertexArray(_: Context, array: VertexArray) void {
        raw.bindVertexArray(array.index());
    }

    pub inline fn enableVertexAttribArray(_: Context, index: u32) void {
        raw.enableVertexAttribArray(index);
    }

    pub inline fn disableVertexAttribArray(_: Context, index: u32) void {
        raw.disableVertexAttribArray(index);
    }

    /// Where attribute `index` reads from in the buffer currently bound to
    /// `array_buffer`, and how to read it.
    ///
    /// `offset` is a byte offset, and here it is spelled as one. Desktop GL
    /// declares this parameter as a pointer and wants an integer in it, which
    /// is why `fluxion-gl` needs an `offset()` helper to avoid the illegal
    /// `@ptrFromInt(0)`. WebGL fixed that: the IDL says `GLintptr`, so the
    /// number is just a number.
    pub inline fn vertexAttribPointer(
        _: Context,
        index: u32,
        size: i32,
        kind: Enum,
        normalized: bool,
        stride: i32,
        offset: i32,
    ) void {
        raw.vertexAttribPointer(index, size, kind, normalized, stride, offset);
    }

    /// `vertexAttribPointer` for an attribute the shader declares as `int`,
    /// `uint` or one of their vectors. The numbers arrive as integers; the
    /// other call would have made floats of them on the way in, and a shader
    /// reading an `ivec4` from one of those reads nonsense. WebGL 2.
    pub inline fn vertexAttribIPointer(_: Context, index: u32, size: i32, kind: Enum, stride: i32, offset: i32) void {
        raw.vertexAttribIPointer(index, size, kind, stride, offset);
    }

    /// How many instances share one value of attribute `index`. Zero - the
    /// default - is per-vertex; one is per-instance.
    pub inline fn vertexAttribDivisor(_: Context, index: u32, divisor: u32) void {
        raw.vertexAttribDivisor(index, divisor);
    }

    // ---------------------------------------------------------------------
    // Shaders and programs
    // ---------------------------------------------------------------------

    /// Compile one shader, or fail with the log written to `log`.
    ///
    /// The caller owns the writer, which is what makes this usable from
    /// anywhere: a browser build sends it to the console, a test sends it to
    /// a fixed buffer and reads it back.
    ///
    /// On WebGL 2 the source must begin with `#version 300 es` on the very
    /// first line, before any whitespace or comment - and a shader without it
    /// is compiled as GLSL ES 1.00 rather than rejected, so the error you get
    /// is about `in` being an unknown identifier rather than about the
    /// version being missing. That is the single most common way to lose an
    /// hour here.
    pub fn compileShader(
        self: Context,
        kind: Enum,
        source: []const u8,
        log: *std.Io.Writer,
    ) (Error || std.Io.Writer.Error)!Shader {
        const name = raw.createShader(kind);
        if (name == 0) return error.OutOfObjects;
        const shader: Shader = @enumFromInt(name);
        // If anything below fails the shader is not the caller's to free,
        // because they never received it.
        errdefer raw.deleteShader(name);

        raw.shaderSource(name, source.ptr, @intCast(source.len));
        raw.compileShader(name);

        if (raw.getShaderParameter(name, enums.compile_status) == 0) {
            try self.writeLog(log, name, raw.getShaderInfoLog);
            return error.CompileFailed;
        }
        return shader;
    }

    pub inline fn deleteShader(_: Context, shader: Shader) void {
        raw.deleteShader(shader.index());
    }

    /// Link a vertex and a fragment shader into a program, or fail with the
    /// log written to `log`.
    ///
    /// The shaders stay yours to delete, and deleting them straight after a
    /// successful link is the usual thing: a program keeps what it needs, and
    /// `deleteShader` on an attached shader marks it for deletion rather than
    /// pulling it out from under the program.
    pub fn linkProgram(
        self: Context,
        vertex: Shader,
        fragment: Shader,
        log: *std.Io.Writer,
    ) (Error || std.Io.Writer.Error)!Program {
        const name = raw.createProgram();
        if (name == 0) return error.OutOfObjects;
        errdefer raw.deleteProgram(name);

        raw.attachShader(name, vertex.index());
        raw.attachShader(name, fragment.index());
        raw.linkProgram(name);

        if (raw.getProgramParameter(name, enums.link_status) == 0) {
            try self.writeLog(log, name, raw.getProgramInfoLog);
            return error.LinkFailed;
        }
        return @enumFromInt(name);
    }

    /// Both shaders and the program, in one call, with the intermediate
    /// shaders cleaned up either way.
    ///
    /// This is what a renderer actually wants, and writing it out by hand is
    /// six calls of which two are `errdefer`s people forget. The log names
    /// which stage failed before the driver's own text.
    pub fn buildProgram(
        self: Context,
        vertex_source: []const u8,
        fragment_source: []const u8,
        log: *std.Io.Writer,
    ) (Error || std.Io.Writer.Error)!Program {
        const vertex = self.compileShader(enums.vertex_shader, vertex_source, log) catch |err| {
            try log.writeAll("\n(in the vertex shader)\n");
            return err;
        };
        defer raw.deleteShader(vertex.index());

        const fragment = self.compileShader(enums.fragment_shader, fragment_source, log) catch |err| {
            try log.writeAll("\n(in the fragment shader)\n");
            return err;
        };
        defer raw.deleteShader(fragment.index());

        return self.linkProgram(vertex, fragment, log);
    }

    /// Copy an info log across the boundary and into `log`.
    ///
    /// `getter` is a function *value* rather than a name, so the same body
    /// serves shaders and programs - and because it is comptime-known at
    /// every call site, the compiler turns it back into a direct call. This
    /// is the shape a C binding would need a macro or a `void*` for.
    fn writeLog(
        _: Context,
        log: *std.Io.Writer,
        name: Uint,
        comptime getter: fn (Uint, [*]u8, u32) callconv(if (api.is_wasm) .c else .auto) u32,
    ) std.Io.Writer.Error!void {
        var scratch: [log_limit]u8 = undefined;
        const full = getter(name, &scratch, scratch.len);
        const kept = @min(full, scratch.len);
        try log.writeAll(scratch[0..kept]);
        if (full > kept) try log.print("\n... {d} more bytes\n", .{full - kept});
    }

    pub inline fn deleteProgram(_: Context, program: Program) void {
        raw.deleteProgram(program.index());
    }

    pub inline fn useProgram(_: Context, program: Program) void {
        raw.useProgram(program.index());
    }

    /// Pin an attribute to a location before linking. An alternative to
    /// `layout(location = N)` in the shader, and the only way to do it in
    /// GLSL ES 1.00, which has no such qualifier.
    pub inline fn bindAttribLocation(_: Context, program: Program, index: u32, name: []const u8) void {
        raw.bindAttribLocation(program.index(), index, name.ptr, @intCast(name.len));
    }

    /// Where an attribute ended up, or null if the linker removed it.
    pub fn attribLocation(_: Context, program: Program, name: []const u8) ?u32 {
        const at = raw.getAttribLocation(program.index(), name.ptr, @intCast(name.len));
        return if (at < 0) null else @intCast(at);
    }

    /// The handle for a uniform, or `.none` if the linker removed it.
    ///
    /// `.none` is not an error and is not worth branching on: setting it is
    /// defined to do nothing. A uniform the shader declares but never reads
    /// is removed, and so is one whose only use got folded away - so the
    /// usual shape is to look them all up after linking and set them without
    /// checking.
    pub fn uniformLocation(_: Context, program: Program, name: []const u8) UniformLocation {
        return @enumFromInt(raw.getUniformLocation(program.index(), name.ptr, @intCast(name.len)));
    }

    /// Which of the program's uniform blocks is called `name`, or null where
    /// there is none - never declared, or removed by the linker because
    /// nothing reads it. WebGL 2.
    ///
    /// Null rather than `invalid_index`, because that number is a real `u32`
    /// and would go on to `uniformBlockBinding` without complaint. Unlike a
    /// missing uniform location, a missing block is usually worth stopping
    /// for: a block is where a whole frame's numbers are, and a program that
    /// binds a buffer to nothing draws with zeros.
    pub fn uniformBlockIndex(_: Context, program: Program, name: []const u8) ?u32 {
        const index = raw.getUniformBlockIndex(program.index(), name.ptr, @intCast(name.len));
        return if (index == enums.invalid_index) null else index;
    }

    /// Point uniform block `block` of `program` at uniform buffer slot
    /// `binding` - the slot `bindBufferBase` fills.
    ///
    /// GLSL ES 3.00 has no `layout(binding = n)`, so this call is the only
    /// place a block learns its slot, and it is remembered by the program:
    /// once after linking is enough. WebGL 2.
    pub inline fn uniformBlockBinding(_: Context, program: Program, block: u32, binding: u32) void {
        raw.uniformBlockBinding(program.index(), block, binding);
    }

    // ---------------------------------------------------------------------
    // Uniforms
    // ---------------------------------------------------------------------

    /// An integer, and - the reason this is the one you reach for most - the
    /// *unit number* a sampler reads from. Not the `texture0 + n` token: see
    /// `enums.textureUnit`.
    pub inline fn uniform1i(_: Context, location: UniformLocation, v: i32) void {
        raw.uniform1i(location.index(), v);
    }

    pub inline fn uniform1f(_: Context, location: UniformLocation, v: f32) void {
        raw.uniform1f(location.index(), v);
    }

    pub inline fn uniform2f(_: Context, location: UniformLocation, x: f32, y: f32) void {
        raw.uniform2f(location.index(), x, y);
    }

    pub inline fn uniform3f(_: Context, location: UniformLocation, x: f32, y: f32, z: f32) void {
        raw.uniform3f(location.index(), x, y, z);
    }

    pub inline fn uniform4f(_: Context, location: UniformLocation, x: f32, y: f32, z: f32, w: f32) void {
        raw.uniform4f(location.index(), x, y, z, w);
    }

    /// A four-by-four, column-major, which is the layout GL has always wanted.
    ///
    /// The parameter is sixteen floats rather than a matrix type, because a
    /// binding has no business having an opinion about your vectors - the
    /// same reason `fluxion-gl` has no matrices in it. A
    /// [Fluxion Math](https://github.com/kisstp2006/fluxion-math) `Mat4` is an
    /// `extern struct` of four `Vec4` columns, so it is already exactly these
    /// sixteen floats in exactly this order, and `array` says so:
    ///
    /// ```zig
    /// const mvp = projection.mul(view).mul(model);
    /// const floats = mvp.array();
    /// gl.uniformMatrix4(mvp_location, &floats);
    /// ```
    ///
    /// There is no `transpose` parameter because the answer is always false.
    /// WebGL 1 rejects `true` outright, and a program that needs the other
    /// layout has a bug one layer up.
    pub inline fn uniformMatrix4(_: Context, location: UniformLocation, values: *const [16]f32) void {
        raw.uniformMatrix4fv(location.index(), 1, false, values);
    }

    /// A three-by-three, column-major. What a normal matrix is.
    pub inline fn uniformMatrix3(_: Context, location: UniformLocation, values: *const [9]f32) void {
        raw.uniformMatrix3fv(location.index(), 1, false, values);
    }

    // ---------------------------------------------------------------------
    // Textures
    // ---------------------------------------------------------------------

    pub fn createTexture(_: Context) Error!Texture {
        const name = raw.createTexture();
        if (name == 0) return error.OutOfObjects;
        return @enumFromInt(name);
    }

    pub inline fn deleteTexture(_: Context, texture: Texture) void {
        raw.deleteTexture(texture.index());
    }

    pub inline fn bindTexture(_: Context, target: Enum, texture: Texture) void {
        raw.bindTexture(target, texture.index());
    }

    /// Which unit the next `bindTexture` binds into. Takes the token, not the
    /// index: `enums.textureUnit(1)`, never `1`.
    pub inline fn activeTexture(_: Context, unit: Enum) void {
        raw.activeTexture(unit);
    }

    pub inline fn texParameteri(_: Context, target: Enum, pname: Enum, param: i32) void {
        raw.texParameteri(target, pname, param);
    }

    pub inline fn generateMipmap(_: Context, target: Enum) void {
        raw.generateMipmap(target);
    }

    /// The description of one level of a texture, and optionally its pixels.
    pub const Image = struct {
        target: Enum = enums.texture_2d,
        level: i32 = 0,
        /// What the implementation stores. On WebGL 2 a sized format -
        /// `rgba8`, `srgb8_alpha8`; on WebGL 1 the same token as `format`.
        internal_format: Enum = enums.rgba,
        width: i32,
        height: i32,
        /// What `pixels` are laid out as.
        format: Enum = enums.rgba,
        /// What one channel of `pixels` is.
        kind: Enum = enums.unsigned_byte,
        /// The pixels, or null to allocate the storage and leave it undefined
        /// - which is what a render target wants.
        pixels: ?[]const u8 = null,
    };

    /// Upload, or allocate, one level of the texture bound to `image.target`.
    pub fn texImage2D(_: Context, image: Image) void {
        const bytes = image.pixels orelse &[_]u8{};
        // A null upload still needs an address the glue can ignore, and a
        // zero-length slice has one that is aligned and never read.
        raw.texImage2D(
            image.target,
            image.level,
            @intCast(image.internal_format),
            image.width,
            image.height,
            0,
            image.format,
            image.kind,
            bytes.ptr,
            @intCast(bytes.len),
        );
    }

    /// Overwrite a rectangle of the texture bound to `image.target`.
    /// `image.pixels` is required here: there is nothing to allocate.
    pub fn texSubImage2D(_: Context, x: i32, y: i32, image: Image) void {
        const bytes = image.pixels orelse &[_]u8{};
        raw.texSubImage2D(
            image.target,
            image.level,
            x,
            y,
            image.width,
            image.height,
            image.format,
            image.kind,
            bytes.ptr,
            @intCast(bytes.len),
        );
    }

    // ---------------------------------------------------------------------
    // Samplers
    // ---------------------------------------------------------------------

    /// A sampler object: filtering and wrapping, held apart from the texture.
    ///
    /// Bound to a texture unit, it overrides whatever the texture's own
    /// `texParameteri` said - so one picture can be read smoothly in one draw
    /// and in hard pixels in the next without being touched in between.
    /// WebGL 2; ask `has(.samplers)` first if the page might get WebGL 1.
    pub fn createSampler(_: Context) Error!Sampler {
        const name = raw.createSampler();
        if (name == 0) return error.OutOfObjects;
        return @enumFromInt(name);
    }

    pub inline fn deleteSampler(_: Context, sampler: Sampler) void {
        raw.deleteSampler(sampler.index());
    }

    /// Read texture unit `unit` through `sampler`, or through the texture's
    /// own parameters again with `.none`. The unit is the index - `1`, not
    /// `textureUnit(1)` - which is the opposite of `activeTexture` and the
    /// same as the number a sampler uniform is set to.
    pub inline fn bindSampler(_: Context, unit: u32, sampler: Sampler) void {
        raw.bindSampler(unit, sampler.index());
    }

    pub inline fn samplerParameteri(_: Context, sampler: Sampler, pname: Enum, param: i32) void {
        raw.samplerParameteri(sampler.index(), pname, param);
    }

    // ---------------------------------------------------------------------
    // Framebuffers
    // ---------------------------------------------------------------------

    pub fn createFramebuffer(_: Context) Error!Framebuffer {
        const name = raw.createFramebuffer();
        if (name == 0) return error.OutOfObjects;
        return @enumFromInt(name);
    }

    pub inline fn deleteFramebuffer(_: Context, fbo: Framebuffer) void {
        raw.deleteFramebuffer(fbo.index());
    }

    /// Bind, or - with `.none` - go back to drawing at the canvas.
    pub inline fn bindFramebuffer(_: Context, target: Enum, fbo: Framebuffer) void {
        raw.bindFramebuffer(target, fbo.index());
    }

    pub inline fn framebufferTexture2D(
        _: Context,
        target: Enum,
        attachment: Enum,
        tex_target: Enum,
        texture: Texture,
        level: i32,
    ) void {
        raw.framebufferTexture2D(target, attachment, tex_target, texture.index(), level);
    }

    /// Whether the framebuffer bound to `target` can be rendered to, as an
    /// error union rather than a token to remember the spelling of.
    pub fn checkFramebuffer(_: Context, target: Enum) Error!void {
        if (raw.checkFramebufferStatus(target) != enums.framebuffer_complete) {
            return error.FramebufferIncomplete;
        }
    }

    pub fn createRenderbuffer(_: Context) Error!Renderbuffer {
        const name = raw.createRenderbuffer();
        if (name == 0) return error.OutOfObjects;
        return @enumFromInt(name);
    }

    pub inline fn deleteRenderbuffer(_: Context, rbo: Renderbuffer) void {
        raw.deleteRenderbuffer(rbo.index());
    }

    pub inline fn bindRenderbuffer(_: Context, target: Enum, rbo: Renderbuffer) void {
        raw.bindRenderbuffer(target, rbo.index());
    }

    pub inline fn renderbufferStorage(_: Context, target: Enum, format: Enum, width: i32, height: i32) void {
        raw.renderbufferStorage(target, format, width, height);
    }

    pub inline fn renderbufferStorageMultisample(_: Context, target: Enum, samples: i32, format: Enum, width: i32, height: i32) void {
        raw.renderbufferStorageMultisample(target, samples, format, width, height);
    }

    pub inline fn framebufferRenderbuffer(
        _: Context,
        target: Enum,
        attachment: Enum,
        rb_target: Enum,
        rbo: Renderbuffer,
    ) void {
        raw.framebufferRenderbuffer(target, attachment, rb_target, rbo.index());
    }

    pub inline fn blitFramebuffer(
        _: Context,
        src_x0: i32,
        src_y0: i32,
        src_x1: i32,
        src_y1: i32,
        dst_x0: i32,
        dst_y0: i32,
        dst_x1: i32,
        dst_y1: i32,
        mask: u32,
        filter: Enum,
    ) void {
        raw.blitFramebuffer(src_x0, src_y0, src_x1, src_y1, dst_x0, dst_y0, dst_x1, dst_y1, mask, filter);
    }

    pub inline fn internalformatSamples(_: Context, target: Enum, internal_format: Enum, out: []i32) []i32 {
        const count = raw.getInternalformatSamples(target, internal_format, out.ptr, @intCast(out.len));
        return out[0..@min(count, out.len)];
    }

    /// Read a rectangle of the bound framebuffer into `pixels`.
    ///
    /// The rows come back **bottom-up**, which is GL's convention and not
    /// this library's choice. `fluxion-rhi` flips them so that every backend
    /// agrees the origin is the top left; here the rows are left as GL
    /// produced them and this comment is the warning.
    ///
    /// `pixels` must be at least `width * height * 4` bytes for the usual
    /// `rgba`/`unsigned_byte` pair. The call is a pipeline stall in any case:
    /// it waits for everything queued to finish.
    pub fn readPixels(
        _: Context,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        format: Enum,
        kind: Enum,
        pixels: []u8,
    ) void {
        raw.readPixels(x, y, width, height, format, kind, pixels.ptr, @intCast(pixels.len));
    }

    // ---------------------------------------------------------------------
    // Drawing
    // ---------------------------------------------------------------------

    pub inline fn drawArrays(_: Context, mode: Enum, first: i32, count: i32) void {
        raw.drawArrays(mode, first, count);
    }

    /// `offset` is in **bytes** into the bound `element_array_buffer`, not in
    /// indices - so the second half of a `u16` index buffer of 600 starts at
    /// 600, not at 300.
    pub inline fn drawElements(_: Context, mode: Enum, count: i32, kind: Enum, offset: i32) void {
        raw.drawElements(mode, count, kind, offset);
    }

    pub inline fn drawArraysInstanced(_: Context, mode: Enum, first: i32, count: i32, instances: i32) void {
        raw.drawArraysInstanced(mode, first, count, instances);
    }

    pub inline fn drawElementsInstanced(
        _: Context,
        mode: Enum,
        count: i32,
        kind: Enum,
        offset: i32,
        instances: i32,
    ) void {
        raw.drawElementsInstanced(mode, count, kind, offset, instances);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const c = enums;

test "init asks the context what it is, once" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    try testing.expectEqual(.webgl2, gl.version);
    try testing.expect(gl.version.atLeast(.webgl1));
    try testing.expect(gl.has(.vertex_arrays));
    try testing.expectEqual(2048, gl.limits.max_texture_size);
    try testing.expectEqual(16, gl.limits.max_vertex_attribs);
}

test "a slice keeps its length across the boundary" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    const buffer = try gl.createBuffer();
    defer gl.deleteBuffer(buffer);

    // Three vertices of two floats: six floats, twenty-four bytes. The count
    // is never written down, which is the point.
    const vertices = [_]f32{ -0.5, -0.5, 0.5, -0.5, 0.0, 0.5 };
    gl.bindBuffer(c.array_buffer, buffer);
    gl.bufferData(c.array_buffer, &vertices, c.static_draw);

    try testing.expectEqual(24, api.stub.state.last_upload_len);
}

test "a struct of vertices goes over as its bytes" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    // `extern` so the field order is the one the shader is expecting rather
    // than one the compiler chose.
    const Vertex = extern struct { x: f32, y: f32, u: f32, v: f32 };
    const quad = [_]Vertex{
        .{ .x = -1, .y = -1, .u = 0, .v = 0 },
        .{ .x = 1, .y = -1, .u = 1, .v = 0 },
        .{ .x = 0, .y = 1, .u = 0.5, .v = 1 },
    };

    gl.bufferData(c.array_buffer, &quad, c.static_draw);
    try testing.expectEqual(3 * 16, api.stub.state.last_upload_len);
}

test "a program that builds, and the objects it used are gone" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    var text: [256]u8 = undefined;
    var log: std.Io.Writer = .fixed(&text);

    const program = try gl.buildProgram("#version 300 es\nvoid main(){}", "#version 300 es\nvoid main(){}", &log);
    defer gl.deleteProgram(program);

    // Nothing was written to the log, because nothing went wrong.
    try testing.expectEqual(0, log.buffered().len);

    // Two shaders made and both deleted; the program and the uniform lookups
    // are what is left.
    try testing.expect(program.valid());
}

test "a shader that does not compile says so, and says why" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    api.stub.state.fail_compile = true;

    var text: [512]u8 = undefined;
    var log: std.Io.Writer = .fixed(&text);

    const result = gl.buildProgram("not glsl", "nor this", &log);
    try testing.expectError(error.CompileFailed, result);

    // The driver's own text, and then which stage it came from.
    const written = log.buffered();
    try testing.expect(std.mem.startsWith(u8, written, "ERROR:"));
    try testing.expect(std.mem.endsWith(u8, written, "(in the vertex shader)\n"));

    // And the shader that failed was freed rather than leaked - the errdefer
    // in `compileShader` did its work.
    try testing.expectEqual(0, api.stub.state.live_objects);
}

test "a link failure is reported separately from a compile failure" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    api.stub.state.fail_link = true;

    var text: [512]u8 = undefined;
    var log: std.Io.Writer = .fixed(&text);

    try testing.expectError(
        error.LinkFailed,
        gl.buildProgram("#version 300 es\n", "#version 300 es\n", &log),
    );
    try testing.expect(std.mem.indexOf(u8, log.buffered(), "not read by fragment") != null);
    try testing.expectEqual(0, api.stub.state.live_objects);
}

test "a uniform the linker removed is none, and setting it is allowed" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    var text: [64]u8 = undefined;
    var log: std.Io.Writer = .fixed(&text);
    const program = try gl.buildProgram("#version 300 es\n", "#version 300 es\n", &log);
    defer gl.deleteProgram(program);

    const present = gl.uniformLocation(program, "mvp");
    try testing.expect(present.valid());

    // The stub answers `.none` for a name starting with an underscore, which
    // stands in for a uniform the linker folded away.
    const absent = gl.uniformLocation(program, "_unused");
    try testing.expect(!absent.valid());

    // Setting it is defined to do nothing, so there is no branch to write.
    gl.uniform1f(absent, 1.0);
    try testing.expectEqual(null, gl.attribLocation(program, "_gone"));
}

test "checkError drains the queue rather than reading one" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    try testing.expectEqual(null, gl.checkError());

    api.stub.state.pending_error = c.invalid_operation;
    try testing.expectEqual(c.invalid_operation, gl.checkError());
    // Drained, so the next frame starts clean.
    try testing.expectEqual(null, gl.checkError());
}

test "a matrix goes over as sixteen floats in the order it was written" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    var text: [64]u8 = undefined;
    var log: std.Io.Writer = .fixed(&text);
    const program = try gl.buildProgram("#version 300 es\n", "#version 300 es\n", &log);
    defer gl.deleteProgram(program);

    // The identity, with the translation column filled in - which is where a
    // column-major matrix keeps it, and the thing a row-major mix-up moves.
    const mvp = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 4, 5, 1 };
    gl.uniformMatrix4(gl.uniformLocation(program, "mvp"), &mvp);

    try testing.expectEqualSlices(f32, &mvp, &api.stub.state.last_matrix);
    try testing.expectEqual(@as(f32, 3), api.stub.state.last_matrix[12]);
}

test "a draw records what it was asked for" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    gl.drawArrays(c.triangles, 0, 3);
    try testing.expectEqual(c.triangles, api.stub.state.last_draw.mode);
    try testing.expectEqual(3, api.stub.state.last_draw.count);

    gl.drawArraysInstanced(c.triangle_strip, 0, 4, 128);
    try testing.expectEqual(128, api.stub.state.last_draw.instances);
    try testing.expectEqual(2, api.stub.state.draw_calls);
}

test "a uniform block is found by name, and one the linker removed is null" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    var text: [64]u8 = undefined;
    var log: std.Io.Writer = .fixed(&text);
    const program = try gl.buildProgram("#version 300 es\n", "#version 300 es\n", &log);
    defer gl.deleteProgram(program);

    const frame = gl.uniformBlockIndex(program, "Frame").?;
    gl.uniformBlockBinding(program, frame, 2);
    try testing.expectEqual(frame, api.stub.state.last_block_binding.block);
    try testing.expectEqual(2, api.stub.state.last_block_binding.binding);

    // Null, and not `invalid_index` - which is a real number and would have
    // gone on to `uniformBlockBinding` without a word.
    try testing.expectEqual(null, gl.uniformBlockIndex(program, "_gone"));

    // And the slot the block was pointed at is the slot a buffer goes in.
    const ubo = try gl.createBuffer();
    defer gl.deleteBuffer(ubo);
    gl.bindBufferBase(c.uniform_buffer, 2, ubo);
    try testing.expectEqual(ubo.index(), api.stub.state.uniform_buffers[2]);
    // Or a part of it, from where the alignment allows.
    const step = gl.limits.uniform_buffer_offset_alignment;
    gl.bindBufferRange(c.uniform_buffer, 2, ubo, step, 64);
    try testing.expectEqual([2]u32{ step, 64 }, api.stub.state.uniform_ranges[2]);
}

test "a buffer can be given its size before anything is in it" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    const buffer = try gl.createBuffer();
    defer gl.deleteBuffer(buffer);

    gl.bindBuffer(c.uniform_buffer, buffer);
    gl.bufferDataSize(c.uniform_buffer, 256, c.dynamic_draw);
    try testing.expectEqual(256, api.stub.state.last_buffer_size);
    // Nothing was uploaded to get there.
    try testing.expectEqual(0, api.stub.state.last_upload_len);
}

test "a sampler is an object like any other, and it is given back" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    try testing.expect(gl.has(.samplers));

    const sampler = try gl.createSampler();
    gl.samplerParameteri(sampler, c.texture_min_filter, @intCast(c.nearest));
    try testing.expectEqual(1, api.stub.state.live_objects);

    // By unit index, the same number a sampler uniform is set to - and not
    // `textureUnit(3)`, which is what `activeTexture` takes.
    gl.bindSampler(3, sampler);
    try testing.expectEqual(sampler.index(), api.stub.state.samplers[3]);
    gl.bindSampler(3, .none);
    try testing.expectEqual(0, api.stub.state.samplers[3]);

    gl.deleteSampler(sampler);
    try testing.expectEqual(0, api.stub.state.live_objects);
}

test "colour and alpha can blend by different rules" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    gl.blendFuncSeparate(c.src_alpha, c.one_minus_src_alpha, c.one, c.one_minus_src_alpha);
    gl.blendEquationSeparate(c.func_add, c.func_add);
    try testing.expectEqual(
        .{ c.src_alpha, c.one_minus_src_alpha, c.one, c.one_minus_src_alpha },
        api.stub.state.last_blend_func,
    );
}

test "an attribute read as integers says so" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    gl.vertexAttribIPointer(3, 4, c.unsigned_byte, 16, 12);
    try testing.expect(api.stub.state.last_attribute.integer);
    try testing.expectEqual(12, api.stub.state.last_attribute.offset);

    gl.vertexAttribPointer(3, 4, c.unsigned_byte, true, 16, 12);
    try testing.expect(!api.stub.state.last_attribute.integer);
}

test "depth and stencil have the rest of their state" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    gl.depthRange(0.25, 0.75);
    gl.clearStencil(0);
    try testing.expectEqual(.{ 0.25, 0.75 }, api.stub.state.last_depth_range);

    // A renderbuffer attached as depth, which is a typed object going to the
    // wire as its index like every other.
    const fbo = try gl.createFramebuffer();
    defer gl.deleteFramebuffer(fbo);
    const rbo = try gl.createRenderbuffer();
    defer gl.deleteRenderbuffer(rbo);
    gl.bindFramebuffer(c.framebuffer, fbo);
    gl.bindRenderbuffer(c.renderbuffer, rbo);
    gl.renderbufferStorage(c.renderbuffer, c.depth_component24, 64, 64);
    gl.framebufferRenderbuffer(c.framebuffer, c.depth_attachment, c.renderbuffer, rbo);
    try gl.checkFramebuffer(c.framebuffer);
}

test "the strings a context describes itself with" {
    api.stub.reset();
    defer api.stub.reset();

    const gl: Context = .init();
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("Fluxion", gl.string(c.vendor, &buffer));
    try testing.expect(std.mem.startsWith(u8, gl.string(c.version, &buffer), "WebGL 2.0"));

    // A buffer too small truncates rather than overruns.
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("Flux", gl.string(c.vendor, &tiny));
}
