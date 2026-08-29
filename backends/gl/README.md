# `gl` — a hardware-accelerated graphics backend for `id`

Where [`backends/gfx`](../gfx/README.md) presents a software framebuffer that
`id` paints one pixel at a time, `gl` hands geometry straight to a GPU. It's a
second, sibling backend directory — not new entry points bolted onto `gfx.h` —
so a program picks its floor or its ceiling at build time, and the frame-loop
shape (`open` → loop of `draw → present → poll` → `close`) is identical either
way:

```sh
./idc.py demos/gl3d --backend backends/gl -o gl3d && ./gl3d
# a 640x480 window with a spinning, per-vertex-shaded cube. Close it (or Esc / q) to quit.
```

## The seam

The entire contract is [`gl.h`](gl.h). The window/input primitives are the
*same names and contract* as `gfx.h` on purpose — switching a program from the
software floor to the GPU path never changes its loop shape, only what it calls
each frame to draw:

| function | meaning |
| --- | --- |
| `gfx_open(w, h, title)` | open a GPU-backed `w`×`h` window, return 1/0 |
| `gfx_poll()`            | one event, non-blocking: `-2` quit, `-1` none, `>=0` key code |
| `gfx_close()`           | tear the context/window down |

New, GPU-specific primitives layer on top:

| function | meaning |
| --- | --- |
| `gl_begin_frame(r, g, b)`  | clear the color+depth buffers to `(r,g,b)` (0..255 each) |
| `gl_mat_identity()`, `gl_mat_perspective(...)`, `gl_mat_rotate_x/y/z(deg_x1000)`, `gl_mat_translate(...)`, `gl_mat_mul(a, b)` | build a 4x4 matrix, return an opaque **handle** |
| `gl_set_projection(handle)`, `gl_set_modelview(handle)` | load a handle's matrix onto the GL projection/modelview stack |
| `gl_draw_tris(verts, colors, count)` | draw `count` triangles from flattened `int[]` vertex/color lists |
| `gl_draw_points(positions, colors, count, size_x1000)` | draw `count` additively-blended, glowing `GL_POINTS` (a particle/starfield primitive) |
| `gl_width()`, `gl_height()`, `gl_aspect_x1000()` | the window's *live* pixel size and aspect ratio, tracking any runtime resize |
| `glwin_open/poll/close` | the window, named apart from the software backend's `gfx_*` so both can live in one binary |
| `glwin_mouse_x/y/buttons` | pointer state, same contract as `backends/gfx` |
| `gl_read_pixels(fb)` | read the rendered frame back into an `int[]` of `0xRRGGBB`, top row first |
| `gl_end_frame()`           | swap buffers, pump events, log a frame count, advance `GFX_MAX_FRAMES` |

Like `gfx`, `GFX_MAX_FRAMES` (checked in `gl_end_frame` instead of `gfx_present`,
since that's this backend's "one frame is done" moment) makes headless runs
self-terminating: after *N* frames, the next `gfx_poll()` reports quit (`-2`).

## The float problem, and how this backend solves it

`id` has no convenient way to build the float matrices a GPU pipeline needs (no
float literals worth relying on, no bitwise ops for bit-casting). Rather than
touch `idc.py` (out of scope for this backend) to add float support, **all
matrix math lives here, in C**, and the `id`/native seam only ever crosses
plain integers:

- Angles and translations cross as integers **scaled by 1000** ("milli-units"):
  an `id` int `y` passed to `gl_mat_translate` means "translate by `y/1000.0`
  units"; a `deg_x1000` passed to `gl_mat_rotate_y` means "rotate by
  `deg_x1000/1000.0` degrees." This is the same trick
  `demos/gfxdemo/fb/color.id`'s `rgb(r,g,b)` uses to pack a pixel — plain
  integer arithmetic standing in for something the language can't spell
  directly.
- A built matrix is **never marshalled back into `id`**. Each `gl_mat_*`
  builder returns a small int **handle** — an index into a fixed pool of 4x4
  matrices (`g_mat[1024][16]` in `gl_linux.c`) that lives entirely on the
  native side. `id` just threads handles between calls:
  `gl_mat_mul(gl_mat_translate(...), gl_mat_mul(gl_mat_rotate_y(...), gl_mat_rotate_x(...)))`
  builds a full modelview matrix without a single float ever crossing into
  `id`. This is simpler than round-tripping 16 bit-cast floats through an
  `IdList*` (the alternative the task description offered) and just as
  legitimate a lowering — see `gl.h` for the full rationale.
