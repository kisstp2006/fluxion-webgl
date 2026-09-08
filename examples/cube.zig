// SPDX-License-Identifier: BSL-1.0

//! 3D: a lit cube turning, with a depth buffer, backface culling, a
//! perspective projection and a normal per face.
//!
//! This is the example that shows the libraries fitting together. The
//! drawing is [Fluxion WebGL](https://github.com/kisstp2006/fluxion-webgl);
//! the four-by-fours are
//! [Fluxion Math](https://github.com/kisstp2006/fluxion-math), and none of
//! them are in the binding - a binding has no business having an opinion
//! about your vectors. `proj.Clip.gl` is the one line that says which clip
//! space the projection is for, and changing it is what would make the same
//! scene correct under Direct3D or Vulkan.
//!
//! Two things here are more interesting than the cube:
//!
//! **The geometry is built by the compiler.** `buildMesh` is an ordinary
//! function with ordinary loops in it, and it runs during the build rather
//! than at start-up for one reason: it is called from the initialiser of a
//! container-level `const`, which is already a comptime scope. The
//! twenty-four vertices and thirty-six indices land in the wasm module as
//! constant data - no start-up cost, no allocation, no loop at run time - and
//! the six faces are still written down once, as a normal and two axes,
//! rather than as seventy-two floats somebody has to check by hand.
//!
//! **The normal matrix is the inverse transpose**, and `normalMatrix` returns
//! an optional because a matrix that does not invert has no normals to speak
//! of. A cube scaled to nothing is the usual way to get one.

const std = @import("std");
const webgl = @import("fluxion_webgl");
const math = @import("fluxion_math");

const c = webgl.enums;
const proj = math.proj;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;

pub const std_options: std.Options = .{ .logFn = webgl.host.logFn };

pub const panic = if (webgl.is_wasm)
    webgl.host.panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

// -------------------------------------------------------------------------
// The cube, built at compile time
// -------------------------------------------------------------------------

/// One corner: where it is, which way the surface faces, and what colour it
/// is. `extern` so the offsets below describe the layout that is actually
/// there - see `triangle.zig` for what goes wrong otherwise.
const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    colour: [3]f32,
};

/// A cube has eight corners and twenty-four vertices, and the difference is
/// the whole reason lighting works.
///
/// A corner shared between three faces would need three different normals,
/// and a vertex carries one. So each face gets its own four, the corners are
/// duplicated, and every fragment on a face interpolates between four normals
/// that all point the same way - which is what makes a cube look flat and a
/// sphere look round.
const Mesh = struct {
    vertices: [24]Vertex,
    indices: [36]u16,
};

/// Each face, as the direction it faces and the two axes that span it.
///
/// `tangent` crossed with `bitangent` is `normal`, which is what makes the
/// winding below counter-clockwise seen from outside - and counter-clockwise
/// seen from outside is what `frontFace(ccw)` and `cullFace(back)` agree to
/// keep. Get one of the three wrong and the cube renders inside out, which
/// looks like the depth test failing and is not.
const Face = struct {
    normal: [3]f32,
    tangent: [3]f32,
    bitangent: [3]f32,
    colour: [3]f32,
};

const faces = [6]Face{
    .{ .normal = .{ 1, 0, 0 }, .tangent = .{ 0, 0, -1 }, .bitangent = .{ 0, 1, 0 }, .colour = .{ 0.90, 0.30, 0.35 } },
    .{ .normal = .{ -1, 0, 0 }, .tangent = .{ 0, 0, 1 }, .bitangent = .{ 0, 1, 0 }, .colour = .{ 0.30, 0.70, 0.95 } },
    .{ .normal = .{ 0, 1, 0 }, .tangent = .{ 1, 0, 0 }, .bitangent = .{ 0, 0, -1 }, .colour = .{ 0.40, 0.85, 0.45 } },
    .{ .normal = .{ 0, -1, 0 }, .tangent = .{ 1, 0, 0 }, .bitangent = .{ 0, 0, 1 }, .colour = .{ 0.95, 0.75, 0.25 } },
    .{ .normal = .{ 0, 0, 1 }, .tangent = .{ 1, 0, 0 }, .bitangent = .{ 0, 1, 0 }, .colour = .{ 0.75, 0.50, 0.95 } },
    .{ .normal = .{ 0, 0, -1 }, .tangent = .{ -1, 0, 0 }, .bitangent = .{ 0, 1, 0 }, .colour = .{ 0.95, 0.55, 0.30 } },
};

