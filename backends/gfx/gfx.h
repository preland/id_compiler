/* gfx.h -- the `id` graphics backend ABI (the platform-agnostic seam).
 *
 * This header defines the *entire* contract between `id` programs and the
 * native window/present code. An `id` program never names a platform API; it
 * only calls these five functions, which `idc` resolves at link time against
 * one platform backend object (gfx_macos.m, gfx_linux.c, ...). Swapping the OS
 * swaps the object behind this header and nothing else -- the same way the
 * terminal engine abstracts over termios/ANSI behind put/getkey/flush.
 *
 * Design: a *software framebuffer*. The `id` side owns an `int[]` of w*h pixels
 * (one 0xRRGGBB value per pixel, row-major, top row first) and draws into it in
 * pure, portable `id`. Once per frame it hands the whole buffer to gfx_present,
 * which blits it to the window. All drawing logic stays in `id`; the backend
 * only opens a window, copies pixels, and reports input. This keeps the
 * per-platform code tiny and is the most portable possible seam.
 *
 * Path to true-native rendering: this same header is the place to grow a
 * second tier of entry points (gfx_rect, gfx_blit, a GPU pipeline, ...) backed
 * per-OS by Metal/Vulkan, while gfx_present stays as the always-available
 * software path. The framebuffer is the floor, not the ceiling.
 *
 * ABI notes (dictated by how `idc` links unknown functions):
 *   - Every entry point is declared `extern int id_<name>()` by idc and is
 *     called as `id_<name>(args)`. So each function here is named with the
 *     `id_` prefix and returns `int`.
 *   - Argument lowering mirrors idc's: `id` int -> C int, `id` string -> char*,
 *     `id` int[] -> IdList* (below). These match what idc emits at the call.
 */
#ifndef ID_GFX_H
#define ID_GFX_H

/* Growable list, byte-for-byte identical to the IdList in idc.py's RUNTIME.
 * An `id` `int[]` lowers to `IdList*`; each element is one cell. For an int
 * list the cell holds the int directly (only floats are bit-boxed), so a pixel
 * value is simply `(int)data[i]`. If idc's runtime layout ever changes, this
 * struct must change with it. */
typedef struct { int len, cap; long long* data; } IdList;

/* -- key codes ------------------------------------------------------------
 * id_gfx_poll returns one int, so the codes share one space:
 *
 *     0 .. 255      a key that makes a character: its byte. Unchanged, so
 *                   every program written against the old contract still
 *                   reads the same values for letters, Return, Esc and so on.
 *     256 .. 511    a key that makes no character. XLookupString yields
 *                   nothing for these, which is why arrows, F-keys and bare
 *                   modifiers used to be invisible to `id` entirely.
 *     + GFX_RELEASED  the same code, released rather than pressed.
 *
 * So a program that only wants "which letter" keeps working untouched, one
 * that wants arrows tests against the names below, and one that wants "is
 * this key held" tracks presses and releases itself -- which it could not do
 * at all before, because releases were never reported. */
#define GFX_RELEASED   65536

#define GFX_KEY_LEFT   256
#define GFX_KEY_RIGHT  257
#define GFX_KEY_UP     258
#define GFX_KEY_DOWN   259
#define GFX_KEY_HOME   260
#define GFX_KEY_END    261
#define GFX_KEY_PGUP   262
#define GFX_KEY_PGDN   263
#define GFX_KEY_INSERT 264
#define GFX_KEY_DELETE 265
#define GFX_KEY_F1     266            /* F1..F12 are 266..277 */
#define GFX_KEY_SHIFT  278
#define GFX_KEY_CTRL   279
#define GFX_KEY_ALT    280

/* Open a window with a w*h pixel surface and the given UTF-8 title.
 * Returns 1 on success, 0 on failure. Call once before presenting. */
extern int id_gfx_open(int w, int h, const char* title);

/* Present one frame: copy w*h pixels from `fb` (0xRRGGBB each, row-major, top
 * row first) to the window and pump the platform's pending events. `fb` must
 * hold at least w*h elements; extra elements are ignored, missing ones read as
 * black. Returns 0. Call once per frame. */
extern int id_gfx_present(IdList* fb);

/* Poll one input event without blocking. Drains/advances the platform event
 * queue and returns:
 *     -2  the window wants to close (close button / quit) -- stop the loop
 *     -1  no event this poll
 *    >=0  a key event; see the key-code block above. Below GFX_RELEASED it is
 *         a press, at or above it a release of (code - GFX_RELEASED).
 * Mirrors getkey()'s -1 convention, with -2 added for "quit". Poll in a loop
 * each frame to drain everything buffered since the last frame.
 *
 * Auto-repeat is filtered: X delivers a release/press pair at one timestamp
 * while a key is held, and reporting those releases would make a held key
 * look like a rapid tap. */
extern int id_gfx_poll(void);

/* The surface's current size in pixels. These can differ from what gfx_open
 * asked for: a tiling window manager resizes the window on map, and the
 * backend follows it. Ask once per frame and re-init the framebuffer when it
 * changes -- there is no way to refuse a resize, and a surface that no longer
 * matches the window is drawn into the top-left corner with black margins. */
extern int id_gfx_width(void);
extern int id_gfx_height(void);

/* Pointer state, in surface pixels, as of the last poll/present. Buttons are a
 * bitmask: bit 0 left, bit 1 middle, bit 2 right, bits 3-4 wheel up/down.
 *
 * State rather than events, deliberately: a click is an edge, and `id` sees an
 * edge by comparing this frame's buttons with last frame's. That keeps the
 * seam three small functions wide instead of growing an event encoding.
 *
 * The three real buttons are state; the two wheel bits are a *latch*. A wheel
 * notch has no duration to report -- the platform delivers it as a press and a
 * release together -- so a notch sets its bit and reading the mask clears it,
 * which makes exactly one read see each notch. Poll the mask once a frame and
 * the two behave identically; poll it twice and the second read sees no wheel. */
extern int id_gfx_mouse_x(void);
extern int id_gfx_mouse_y(void);
extern int id_gfx_mouse_buttons(void);

/* Close the window and release backend resources. Safe to call once at exit;
 * a no-op if no window is open. Returns 0. */
extern int id_gfx_close(void);

#endif /* ID_GFX_H */