- Vertex data (`gl_draw_tris`'s `verts`/`colors`) *does* cross as `IdList*`,
  but every element is a plain int: a milli-unit coordinate, or a packed
  `0xRRGGBB` color (the same convention `gfx.h`'s framebuffer already uses).

`demos/gl3d` (see its own README) is the concrete proof: it builds an
eight-corner cube and a 12-triangle face table with pure integer arithmetic and
array literals, and drives the whole rotation/projection pipeline through
`gl_mat_*` handles — no `id`-side float ever appears.

## The window entry points are `glwin_*`, not `gfx_*`

They used to be `gfx_open`/`gfx_poll`/`gfx_close` -- the same names the
software backend exports. Two objects defining one symbol do not link, so a
program could have a software window or a GPU window and never both, which is
exactly what an engine that wants a GPU scene and a software HUD needs.

`-Wl,--allow-multiple-definition` is not the fix: it links, and then every
`gfx_open` call binds to whichever object came first, so one of the two
subsystems silently operates on a window it never opened.

The fix is the rename. `tests/backends.sh` links both backends into one binary
and drives two windows as the proof.

## Window resize

The window can be resized at runtime (by the user dragging an edge, or a
window manager honoring some other resize request). `gl_linux.c`'s `pump()`
now handles `ConfigureNotify` — the X event a resize generates — by tracking
the new drawable size into `g_w`/`g_h` and re-issuing `glViewport(0, 0, g_w,
g_h)` whenever it changes (it also logs a `"resized to WxH"` line to stderr,
so a headless run has visible proof a resize was observed and handled). The
window is created with `StructureNotifyMask` in its event mask specifically so
these events arrive.

That keeps the *viewport* correct automatically, but it can't fix a demo's
*projection* matrix on its own — `gl_mat_perspective`'s aspect ratio is just
whatever integer the `id` program passed it, typically once at startup. If a
demo builds its projection once and never rebuilds it, a resize will still
letterbox/stretch the image even though the viewport itself is right. The fix
is on the `id` side: **rebuild the projection every frame from the live
aspect**, using the two new query primitives:

```
// once per frame, before drawing:
int proj = gl_mat_perspective(60000, gl_aspect_x1000(), 100, 10000);
gl_set_projection(proj);
```

`gl_aspect_x1000()` returns `gl_width()*1000/gl_height()` (matrix-pool
allocation is cheap — see "known rough edges" below — so rebuilding a
perspective handle every frame is the intended usage, not a special case).
`gl_width()`/`gl_height()` are also useful on their own, e.g. to recompute
UI layout or a screen-space effect that depends on the window's pixel size.

## Particles / points

`gl_draw_points(positions, colors, count, size_x1000)` draws `count` points as
`GL_POINTS` — the primitive to reach for when a scene wants a galaxy of
thousands of glowing particles rather than shaded triangles. Unlike
`gl_draw_tris`, colors are one packed `0xRRGGBB` per *point*, not per vertex.
It renders with **additive blending** (`glBlendFunc(GL_SRC_ALPHA, GL_ONE)`) so
overlapping particles accumulate into bright cores instead of the topmost
point simply covering the rest, uses `GL_POINT_SMOOTH` for round sprites where
the driver supports it, and disables depth *writes* (not depth *testing*) for
the duration of the call so a glow never occludes geometry behind it while
still being correctly hidden by solid geometry in front of it. All of this GL
state is restored before the call returns, so it composes cleanly with
`gl_draw_tris` in either order within the same frame — e.g. draw a scene's
triangles, then its particle system, or vice versa.

## Platforms

- **Linux** ([`gl_linux.c`](gl_linux.c)) — Xlib + GLX. Chooses a
  double-buffered RGBA visual with a 16-bit depth buffer, creates a legacy
  (compatibility-profile) GL context with `glXCreateContext`, and draws with
  immediate-mode `glBegin`/`glEnd` — the simplest path that reliably works
  against mesa, per the guidance to prefer "actually renders via GPU" over
  modern-GL purity. **Validated**: built and run inside `tools/devshell.sh`
  against a live X server (XWayland), reporting a real GPU renderer string
  (`GL_RENDERER=... (radeonsi, ...) GL_VERSION=4.6 (Compatibility Profile)
  Mesa ...` in this environment) and rendering 120 frames of a spinning cube
  before exiting 0 via `GFX_MAX_FRAMES`.
- **macOS** — not implemented. `backend.json` has no `darwin` entry, so
  building `demos/gl3d --backend backends/gl` on macOS fails fast with a clear
  "backend has no support for platform 'darwin'" error rather than silently
  doing the wrong thing. The natural next step is a CGL/`NSOpenGLContext`
  backend behind this same `gl.h` (mirroring how `backends/gfx/gfx_macos.m`
  sits next to `gfx_linux.c`); not attempted here since this environment can
  only build and validate the Linux path.

## How it links

Same mechanism as `gfx`: `idc --backend backends/gl` reads
[`backend.json`](backend.json), compiles `gl_linux.c` on Linux, and links
`-lGL -lX11 -lm` (the `-lm` is for `tan`/`sin`/`cos` in the matrix builders —
easy to miss since desktop Linux usually auto-links libm through other
dependencies, but not guaranteed here).

## Known rough edges

- Same K&R-prototype-free `extern` linking as `gfx` (see its README) — a
  future `idc` feature for typed external declarations would let `cc` fully
  type-check backend calls instead of only checking them at the `id` side.
- The matrix pool (1024 slots) is a ring buffer with no explicit free; handles
  from many frames ago silently become invalid once overwritten. Fine for a
  demo that rebuilds a handful of matrices every frame and never holds a
  handle across frames; a long-lived-handle use case would need real
  allocation/refcounting.
- Window resize now updates the viewport automatically (see "Window resize"
  above), but a demo must still opt in to rebuilding its projection matrix
  from `gl_aspect_x1000()` every frame, or its image will stretch even though
  the viewport is correctly sized.
- `gl_draw_tris` assumes `verts`/`colors` are large enough for `count`
  triangles; it clamps to whatever's actually there rather than erroring, so a
  short list silently draws fewer triangles instead of crashing (matches
  `gfx_present`'s "missing pixels read as black" philosophy of failing soft).
