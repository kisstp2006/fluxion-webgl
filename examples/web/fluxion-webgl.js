// SPDX-License-Identifier: BSL-1.0
//
// The other side of the boundary: every import `src/imports.zig` and
// `src/host_imports.zig` declare, implemented against a real WebGL context.
//
// This is the whole of the JavaScript. It is deliberately one file with no
// dependencies and no build step - open the page and it runs.
//
// Three things it has to do, and they are the three things every wasm binding
// has to do:
//
//   1. Keep the objects. `gl.createBuffer()` returns a WebGLBuffer, which is
//      a live JavaScript object with no numeric value. A wasm module holds
//      bytes, so it cannot hold one. The `objects` array below is the fix:
//      the module gets an index, and this file turns it back into an object.
//      Slot 0 is reserved and stays null, so an index the module never set is
//      the null object rather than somebody else's texture.
//
//   2. Read the memory. A Zig slice arrives as a pointer and a length. The
//      bytes live in the module's own linear memory, and this file reads them
//      with a view over that range - see `bytes` and `text` below.
//
//   3. Rebuild the views. `memory.buffer` is detached and replaced whenever
//      the module grows its memory, so a cached `Uint8Array` silently stops
//      working. Every accessor here checks and rebuilds.

export class Fluxion {
  constructor(canvas, options = {}) {
    this.canvas = canvas;

    // `antialias` is on by default and worth keeping; `depth` is too, but
    // saying so costs nothing and documents what the examples rely on.
    const attributes = {
      alpha: false,
      antialias: true,
      depth: true,
      stencil: false,
      powerPreference: "high-performance",
      ...options.attributes,
    };

    this.gl =
      canvas.getContext("webgl2", attributes) ||
      canvas.getContext("webgl", attributes);
    if (!this.gl) throw new Error("this browser has no WebGL at all");

    this.isWebGL2 = typeof WebGL2RenderingContext !== "undefined" &&
      this.gl instanceof WebGL2RenderingContext;

    // WebGL 1 has vertex array objects only as an extension, and instancing
    // likewise. Fetch them once; the shims at the bottom use them if present.
    if (!this.isWebGL2) {
      this.vaoExt = this.gl.getExtension("OES_vertex_array_object");
      this.instExt = this.gl.getExtension("ANGLE_instanced_arrays");
    }

    // Slot 0 is the null object, for ever.
    this.objects = [null];
    this.free = [];

    this.memory = null;
    this.cachedU8 = null;
    this.cachedF32 = null;
    this.start = performance.now();
    this.decoder = new TextDecoder("utf-8");
  }

  // -- the object table --

  store(object) {
    if (object === null || object === undefined) return 0;
    const slot = this.free.length > 0 ? this.free.pop() : this.objects.length;
    this.objects[slot] = object;
    return slot;
  }

  get(index) {
    return index === 0 ? null : this.objects[index];
  }

  release(index) {
    if (index === 0) return;
    this.objects[index] = null;
    this.free.push(index);
  }

  // -- reading the module's memory --
  //
  // Rebuilt whenever the buffer has been swapped underneath us, which is what
  // happens when the module grows its memory. A view held across a call that
  // allocates is detached, and reading it throws rather than returning
  // rubbish - which is the good outcome, and the reason to check every time.

  get u8() {
    if (!this.cachedU8 || this.cachedU8.buffer !== this.memory.buffer) {
      this.cachedU8 = new Uint8Array(this.memory.buffer);
    }
    return this.cachedU8;
  }

  get f32() {
    if (!this.cachedF32 || this.cachedF32.buffer !== this.memory.buffer) {
      this.cachedF32 = new Float32Array(this.memory.buffer);
    }
    return this.cachedF32;
  }

  /// The bytes at `ptr[0..len]`, as a view - no copy. Valid only until the
  /// module next allocates, which is why nothing here keeps one.
  bytes(ptr, len) {
    return this.u8.subarray(ptr, ptr + len);
  }