/// Turn those six lines into twenty-four vertices and thirty-six indices.
///
/// An ordinary function, written in the ordinary way, with a `for` loop and a
/// mutable local. Nothing marks it as compile-time work. What makes it
/// compile-time work is *where it is called*: the initialiser of a
/// container-level `const` is already a comptime scope, so `buildMesh()`
/// below runs in the compiler and the loops never reach the module.
///
/// That is worth noticing, because it is the opposite of how a macro works.
/// This is not a second language with its own rules - it is the same code,
/// and moving the call into a function body would run it at start-up instead,
/// with no edit to anything here.
fn buildMesh() Mesh {
    var out: Mesh = undefined;

    for (faces, 0..) |face, f| {
        const centre = scale(face.normal, 0.5);
        const t = scale(face.tangent, 0.5);
        const b = scale(face.bitangent, 0.5);

        // The four corners, going round: bottom left, bottom right, top
        // right, top left, seen from outside.
        const corners = [4][3]f32{
            add(centre, add(negate(t), negate(b))),
            add(centre, add(t, negate(b))),
            add(centre, add(t, b)),
            add(centre, add(negate(t), b)),
        };

        for (corners, 0..) |corner, i| {
            out.vertices[f * 4 + i] = .{
                .position = corner,
                .normal = face.normal,
                .colour = face.colour,
            };
        }

        // Two triangles over those four corners, both counter-clockwise.
        const base: u16 = @intCast(f * 4);
        const pattern = [6]u16{ 0, 1, 2, 0, 2, 3 };
        for (pattern, 0..) |offset, i| {
            out.indices[f * 6 + i] = base + offset;
        }
    }

    return out;
}

fn scale(v: [3]f32, k: f32) [3]f32 {
    return .{ v[0] * k, v[1] * k, v[2] * k };
}
fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
fn negate(v: [3]f32) [3]f32 {
    return .{ -v[0], -v[1], -v[2] };
}

/// The cube, as constant data in the module. Nothing computes this at run
/// time - being the initialiser of a container-level `const` is what moves
/// the work into the build. An explicit `comptime` here would be redundant,
/// and Zig says so.
const mesh = buildMesh();

// -------------------------------------------------------------------------
// Shaders
// -------------------------------------------------------------------------

const vertex_source =
    \\#version 300 es
    \\layout(location = 0) in vec3 a_position;
    \\layout(location = 1) in vec3 a_normal;
    \\layout(location = 2) in vec3 a_colour;
    \\
    \\uniform mat4 u_mvp;
    \\uniform mat3 u_normal_matrix;
    \\
    \\out vec3 v_normal;
    \\out vec3 v_colour;
    \\
    \\void main() {
    \\    v_normal = u_normal_matrix * a_normal;
    \\    v_colour = a_colour;
    \\    gl_Position = u_mvp * vec4(a_position, 1.0);
    \\}
;

const fragment_source =
    \\#version 300 es
    \\precision highp float;
    \\
    \\in vec3 v_normal;
    \\in vec3 v_colour;
    \\
    \\uniform vec3 u_light;
    \\
    \\out vec4 o_colour;
    \\
    \\void main() {
    \\    float lambert = max(dot(normalize(v_normal), normalize(u_light)), 0.0);
    \\    o_colour = vec4(v_colour * (0.25 + 0.75 * lambert), 1.0);
    \\}
;

// -------------------------------------------------------------------------
// The program
// -------------------------------------------------------------------------

