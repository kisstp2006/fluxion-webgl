// SPDX-License-Identifier: BSL-1.0

//! The page, as WebAssembly imports.
//!
//! Everything a running renderer needs that is not a WebGL call: what time it
//! is, how big the canvas is, and somewhere for a line of text to go. Under
//! its own import module - `host` rather than `webgl` - so the glue can hand
//! over the two separately, and so a program that wants only the drawing can
//! supply an empty one.
//!
//! Small on purpose. Everything here is something the standard library would
//! normally provide and cannot, because `wasm32-freestanding` has no clock,
//! no console and no operating system underneath it. See `host` for why each
//! one is missing rather than merely absent.

/// Milliseconds since the page loaded, as `performance.now()` returns them.
///
/// A `f64` because that is what it is: sub-millisecond precision, and enough
/// range that it will not wrap while anybody is looking. It is monotonic and
/// it is not wall-clock time - there is no wall clock here.
pub extern "host" fn now() f64;

/// The width of the drawing buffer, in device pixels.
pub extern "host" fn canvasWidth() i32;

/// The height of the drawing buffer, in device pixels.
pub extern "host" fn canvasHeight() i32;

/// One line of text to the console, at a severity the glue maps to
/// `console.debug` through `console.error`.
pub extern "host" fn consoleWrite(level: u32, ptr: [*]const u8, len: u32) void;