  /// `count` floats at `ptr`. The pointer is a byte address and Float32Array
  /// is indexed in floats, hence the shift - and hence the requirement that
  /// the Zig side pass something four-byte aligned, which `[*]const f32` is.
  floats(ptr, count) {
    return this.f32.subarray(ptr >> 2, (ptr >> 2) + count);
  }

  text(ptr, len) {
    return this.decoder.decode(this.bytes(ptr, len));
  }

  /// The bytes at `ptr[0..len]`, as the view WebGL wants for pixels whose
  /// channels are `kind`. WebGL 2 checks the view's type against the `type`
  /// argument and answers a Uint8Array of floats with INVALID_OPERATION, so
  /// floats are handed over as a Float32Array, the sixteen-bit types as a
  /// Uint16Array and the thirty-two-bit integer ones as a Uint32Array. A
  /// pointer that is not aligned for the wider view is copied first: a typed
  /// array cannot start part-way into one of its elements.
  pixels(kind, ptr, len) {
    let View = Uint8Array;
    switch (kind) {
      case 0x1406: // FLOAT
        View = Float32Array;
        break;
      case 0x140b: // HALF_FLOAT
      case 0x1403: // UNSIGNED_SHORT
      case 0x8033: // UNSIGNED_SHORT_4_4_4_4
      case 0x8034: // UNSIGNED_SHORT_5_5_5_1
      case 0x8363: // UNSIGNED_SHORT_5_6_5
        View = Uint16Array;
        break;
      case 0x1405: // UNSIGNED_INT
      case 0x84fa: // UNSIGNED_INT_24_8
        View = Uint32Array;
        break;
    }
    if (View === Uint8Array) return this.bytes(ptr, len);
    const count = Math.floor(len / View.BYTES_PER_ELEMENT);
    if (ptr % View.BYTES_PER_ELEMENT === 0) {
      return new View(this.memory.buffer, ptr, count);
    }
    return new View(this.bytes(ptr, len).slice().buffer, 0, count);
  }

  /// Copy a JavaScript string into `ptr[0..cap]` as UTF-8 and answer its full
  /// length in bytes - which may be more than `cap`, and the Zig side treats
  /// that as truncation rather than as an error.
  writeText(string, ptr, cap) {
    const encoded = new TextEncoder().encode(string);
    const n = Math.min(encoded.length, cap);
    this.u8.set(encoded.subarray(0, n), ptr);
    return encoded.length;
  }

  // -- the import object --

