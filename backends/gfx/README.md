# `gfx` — a platform-agnostic graphics backend for `id`

A windowed graphics backend, built the way the terminal engine was: a tiny set
of native primitives that `id` drives from its own frame loop. Where
`demos/engine` keeps an off-screen **character** buffer and flushes it to a
terminal with ANSI escapes, `gfx` keeps an off-screen **pixel** buffer and
presents it to a real OS window. The drawing logic stays in portable `id`; only
the window and the blit are native.

```sh
./idc.py demos/gfxdemo --backend backends/gfx -o gfxdemo && ./gfxdemo
# a 320x200 window with a sliding, color-cycling box. Close it (or Esc / q) to quit.
```

## The seam

The entire contract between `id` and the platform is [`gfx.h`](gfx.h) — five
integer-returning functions:

| function | meaning |
| --- | --- |
| `gfx_open(w, h, title)`  | open a `w`×`h` window, return 1/0 |
| `gfx_present(fb)`        | blit the `int[]` pixel buffer (`0xRRGGBB`, row-major, top row first) and pump events |
| `gfx_poll()`             | one event, non-blocking: `-2` quit, `-1` none, `>=0` key code |
| `gfx_close()`            | tear the window down |

Both backends also honor `GFX_MAX_FRAMES`: if that environment variable is set
to a positive integer *N*, `gfx_present` counts calls and, once *N* have
happened, makes the *next* `gfx_poll()` report quit (`-2`). This lets a build
run headlessly (no human closing the window) for a bounded number of frames and
exit 0 — the mechanism used to validate this backend in CI/dev-shell runs.

`id` never names a platform API; it only calls these. That seam is exactly
`id`'s segmentation philosophy applied to portability: the platform-specific
code is quarantined behind a handful of names, and the whole rule-of-3 `id` tree
above it (`demos/gfxdemo`) is identical on every OS.

### Why these signatures

`idc` resolves a call to an undefined function as `extern int id_<name>()`,
satisfied at link time (see the README's "Functions link across files"
section). So every backend entry point is named `id_*`, returns `int`, and
takes arguments lowered the way `idc` lowers them (`int`→`int`, `string`→`char*`,
`int[]`→`IdList*`). The framebuffer is passed as one `int[]` so a whole frame
crosses the boundary in a single call, not a million per-pixel ones — the same
"build the buffer, then flush once" shape the terminal engine uses.

## How it links

`idc` grew a `--backend DIR` flag. It reads `DIR/backend.json`, picks the entry
for the host platform, compiles that platform's sources to objects, and appends
them plus the platform link flags to the final `cc` invocation. Nothing is
hard-coded in the compiler — a backend is self-describing:

```json
{ "platforms": {
    "darwin": { "sources": ["gfx_macos.m"], "cflags": ["-fobjc-arc"],
                "link": ["-framework", "Cocoa", "-framework", "QuartzCore"] },
    "linux":  { "sources": ["gfx_linux.c"], "cflags": [],
                "link": ["-lX11"] } } }
```

## Platforms

- **macOS** ([`gfx_macos.m`](gfx_macos.m)) — Cocoa + QuartzCore via the system
  toolchain (no third-party libraries). A layer-backed `NSView` draws the
  framebuffer as a `CGImage`. `id` keeps its own loop, so the app is
  `finishLaunching`ed once and events are pumped non-blockingly with
  `nextEventMatchingMask:…distantPast` each frame. **Built and run.**
- **Linux** ([`gfx_linux.c`](gfx_linux.c)) — Xlib `XPutImage` over a software
  framebuffer, `-lX11` only. Same header, same contract; this is the concrete
  proof the seam is portable. **Validated**: built and run inside
  `tools/devshell.sh` against a live X server —
  `GFX_MAX_FRAMES=60 ./gfxdemo` presents 60 frames and exits 0. (Earlier drafts
  of this file were missing `#include <stdint.h>`, needed for the `uint32_t`
  pixel buffer; fixed as part of validating this path.)

Adding Windows (GDI/`StretchDIBits`) or a Wayland backend is one more source
file plus a `backend.json` entry — no change to `id` code or to the compiler.

## Path to true-native rendering

Today the only primitive is "present a software framebuffer," which is the most
portable floor and keeps all drawing in `id`. The header is built to grow a
second tier *without breaking the first*: add entry points like `gfx_rect`,
`gfx_blit`, or a GPU pipeline (Metal on macOS, Vulkan on Linux) backed
per-platform, while `gfx_present` stays as the always-available fallback. `id`
programs opt into the faster path by calling the new names; the framebuffer path
keeps working everywhere it always did.

**This second tier now exists**: [`backends/gl`](../gl/README.md) is a sibling
backend (same `gfx_open`/`gfx_poll`/`gfx_close`, a separate `backend.json`) that
adds a real GPU pipeline via GLX/OpenGL — `demos/gl3d` drives it to render a
spinning, per-vertex-shaded cube. It's a different backend directory rather
than new entry points bolted onto *this* header, which keeps `gfx.h` exactly as
simple as the day it validated the seam; a program picks its floor
(`--backend backends/gfx`) or its ceiling (`--backend backends/gl`) at build
time and the frame-loop shape (open → loop of draw/present/poll → close) is
identical either way.

## Known rough edges (first slice)

- The link-time `extern` mechanism declares backend functions K&R-style (no
  prototype), so `cc` warns `-Wdeprecated-non-prototype` and a future C23-only
  toolchain would reject it. The clean fix is a small `idc` feature for typed
  external declarations; tracked as future work, not needed to run today.
- Window resize is now followed: `pump()` handles `ConfigureNotify` and
  reallocates the surface, and `gfx_width()`/`gfx_height()` report the live
  size. An `id` program must ask each frame and re-init its framebuffer when
  the answer changes — the surface follows the window, and a framebuffer that
  no longer matches is drawn into the top-left corner with black margins.
  There is no way to refuse a resize; a tiling window manager will impose one
  on map, before the first frame.
- Input now covers arrow keys, F-keys, Home/End/PgUp/PgDn/Insert/Delete, bare
  modifiers, and **key release** — see the key-code block in `gfx.h`. Codes
  0–255 are unchanged, so nothing written against the old contract moved.
  Auto-repeat is filtered, so "is this key held" is answerable for the first
  time.
- Pointer state is `gfx_mouse_x()`, `gfx_mouse_y()`, `gfx_mouse_buttons()` —
  state, not events, because a click is an edge and `id` can see an edge by
  comparing frames.
- **Audio: none.** There is no sound backend anywhere in the repo. It would be
  a new `backend.json` beside these two (`snd_open`, `snd_queue(int[])`), and
  it should be specified before it is built.
- `gfx_macos.m` implements the same extended contract, but **it has not been
  compiled or run**: the machine this work was done on is Linux. Treat it as a
  faithful translation awaiting a machine.
- `gfx.h`'s `IdList` must stay byte-identical to `idc.py`'s runtime `IdList`; if
  that layout ever changes, update both.