const State = struct {
    gl: webgl.Context,
    program: webgl.Program,
    vao: webgl.VertexArray,
    vbo: webgl.Buffer,
    ebo: webgl.Buffer,

    // Looked up once, after linking, and set every frame without checking:
    // a uniform the linker removed is `.none`, and setting `.none` does
    // nothing. See `Context.uniformLocation`.
    u_mvp: webgl.UniformLocation,
    u_normal_matrix: webgl.UniformLocation,
    u_light: webgl.UniformLocation,
};

var state: State = undefined;

export fn init() bool {
    // The buffer lives here rather than in `start` because this is the
    // function that decides the browser console is where a shader log goes.
    var log_text: [2048]u8 = undefined;
    var log: std.Io.Writer = .fixed(&log_text);

    start(&log) catch |err| {
        if (log.buffered().len > 0) std.log.err("{s}", .{log.buffered()});
        std.log.err("could not start: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

/// Everything `init` does, with the reporting left to the caller. See the
/// same split in `triangle.zig`.
fn start(log: *std.Io.Writer) !void {
    const gl: webgl.Context = .init();

    var name: [128]u8 = undefined;
    std.log.info("{f} on {s}", .{ gl.version, gl.string(c.renderer, &name) });

    if (!gl.has(.vertex_arrays)) {
        // WebGL 1 without OES_vertex_array_object. The glue throws rather
        // than pretending, so say why before it does.
        std.log.warn("no vertex array objects; this example needs WebGL 2", .{});
        return error.NeedsWebGl2;
    }

    const program = try gl.buildProgram(vertex_source, fragment_source, log);

    const vao = try gl.createVertexArray();
    const vbo = try gl.createBuffer();
    const ebo = try gl.createBuffer();

    gl.bindVertexArray(vao);

    gl.bindBuffer(c.array_buffer, vbo);
    gl.bufferData(c.array_buffer, &mesh.vertices, c.static_draw);

    // The element buffer binding is part of the vertex array's state, which
    // is the one piece of that state people are surprised by: unbinding the
    // vertex array unbinds this too, and binding it again brings it back.
    gl.bindBuffer(c.element_array_buffer, ebo);
    gl.bufferData(c.element_array_buffer, &mesh.indices, c.static_draw);

    const stride = @sizeOf(Vertex);
    inline for (.{ "position", "normal", "colour" }, 0..) |field, location| {
        gl.enableVertexAttribArray(location);
        gl.vertexAttribPointer(location, 3, c.float, false, stride, @offsetOf(Vertex, field));
    }

    // Depth testing, so the far faces lose; culling, so they are not drawn at
    // all. Either alone would nearly work, and the pair is what makes a solid
    // object look solid.
    gl.enable(c.depth_test);
    gl.depthFunc(c.less);
    gl.enable(c.cull_face);
    gl.cullFace(c.back);
    gl.frontFace(c.ccw);

    state = .{
        .gl = gl,
        .program = program,
        .vao = vao,
        .vbo = vbo,
        .ebo = ebo,
        .u_mvp = gl.uniformLocation(program, "u_mvp"),
        .u_normal_matrix = gl.uniformLocation(program, "u_normal_matrix"),
        .u_light = gl.uniformLocation(program, "u_light"),
    };
}

/// Where the cube is this many milliseconds in.
///
/// Split out from `frame` so a test can ask for the matrix at a given moment
/// without a canvas - which is the only way to check that the projection and
/// the rotation agree on a machine with no browser.
fn modelViewProjection(seconds: f32, aspect: f32) Mat4 {
    // Two exact axes rather than one tilted one, so there is no unit vector
    // to get wrong: turning about Y and about X at different rates shows
    // every face in turn.
    const spin = Mat4.fromAxisAngle(.init(0, 1, 0), seconds * 0.9);
    const tilt = Mat4.fromAxisAngle(.init(1, 0, 0), seconds * 0.5);
    const model = spin.mul(tilt);

    const view = proj.lookAt(
        .init(0, 0, 2.6),
        .init(0, 0, 0),
        .init(0, 1, 0),
        .right,
    );

    const projection = proj.perspective(.{
        .fov_y = math.scalar.radians(50),
        .aspect = aspect,
        .near = 0.1,
        .far = 100,
        // The one line that says which API this is for. WebGL is OpenGL's
        // clip space: depth from -1 to +1.
        .clip = .gl,
    });

    // Column-major, applied right to left: the model matrix acts first.
    return projection.mul(view).mul(model);
}

/// The model matrix on its own, for the normals.
fn modelMatrix(seconds: f32) Mat4 {
    const spin = Mat4.fromAxisAngle(.init(0, 1, 0), seconds * 0.9);
    const tilt = Mat4.fromAxisAngle(.init(1, 0, 0), seconds * 0.5);
    return spin.mul(tilt);
}

export fn frame() void {
    const gl = state.gl;

    const size = webgl.canvasSize();
    gl.viewport(0, 0, size.width, size.height);

    gl.clearColor(0.06, 0.07, 0.09, 1);
    gl.clearDepth(1);
    gl.clear(c.color_buffer_bit | c.depth_buffer_bit);

    // Milliseconds since the page loaded, and the difference is what matters
    // - see `host.now` on why this is an `f64` until the last moment.
    const seconds: f32 = @floatCast(webgl.now() / 1000.0);
    const aspect = @as(f32, @floatFromInt(size.width)) / @as(f32, @floatFromInt(@max(size.height, 1)));

    const mvp = modelViewProjection(seconds, aspect);
    const model = modelMatrix(seconds);

    gl.useProgram(state.program);

    // A `Mat4` is an extern struct of four `Vec4` columns - sixteen floats,
    // columns first, which is the order GL has always wanted. `array` is that
    // reinterpretation spelled safely, and the copy it looks like is one the
    // compiler removes.
    const mvp_floats = mvp.array();
    gl.uniformMatrix4(state.u_mvp, &mvp_floats);

    // The inverse transpose, which is what keeps normals perpendicular
    // through a non-uniform scale. Optional because a matrix that does not
    // invert has no normals to speak of; the identity is the honest fallback.
    const normal_matrix = model.normalMatrix() orelse math.Mat3.identity;
    // `Mat3` has no `array` of its own, but it is an extern struct of three
    // `Vec3`, so it is exactly nine floats - and `@bitCast` will not compile
    // if that ever stops being true.
    const normal_floats: [9]f32 = @bitCast(normal_matrix);
    gl.uniformMatrix3(state.u_normal_matrix, &normal_floats);

    gl.uniform3f(state.u_light, 0.4, 0.8, 0.6);

    gl.bindVertexArray(state.vao);
    gl.drawElements(c.triangles, mesh.indices.len, c.unsigned_short, 0);
}

export fn deinit() void {
    const gl = state.gl;
    gl.deleteBuffer(state.ebo);
    gl.deleteBuffer(state.vbo);
    gl.deleteVertexArray(state.vao);
    gl.deleteProgram(state.program);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const stub = webgl.stub;

test "the mesh is built by the compiler, not at start-up" {
    // If this were run-time work the array would not be usable here.
    comptime {
        if (mesh.vertices.len != 24) @compileError("a cube has six faces of four");
        if (mesh.indices.len != 36) @compileError("six faces of two triangles");
    }
    try testing.expectEqual(24, mesh.vertices.len);
    try testing.expectEqual(36, mesh.indices.len);
}

test "every corner is half a unit from the middle, on every axis" {
    for (mesh.vertices) |vertex| {
        for (vertex.position) |component| {
            try testing.expectApproxEqAbs(0.5, @abs(component), 1e-6);
        }
    }
}

test "each face has one normal, and the six are the six directions" {
    var seen: [6][3]f32 = undefined;
    for (0..6) |f| {
        const normal = mesh.vertices[f * 4].normal;
        // All four corners of a face agree, which is the reason for
        // twenty-four vertices rather than eight.
        for (1..4) |i| {
            try testing.expectEqual(normal, mesh.vertices[f * 4 + i].normal);
        }
        seen[f] = normal;
    }

    // And between them they point every way: the six sum to zero.
    var total = [3]f32{ 0, 0, 0 };
    for (seen) |normal| total = add(total, normal);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, total);
}

test "the winding is counter-clockwise seen from outside" {
    // For each face, the cross product of two triangle edges has to point the
    // same way as the face normal. If it does not, `cullFace(back)` removes
    // the faces that should be visible and keeps the ones that should not.
    for (0..6) |f| {
        const tri = mesh.indices[f * 6 ..][0..3];
        const a = mesh.vertices[tri[0]].position;
        const b = mesh.vertices[tri[1]].position;
        const d = mesh.vertices[tri[2]].position;

        const e1 = add(b, negate(a));
        const e2 = add(d, negate(a));
        const cross = [3]f32{
            e1[1] * e2[2] - e1[2] * e2[1],
            e1[2] * e2[0] - e1[0] * e2[2],
            e1[0] * e2[1] - e1[1] * e2[0],
        };

        const normal = mesh.vertices[tri[0]].normal;
        const dot = cross[0] * normal[0] + cross[1] * normal[1] + cross[2] * normal[2];
        try testing.expect(dot > 0);
    }
}

test "the matrix puts the cube in front of the camera and inside the clip box" {
    // The eight corners, at a moment picked to be nothing special, all have
    // to land inside the view frustum - which for GL clip space means
    // `-w <= x, y, z <= w` after the projection and before the divide.
    const mvp = modelViewProjection(1.234, 16.0 / 9.0);

    for (mesh.vertices) |vertex| {
        const p = vertex.position;
        // `at(row, column)`, so this reads as the multiplication does on
        // paper even though the storage is column-major.
        const clip = [4]f32{
            mvp.at(0, 0) * p[0] + mvp.at(0, 1) * p[1] + mvp.at(0, 2) * p[2] + mvp.at(0, 3),
            mvp.at(1, 0) * p[0] + mvp.at(1, 1) * p[1] + mvp.at(1, 2) * p[2] + mvp.at(1, 3),
            mvp.at(2, 0) * p[0] + mvp.at(2, 1) * p[1] + mvp.at(2, 2) * p[2] + mvp.at(2, 3),
            mvp.at(3, 0) * p[0] + mvp.at(3, 1) * p[1] + mvp.at(3, 2) * p[2] + mvp.at(3, 3),
        };

        // In front of the camera at all.
        try testing.expect(clip[3] > 0);
        for (clip[0..3]) |component| {
            try testing.expect(@abs(component) <= clip[3]);
        }
    }
}

test "a frame uploads the mesh once and draws it indexed" {
    stub.reset();
    defer stub.reset();

    try testing.expect(init());

    // The last upload was the index buffer: thirty-six shorts.
    try testing.expectEqual(72, stub.state.last_upload_len);

    frame();
    try testing.expectEqual(1, stub.state.draw_calls);
    try testing.expectEqual(c.triangles, stub.state.last_draw.mode);
    try testing.expectEqual(36, stub.state.last_draw.count);
    try testing.expectEqual(null, state.gl.checkError());

    // The matrix that went over is the one the maths produced, and it is
    // finite - a projection with a zero aspect or a zero near plane is not,
    // and the picture it draws is nothing at all.
    for (stub.state.last_matrix) |component| {
        try testing.expect(std.math.isFinite(component));
    }

    deinit();
}

test "a shader that will not compile stops the example rather than drawing" {
    stub.reset();
    defer stub.reset();

    stub.state.fail_compile = true;

    // `start` rather than `init` - see the note on the same test in
    // `triangle.zig`: a line logged at error level is how the test runner is
    // told a test failed, so calling the wrapper that logs one would fail
    // this test for doing its job.
    var log_text: [512]u8 = undefined;
    var log: std.Io.Writer = .fixed(&log_text);
    try testing.expectError(error.CompileFailed, start(&log));

    try testing.expect(std.mem.startsWith(u8, log.buffered(), "ERROR:"));
    try testing.expectEqual(0, stub.state.live_objects);
}