  imports() {
    const gl = this.gl;
    const self = this;

    const webgl = {
      // state
      viewport: (x, y, w, h) => gl.viewport(x, y, w, h),
      scissor: (x, y, w, h) => gl.scissor(x, y, w, h),
      clearColor: (r, g, b, a) => gl.clearColor(r, g, b, a),
      clearDepth: (d) => gl.clearDepth(d),
      clearStencil: (s) => gl.clearStencil(s),
      clear: (mask) => gl.clear(mask),
      enable: (cap) => gl.enable(cap),
      disable: (cap) => gl.disable(cap),
      depthFunc: (f) => gl.depthFunc(f),
      depthMask: (flag) => gl.depthMask(!!flag),
      depthRange: (near, far) => gl.depthRange(near, far),
      colorMask: (r, g, b, a) => gl.colorMask(!!r, !!g, !!b, !!a),
      cullFace: (mode) => gl.cullFace(mode),
      frontFace: (mode) => gl.frontFace(mode),
      blendFunc: (s, d) => gl.blendFunc(s, d),
      blendEquation: (mode) => gl.blendEquation(mode),
      blendFuncSeparate: (sr, dr, sa, da) => gl.blendFuncSeparate(sr, dr, sa, da),
      blendEquationSeparate: (mr, ma) => gl.blendEquationSeparate(mr, ma),
      pixelStorei: (pname, param) => gl.pixelStorei(pname, param),
      finish: () => gl.finish(),
      flush: () => gl.flush(),
      getError: () => gl.getError(),

      getParameterInt: (pname) => {
        const value = gl.getParameter(pname);
        if (typeof value === "number") return value | 0;
        if (typeof value === "boolean") return value ? 1 : 0;
        // MAX_VIEWPORT_DIMS and friends answer an array; the first element is
        // the useful half and the Zig side asks for one number.
        if (value && value.length) return value[0] | 0;
        return 0;
      },

      getParameterString: (pname, ptr, cap) =>
        self.writeText(String(gl.getParameter(pname) ?? ""), ptr, cap),

      // buffers
      createBuffer: () => self.store(gl.createBuffer()),
      deleteBuffer: (b) => {
        gl.deleteBuffer(self.get(b));
        self.release(b);
      },
      bindBuffer: (target, b) => gl.bindBuffer(target, self.get(b)),
      bufferData: (target, ptr, len, usage) =>
        gl.bufferData(target, self.bytes(ptr, len), usage),
      bufferSubData: (target, offset, ptr, len) =>
        gl.bufferSubData(target, offset, self.bytes(ptr, len)),
      // The size overload of bufferData: a number where the data would go.
      bufferDataSize: (target, size, usage) => gl.bufferData(target, size, usage),
      bindBufferBase: (target, index, b) => {
        if (self.isWebGL2) gl.bindBufferBase(target, index, self.get(b));
      },

      // vertex arrays and attributes
      createVertexArray: () =>
        self.store(
          self.isWebGL2
            ? gl.createVertexArray()
            : self.vaoExt
            ? self.vaoExt.createVertexArrayOES()
            : null,
        ),
      deleteVertexArray: (v) => {
        const object = self.get(v);
        if (self.isWebGL2) gl.deleteVertexArray(object);
        else if (self.vaoExt) self.vaoExt.deleteVertexArrayOES(object);
        self.release(v);
      },
      bindVertexArray: (v) => {
        const object = self.get(v);
        if (self.isWebGL2) gl.bindVertexArray(object);
        else if (self.vaoExt) self.vaoExt.bindVertexArrayOES(object);
      },
      enableVertexAttribArray: (i) => gl.enableVertexAttribArray(i),
      disableVertexAttribArray: (i) => gl.disableVertexAttribArray(i),
      vertexAttribPointer: (i, size, kind, normalized, stride, offset) =>
        gl.vertexAttribPointer(i, size, kind, !!normalized, stride, offset),
      vertexAttribIPointer: (i, size, kind, stride, offset) => {
        if (self.isWebGL2) gl.vertexAttribIPointer(i, size, kind, stride, offset);
      },
      vertexAttribDivisor: (i, divisor) => {
        if (self.isWebGL2) gl.vertexAttribDivisor(i, divisor);
        else if (self.instExt) self.instExt.vertexAttribDivisorANGLE(i, divisor);
      },

      // shaders and programs
      createShader: (kind) => self.store(gl.createShader(kind)),
      deleteShader: (s) => {
        gl.deleteShader(self.get(s));
        self.release(s);
      },
      shaderSource: (s, ptr, len) =>
        gl.shaderSource(self.get(s), self.text(ptr, len)),
      compileShader: (s) => gl.compileShader(self.get(s)),
      getShaderParameter: (s, pname) => {
        const value = gl.getShaderParameter(self.get(s), pname);
        return typeof value === "boolean" ? (value ? 1 : 0) : value | 0;
      },
      getShaderInfoLog: (s, ptr, cap) =>
        self.writeText(gl.getShaderInfoLog(self.get(s)) ?? "", ptr, cap),

      createProgram: () => self.store(gl.createProgram()),
      deleteProgram: (p) => {
        gl.deleteProgram(self.get(p));
        self.release(p);
      },
      attachShader: (p, s) => gl.attachShader(self.get(p), self.get(s)),
      linkProgram: (p) => gl.linkProgram(self.get(p)),
      getProgramParameter: (p, pname) => {
        const value = gl.getProgramParameter(self.get(p), pname);
        return typeof value === "boolean" ? (value ? 1 : 0) : value | 0;
      },
      getProgramInfoLog: (p, ptr, cap) =>
        self.writeText(gl.getProgramInfoLog(self.get(p)) ?? "", ptr, cap),
      useProgram: (p) => gl.useProgram(self.get(p)),

      bindAttribLocation: (p, index, ptr, len) =>
        gl.bindAttribLocation(self.get(p), index, self.text(ptr, len)),
      getAttribLocation: (p, ptr, len) =>
        gl.getAttribLocation(self.get(p), self.text(ptr, len)),
      getUniformLocation: (p, ptr, len) =>
        self.store(gl.getUniformLocation(self.get(p), self.text(ptr, len))),
      // WebGL 1 has no uniform blocks, so every name is one it has not got.
      getUniformBlockIndex: (p, ptr, len) =>
        self.isWebGL2
          ? gl.getUniformBlockIndex(self.get(p), self.text(ptr, len))
          : 0xffffffff,
      uniformBlockBinding: (p, block, binding) => {
        if (self.isWebGL2) gl.uniformBlockBinding(self.get(p), block, binding);
      },

      // uniforms
      uniform1i: (loc, v) => gl.uniform1i(self.get(loc), v),
      uniform1f: (loc, v) => gl.uniform1f(self.get(loc), v),
      uniform2f: (loc, x, y) => gl.uniform2f(self.get(loc), x, y),
      uniform3f: (loc, x, y, z) => gl.uniform3f(self.get(loc), x, y, z),
      uniform4f: (loc, x, y, z, w) => gl.uniform4f(self.get(loc), x, y, z, w),
      uniformMatrix3fv: (loc, count, transpose, ptr) =>
        gl.uniformMatrix3fv(
          self.get(loc),
          !!transpose,
          self.floats(ptr, 9 * count),
        ),
      uniformMatrix4fv: (loc, count, transpose, ptr) =>
        gl.uniformMatrix4fv(
          self.get(loc),
          !!transpose,
          self.floats(ptr, 16 * count),
        ),

      // textures
      createTexture: () => self.store(gl.createTexture()),
      deleteTexture: (t) => {
        gl.deleteTexture(self.get(t));
        self.release(t);
      },
      bindTexture: (target, t) => gl.bindTexture(target, self.get(t)),
      activeTexture: (unit) => gl.activeTexture(unit),
      texParameteri: (target, pname, param) =>
        gl.texParameteri(target, pname, param),
      generateMipmap: (target) => gl.generateMipmap(target),

      texImage2D: (
        target,
        level,
        internalFormat,
        width,
        height,
        border,
        format,
        kind,
        ptr,
        len,
      ) =>
        gl.texImage2D(
          target,
          level,
          internalFormat,
          width,
          height,
          border,
          format,
          kind,
          // A zero length is the null upload: allocate the storage and leave
          // it undefined, which is what a render target wants.
          len === 0 ? null : self.pixels(kind, ptr, len),
        ),

      texSubImage2D: (target, level, x, y, width, height, format, kind, ptr, len) =>
        gl.texSubImage2D(
          target,
          level,
          x,
          y,
          width,
          height,
          format,
          kind,
          self.pixels(kind, ptr, len),
        ),

      // samplers - WebGL 2 only, and WebGL 1 has no extension that adds them
      createSampler: () => self.store(self.isWebGL2 ? gl.createSampler() : null),
      deleteSampler: (s) => {
        if (self.isWebGL2) gl.deleteSampler(self.get(s));
        self.release(s);
      },
      bindSampler: (unit, s) => {
        if (self.isWebGL2) gl.bindSampler(unit, self.get(s));
      },
      samplerParameteri: (s, pname, param) => {
        if (self.isWebGL2) gl.samplerParameteri(self.get(s), pname, param);
      },

      // framebuffers
      createFramebuffer: () => self.store(gl.createFramebuffer()),
      deleteFramebuffer: (f) => {
        gl.deleteFramebuffer(self.get(f));
        self.release(f);
      },
      bindFramebuffer: (target, f) => gl.bindFramebuffer(target, self.get(f)),
      framebufferTexture2D: (target, attachment, texTarget, t, level) =>
        gl.framebufferTexture2D(target, attachment, texTarget, self.get(t), level),
      checkFramebufferStatus: (target) => gl.checkFramebufferStatus(target),

      createRenderbuffer: () => self.store(gl.createRenderbuffer()),
      deleteRenderbuffer: (r) => {
        gl.deleteRenderbuffer(self.get(r));
        self.release(r);
      },
      bindRenderbuffer: (target, r) => gl.bindRenderbuffer(target, self.get(r)),
      renderbufferStorage: (target, format, w, h) =>
        gl.renderbufferStorage(target, format, w, h),
      framebufferRenderbuffer: (target, attachment, rbTarget, r) =>
        gl.framebufferRenderbuffer(target, attachment, rbTarget, self.get(r)),

      readPixels: (x, y, w, h, format, kind, ptr, len) =>
        gl.readPixels(x, y, w, h, format, kind, self.bytes(ptr, len)),

      // drawing
      drawArrays: (mode, first, count) => gl.drawArrays(mode, first, count),
      drawElements: (mode, count, kind, offset) =>
        gl.drawElements(mode, count, kind, offset),
      drawArraysInstanced: (mode, first, count, instances) => {
        if (self.isWebGL2) gl.drawArraysInstanced(mode, first, count, instances);
        else if (self.instExt)
          self.instExt.drawArraysInstancedANGLE(mode, first, count, instances);
      },
      drawElementsInstanced: (mode, count, kind, offset, instances) => {
        if (self.isWebGL2)
          gl.drawElementsInstanced(mode, count, kind, offset, instances);
        else if (self.instExt)
          self.instExt.drawElementsInstancedANGLE(
            mode,
            count,
            kind,
            offset,
            instances,
          );
      },
    };

    const host = {
      now: () => performance.now() - self.start,
      canvasWidth: () => self.canvas.width,
      canvasHeight: () => self.canvas.height,
      consoleWrite: (level, ptr, len) => {
        const line = self.text(ptr, len);
        const method = ["debug", "info", "warn", "error"][level] ?? "log";
        console[method](line);
      },
    };

    return { webgl, host };
  }

