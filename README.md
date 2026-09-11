# Fluxion WebGL

WebGL 2 from Zig, compiled to WebAssembly. For Zig 0.16. Seven pieces that
fit together:

| Module | What it is |
| --- | --- |
| `types` | The types WebGL is written in - fixed widths, because the other side is JavaScript and the wire is the wasm ABI. And `Object`, which is the one that shapes everything else. |
| `enums` | The tokens the calls take, under the Khronos names with `GL_` taken off, plus the three that are defined as a sum. |
| `imports` | The calls, as WebAssembly imports the browser must supply. The file `fluxion-gl` does not have, and the reason the two libraries are shaped differently. |
| `stub` | The same calls again, implemented in Zig. A WebGL that is not there, so the library builds and its tests run on a machine with no browser. |
| `api` | Which of those two this build is talking to, decided at compile time on the target. |
| `context` | The calls as Zig: slices that stay slices, objects that have types, failure that is an error union. |
| `host` | The page - a clock, a canvas size, a console, a panic handler. Everything `wasm32-freestanding` has not got. |

```zig
const webgl = @import("fluxion_webgl");
const c = webgl.enums;

const gl: webgl.Context = .init();

var log_text: [2048]u8 = undefined;
var log: std.Io.Writer = .fixed(&log_text);
const program = try gl.buildProgram(vertex_source, fragment_source, &log);

gl.clearColor(0.1, 0.1, 0.12, 1);
gl.clear(c.color_buffer_bit | c.depth_buffer_bit);
gl.useProgram(program);
gl.drawArrays(c.triangles, 0, 3);
```

## Why this is not Fluxion GL with different tokens

[Fluxion GL](https://github.com/kisstp2006/fluxion-gl) finds OpenGL at run
time: the driver is a shared library, `getProcAddress` hands back an address,
and a struct of function pointers is filled in from it. Optionality lives in
the type - a `?*const fn` field is a command the driver may not have.

**None of that exists here.** A wasm module cannot open a library, cannot take
the address of anything outside its own memory, and cannot call an address it
was handed. What it can do is declare, at compile time, that it needs a
function from outside, and refuse to instantiate until the host provides one.

So the version policy inverts. Every import is required, and the *glue*
decides what to provide: a WebGL 1 context has no `createVertexArray`, so
`fluxion-webgl.js` supplies one backed by `OES_vertex_array_object`. The
check moved from the type system to the loader, because that is where the
browser put it.

Three more consequences run through the library:

**An object is not a number the driver made up.** `glGenBuffers` writes a
`GLuint` and that number *is* the buffer. `gl.createBuffer()` returns a
`WebGLBuffer` - a live JavaScript object, garbage-collected, with no numeric
value and no address. Linear memory holds bytes, so there is nothing an object
could be stored as. The glue keeps them in an array and hands back the index,
which is what `types.Object` is. See [Objects](#objects).

**A slice is two arguments.** WebAssembly has four types, and `[]const u8` is
not one of them. Every call that takes bytes takes a pointer and a length
separately, and the glue reads them back out of the module's memory. `Context`
puts the slice back together so that the one place a length can be wrong is
not in your program.

**The standard library is mostly absent.** `wasm32-freestanding` has no clock,
no console, no files and no stack trace, and that is not a gap in Zig's
support - it is what the target *is*. `host` is the four-line replacement, and
two of its lines go in your program: see [host](#host).

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-webgl
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_webgl = .{ .path = "../fluxion-webgl" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_webgl", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_webgl", fluxion.module("fluxion_webgl"));
```

**Nothing comes with it.** The library has no dependencies at all, which is
worth a sentence rather than a shrug: `fluxion-gl` needs
[Fluxion Dyn](https://github.com/kisstp2006/fluxion-dyn) because a desktop
driver has to be opened and its entry points found. There is nothing to open
here.

One dependency is named in `build.zig.zon` and is *not* fetched for you:
[Fluxion Math](https://github.com/kisstp2006/fluxion-math) is what the cube
example draws with. It is `lazy`, and `build.zig` asks for it only when this
is the package being built - so a program that depends on `fluxion_webgl`
never downloads it, and the module imports it nowhere. Pass
`-Dexamples=false` to skip it in a checkout of this repository too.

### The three settings that make a wasm module

Easy to leave out, and hard to diagnose afterwards:

```zig
exe.entry = .disabled;      // there is no main; the page calls the exports
exe.rdynamic = true;        // or the linker drops every `export fn`
exe.import_memory = false;  // the module makes its memory and hands it out
```

Without `rdynamic`, `instance.exports` is empty for reasons the console does
not explain.

## Tour

### types

Fixed widths, and that is the actual contract rather than a simplification.
WebGL's IDL says `GLenum` is an `unsigned long`, which in Web IDL is 32 bits
and not the `long` of any C compiler:

```zig
pub const Enum = u32;
pub const Int = i32;
pub const Float = f32;
pub const Boolean = bool;   // and not a byte: see below
```

`Boolean` is a real `bool` here, where `fluxion-gl` has to call it a `u8`.
Across a C ABI there is a byte to disagree about; across the wasm boundary a
JavaScript boolean becomes the `i32` 0 or 1, which is exactly what the
specification says an imported `i32` narrows to.

### Objects

The type that shapes the library. One number, distinct per kind:

```zig
const vbo: webgl.Buffer = try gl.createBuffer();
const tex: webgl.Texture = try gl.createTexture();

gl.bindBuffer(c.array_buffer, tex);   // compile error, and not invalid_operation
```

`.none` is zero and the glue reserves slot zero, so an object that was never
assigned is the null object rather than somebody else's texture. Unbinding is
what it always was:

```zig
gl.bindVertexArray(.none);
gl.bindFramebuffer(c.framebuffer, .none);   // back to drawing at the canvas
```

A uniform location is the same type and is routinely `.none` on purpose: a
uniform the shader declares but never reads is removed by the linker, and
setting a `.none` location is defined to do nothing. So look them all up after
linking and set them without checking - there is no branch to write.

### context

The calls, with Zig's machinery over them. Four things it adds, and the first
is the one that stops a real bug:

```zig
const vertices = [_]Vertex{ ... };
gl.bufferData(c.array_buffer, &vertices, c.static_draw);
```

The element type is whatever you pass and the byte count is not a parameter.
`glBufferData` takes a `void*` and a size in bytes, and every renderer ever
written has at some point passed the element count where the byte count
belonged and drawn a quarter of a mesh.

Failure is an error union, with the driver's own text written to a writer you
own:

```zig
var log_text: [2048]u8 = undefined;
var log: std.Io.Writer = .fixed(&log_text);

const program = gl.buildProgram(vertex_source, fragment_source, &log) catch |err| {
    std.log.err("{s}", .{log.buffered()});   // ERROR: 0:14: 'in' : storage qualifier...
    return err;
};
```

`buildProgram` is both shaders and the link, with the intermediates cleaned up
either way - six calls by hand, two of which are `errdefer`s people forget.

The context knows what it is, asked once:

```zig
const gl: webgl.Context = .init();
gl.version;                     // .webgl2
gl.version.atLeast(.webgl1);    // true
gl.has(.vertex_arrays);         // false on WebGL 1 without the extension
gl.limits.max_texture_size;     // and the rest, cached
```

And `checkError` drains the queue rather than reading one entry, for the same
reason `fluxion-gl` does: GL records errors and hands them back one call at a
time, so a program that reads a single `getError` after a frame is reading the
oldest mistake and leaving the rest for the next one.

Two sharp edges the doc comments name and this does too. `readPixels` hands
rows back **bottom-up**, because that is GL's convention and this library does
not silently flip it the way
[Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) does. And
`drawElements` takes its offset in **bytes**, not in indices - so the second
half of a `u16` index buffer of 600 starts at 600, not at 300.

### Matrices

There are none in the library, for the same reason there are none in
`fluxion-gl`: a binding has no business having an opinion about your vectors.
The uniform setters take floats.

A [Fluxion Math](https://github.com/kisstp2006/fluxion-math) `Mat4` is an
`extern struct` of four `Vec4` columns, so it is already sixteen floats in
the order GL wants, and `array` is that reinterpretation spelled safely:

```zig
const mvp = projection.mul(view).mul(model);
const floats = mvp.array();
gl.uniformMatrix4(u_mvp, &floats);
```

There is no `transpose` parameter, because the answer is always false: WebGL 1
rejects `true` outright, and a program that needs the other layout has a bug
one layer up.

`proj.Clip.gl` is the one line that says which clip space a projection is for.
WebGL is OpenGL's: depth from -1 to +1.

### Uniform blocks and samplers

WebGL 2's two ways of binding by slot - which is the way a renderer that also
runs on Direct3D wants to bind, and the way
[Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi)'s WebGL backend does:

```zig
const frame = gl.uniformBlockIndex(program, "Frame") orelse return error.NoFrameBlock;
gl.uniformBlockBinding(program, frame, 0);    // once, after linking
gl.bindBufferBase(c.uniform_buffer, 0, ubo);  // whenever the buffer changes

const sampler = try gl.createSampler();
gl.samplerParameteri(sampler, c.texture_min_filter, @intCast(c.nearest));
gl.bindSampler(0, sampler);                   // unit 0 - the index, not texture0
```

`uniformBlockIndex` answers null for a block the program has not got, where
`uniformLocation` answers `.none` and lets you carry on: a missing uniform is
one number, and a missing block is a whole frame's worth of them read as
zeros. GLSL ES 3.00 has no `layout(binding = n)`, so `uniformBlockBinding` is
the only place a block learns its slot - and the program keeps it, so once
after linking is enough.

A sampler bound to a unit overrides whatever the texture's own `texParameteri`
said, so one picture can be read smoothly in one draw and in hard pixels in
the next. Neither blocks nor samplers exist in WebGL 1, and no extension adds
them; `has(.uniform_blocks)` and `has(.samplers)` are how a program asks.

`bufferDataSize` is WebGL's other `bufferData` - a size where the data would
go - which is what a uniform buffer, and anything written every frame, is
made with. JavaScript tells the two overloads apart by the type of the second
argument, and the wire has no types to tell them apart by, so here they have
two names.

### host

The four things `wasm32-freestanding` has not got, and two lines that go near
the top of a program that runs in a browser:

```zig
pub const std_options: std.Options = .{ .logFn = webgl.host.logFn };
pub const panic = webgl.host.panic;
```

With those, `std.log.info` reaches the browser console with its level and
scope intact, and a failed `unreachable` prints its message before it traps.
Without them the first is a compile error and the second is silence - the
browser raises `RuntimeError: unreachable` and the message, the whole reason
panics have messages, is never seen.

```zig
const size = webgl.canvasSize();   // device pixels, not CSS pixels
gl.viewport(0, 0, size.width, size.height);

const seconds: f32 = @floatCast(webgl.now() / 1000.0);
```

`canvasSize` is the drawing buffer, not the element. On a display with a
device pixel ratio of two those differ by a factor of two, and using the CSS
size is what makes a canvas blurry.

### stub, and how the tests run at all

Every declaration in `imports.zig` appears again in `stub.zig`, implemented in
Zig. `api` picks between them at compile time on the target:

```zig
pub const raw = if (is_wasm) @import("imports.zig") else stub;
```

That is Zig's answer to an `#ifdef`, and the difference is that both files are
always parsed and always checked - only the *bodies* of the branch not taken
go unanalysed. So `zig build test` runs on Windows, on a build server, and
inside another package, none of which have a canvas. It catches everything up
to the draw: that objects are deleted, that a compile failure is reported
rather than drawn with, that the matrix handed over is sixteen floats in the
right order.

The stub also does one thing a browser will not - fail on demand:

```zig
stub.state.fail_compile = true;
try testing.expectError(error.CompileFailed, start(&log));
try testing.expectEqual(0, stub.state.live_objects);   // the errdefer did its work
```

which is how the unhappy path gets a test at all. A real driver has to be
given a broken shader to produce one, and a broken shader in a test file is a
thing that gets quietly fixed.

Keeping the two files in step is `api.verify`, which walks the imports at
compile time and compares each signature against the stub. It can only run
where the imports can be looked at - `extern "webgl"` names a wasm import
module on one target and a *library to link against* on every other, and on
Windows that is `webgl.dll`, which does not exist. So it runs from a top-level
`comptime` block in `root.zig`, on every wasm build of the library, and
`zig build test` makes one as one of its steps - precisely so that the check
runs and the extern surface is compiled rather than merely parsed. A `test`
block would not do: it is analysed only when tests are being built, and a
wasm build never is one.

That wasm build is `src/wasm_check.zig`, and it does one more thing: it calls
every function in `Context` and `host`. The suite cannot - it runs against the
stub, and Zig analyses a function only when something calls it - so without
this, a call that does not compile against the real imports, or one nothing
has called yet, would be found by the first program to try it. The calls are
found by walking the types at compile time rather than listed, so one added
later is covered without anybody remembering to, and their arguments are
`undefined`, because nothing runs them. The examples are built for wasm as
part of the suite too.

## The JavaScript

`examples/web/fluxion-webgl.js` is the whole of it: five hundred lines, a
good part of them comments, with no dependencies and no build step. It
implements every import the library declares, and it is the only JavaScript a
program using this library needs.

```js
import { Fluxion } from "./fluxion-webgl.js";

const fluxion = new Fluxion(document.getElementById("canvas"));
fluxion.resize();

const app = await fluxion.instantiate("./cube.wasm");
if (app.init()) fluxion.run(app.frame);
```

Three things it has to do, and they are the three things every wasm binding
has to do:

1. **Keep the objects**, in an array, and hand out indices. Slot 0 stays null.
2. **Read the memory**, with a view over the pointer and length that arrived.
3. **Rebuild the views**, because `memory.buffer` is detached and replaced
   whenever the module grows its memory, and a cached `Uint8Array` silently
   stops working.

The third is the one that bites. Every accessor in the file checks
`view.buffer !== memory.buffer` and rebuilds.

Pixels are the one place the view has a type other than bytes. WebGL 2 checks
the view it is handed against the pixels' `type`, on the way in and on the way
out, and answers a `Uint8Array` of floats with `invalid_operation` - so a
float texture goes over as a `Float32Array`, the sixteen-bit types as a
`Uint16Array`, the thirty-two-bit ones as a `Uint32Array` and the signed
integers as the signed array of their width. A pointer that is not aligned for
them is copied first, because a typed array cannot start part-way into one of
its elements, and what `readPixels` wrote into the copy is written back to
where the module asked for it.

## Examples

```bash
zig build example                              # the cube, into zig-out/web
zig build examples -Doptimize=ReleaseSmall     # both, 16 KB and 5 KB
```

Then serve the directory - a page cannot `fetch` its own `file://` neighbours,
and ES modules will not load from one either:

```bash
python -m http.server 8000 --directory zig-out/web
```

| Example | What it shows |
| --- | --- |
| `zig build example-cube` | 3D: a lit cube turning, with a depth buffer, backface culling, a perspective projection and a normal per face. The geometry is built by the compiler; the matrices are Fluxion Math. |
| `zig build example-triangle` | The smallest thing that draws: a shader pair, a vertex buffer, an attribute layout, one draw. No matrices - and it stretches with the window, which is what a projection matrix is for. |

Both write `cube.wasm` and `triangle.wasm` next to an `index.html` that
switches between them, reports the drawing buffer size, and rebuilds after a
lost context.

Both carry tests, and `zig build test` runs them on the host against the stub,
because an entry point nothing has called is a guess. The cube's tests are the
interesting ones: that every corner is half a unit from the middle, that each
face has one normal and the six sum to zero, that the winding is
counter-clockwise seen from outside - which is the only way to be sure
`frontFace`, `cullFace` and the index order all agree - and that all eight
corners land inside the clip box under the real projection.

## Build

```bash
zig build test        # the suite, plus every call compiled for wasm32
zig build example     # the cube, into zig-out/web
zig build examples    # both
zig build docs        # API docs into zig-out/docs
```

## Requirements

Zig 0.16.0, and a browser with WebGL 2 - which since 2021 is all of them.
WebGL 1 contexts are accepted and reported by `Context.version`; the glue
shims vertex arrays and instancing onto their extensions, and `has` is how a
program asks before depending on either.

## License

`SPDX-License-Identifier: BSL-1.0`

[Boost Software License 1.0](LICENSE) - permissive, and short enough to read
in a minute: use it, change it, ship it, in anything. The one obligation is
that the copyright notice and the licence text travel with the *source*; a
binary built from it carries nothing, which is the difference from MIT and
BSD and the reason this is the usual choice for a library that ends up
compiled into somebody else's program.

Fluxion libraries are licensed by layer: the foundation is CC0, the engine
infrastructure this one belongs to is BSL-1.0, and what builds on top of it
is BSD.