  /// Fetch, instantiate, and hand back the module's exports.
  async instantiate(url) {
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`could not fetch ${url}: ${response.status}`);
    }

    // `instantiateStreaming` needs the server to send
    // `Content-Type: application/wasm`; falling back to `arrayBuffer` means
    // the page works when it does not, which includes most one-line servers.
    const bytes = await response.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, this.imports());

    this.memory = instance.exports.memory;
    this.exports = instance.exports;
    return instance.exports;
  }

  /// Match the drawing buffer to the element's size in device pixels.
  ///
  /// Two sizes, and mixing them up is the commonest way to get a blurry
  /// canvas: `clientWidth` is CSS pixels and `canvas.width` is device pixels,
  /// and on a high-density display they differ by `devicePixelRatio`. The
  /// module reads `canvas.width` through `host.canvasWidth`, so this is what
  /// decides how sharp the picture is.
  resize() {
    const ratio = window.devicePixelRatio || 1;
    const width = Math.max(1, Math.round(this.canvas.clientWidth * ratio));
    const height = Math.max(1, Math.round(this.canvas.clientHeight * ratio));
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
      return true;
    }
    return false;
  }

  /// Call `frame` until stopped. Returns a function that stops it.
  run(frame) {
    let running = true;
    const tick = () => {
      if (!running) return;
      this.resize();
      frame();
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    return () => {
      running = false;
    };
  }
}
