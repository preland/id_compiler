/* gl.h -- the `id` hardware-accelerated graphics backend ABI.
 *
 * This is the second tier promised by backends/gfx/README.md's "path to
 * true-native rendering": where `gfx` presents a software framebuffer that
 * `id` paints one pixel at a time, `gl` hands the pixels to a real GPU. The
 * window/input primitives (gfx_open, gfx_poll, gfx_close) are the SAME names
 * and the SAME contract as backends/gfx/gfx.h on purpose -- an `id` program's
 * frame-loop shape doesn't change when it switches from the software floor to
 * the hardware path, only what it calls each frame to draw.
 *
 * ABI notes (same rules as gfx.h, dictated by how `idc` links unknown
 * functions): every entry point is declared by idc as `extern int
 * id_<name>()` (no prototype) and called as `id_<name>(args)`, so every
 * function here returns `int`, is named with the `id_` prefix, and takes only
 * argument types idc knows how to lower: `id` int -> C int, `id` int[] ->
 * IdList* (below). There is no `id` string arg on this second tier except the
 * window title, matching gfx.h.
 *
 * -----------------------------------------------------------------------
 * The float problem, and how this backend solves it
 * -----------------------------------------------------------------------
 * `id` cannot conveniently build the float matrices a GPU pipeline needs
 * (see demos/gl3d/README.md for the full rationale), so this backend follows
 * the division of labor the task calls "legitimate and clean": ALL matrix
 * math lives here, in C, using real `double`/`float` arithmetic. `id` only
 * ever passes and receives *integers*:
 *
 *   - angles and translations cross the seam as integers scaled by 1000
 *     ("milli-units"): an id int `y` meaning translate-by-y/1000.0 units, or
 *     `deg` meaning deg/1000.0 degrees. This mirrors demos/gfxdemo's own
 *     `rgb(r,g,b)` packing trick -- plain integer arithmetic standing in for
 *     something the language can't spell directly.
 *   - a built matrix is never marshalled back into `id` at all. Instead each
 *     gl_mat_* builder returns an opaque *handle*: a small int index into a
 *     fixed pool of 4x4 matrices kept entirely on the native side. `id` just
 *     threads handles between calls (gl_mat_mul(a, b) -> new handle, then
 *     gl_set_modelview(handle)). This is simpler than round-tripping 16
 *     bit-cast floats through an IdList* and just as legitimate a lowering.
 *   - vertex data (positions, colors) DOES cross as IdList* of int, but every
 *     element is either a milli-unit coordinate (divide by 1000.0 on this
 *     side to get the float) or a packed 0xRRGGBB color (same convention
 *     gfx.h's framebuffer already uses).
 *
 * -----------------------------------------------------------------------
 * The seam, function by function
 * -----------------------------------------------------------------------
 */
#ifndef ID_GL_H
#define ID_GL_H

/* Growable list, byte-for-byte identical to the IdList in idc.py's RUNTIME
 * (and to backends/gfx/gfx.h's copy). An `id` `int[]` lowers to `IdList*`. */
typedef struct { int len, cap; long long* data; } IdList;

/* ---- window / input (identical contract to backends/gfx/gfx.h) ---------- */

/* Open a w x h GPU-backed window with the given UTF-8 title. 1 on success, 0
 * on failure (e.g. no GLX-capable visual). Call once before any gl_* call. */
/* -- key codes -------------------------------------------------------------
 * Identical to the software backend's (see backends/gfx/gfx.h): 0..255 is a
 * key that makes a character, 256..511 one that does not, and GFX_RELEASED
 * added on top marks a release. A program should not have to ask which window
 * system it is talking to in order to know what Left means. */
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

extern int id_glwin_open(int w, int h, const char* title);

/* Poll one input event, non-blocking: -2 quit (close button, or the
 * GFX_MAX_FRAMES headless self-terminate hook firing), -1 no event this poll,
 * >=0 a key code. Same convention as gfx.h's id_glwin_poll. */
extern int id_glwin_poll(void);

/* Tear down the GL context and window. Safe to call once at exit. Returns 0. */
extern int id_glwin_close(void);

/* ---- per-frame primitives ------------------------------------------------ */

/* Begin a frame: clear the color buffer to (r, g, b) (each 0..255) and clear
 * the depth buffer. Call once at the start of every frame. Returns 0. */
extern int id_gl_begin_frame(int r, int g, int b);

/* End a frame: swap the front/back buffers (presenting what was drawn) and
 * pump the platform event queue. Also advances the GFX_MAX_FRAMES counter
 * (see backends/gfx for the identical hook) and logs a
 * "rendered N frame(s)" line to stderr so headless runs have visible proof
 * real draw calls happened. Call once at the end of every frame. Returns the
 * number of frames rendered so far (>=1). */
extern int id_gl_end_frame(void);

/* ---- matrix builders: each returns an opaque handle (>=0) into a native
 * pool of 4x4 matrices. `id` never sees the floats, only the handle. -------- */

/* The 4x4 identity matrix. */
extern int id_gl_mat_identity(void);

/* A perspective projection matrix (like gluPerspective): vertical field of
 * view in thousandths of a degree, aspect ratio (width/height) in
 * thousandths, near and far clip planes in thousandths of a unit. */
extern int id_gl_mat_perspective(int fov_deg_x1000, int aspect_x1000,
                                  int near_x1000, int far_x1000);

/* Rotation about the X/Y/Z axis, by an angle in thousandths of a degree. */
extern int id_gl_mat_rotate_x(int deg_x1000);
extern int id_gl_mat_rotate_y(int deg_x1000);
extern int id_gl_mat_rotate_z(int deg_x1000);

/* A translation matrix, each axis in thousandths of a unit. */
extern int id_gl_mat_translate(int x_x1000, int y_x1000, int z_x1000);

/* Matrix product a*b (a and b are handles from any gl_mat_* builder above),
 * returned as a new handle. Order matches OpenGL's column-vector convention:
 * applying the result to a vector v computes a*(b*v), i.e. b is applied
 * first. */
extern int id_gl_mat_mul(int a, int b);

/* ---- pipeline state ------------------------------------------------------ */

/* Load `handle`'s matrix onto the GL_PROJECTION stack. */
extern int id_gl_set_projection(int handle);

/* Load `handle`'s matrix onto the GL_MODELVIEW stack. */
extern int id_gl_set_modelview(int handle);

/* ---- geometry -------------------------------------------------------------
 * Draw `count` triangles (so 3*count vertices). `verts` holds 9 ints per
 * triangle (x,y,z, x,y,z, x,y,z), each a milli-unit coordinate (divide by
 * 1000.0 for the float). `colors` holds 3 ints per triangle, one packed
 * 0xRRGGBB per vertex, in the same order as `verts` -- GL interpolates them
 * across the triangle (Gouraud shading) via the fixed-function pipeline.
 * Uses whatever matrices are currently loaded via gl_set_projection /
 * gl_set_modelview. Returns 0. */
extern int id_gl_draw_tris(IdList* verts, IdList* colors, int count);

/* Draw `count` GL_POINTS as light-emitting particles (e.g. a starfield/galaxy
 * of thousands of glowing points). `positions` holds 3 ints per point
 * (x,y,z milli-units, same convention as gl_draw_tris' verts); `colors` holds
 * 1 packed 0xRRGGBB per point (NOT per-vertex-per-triangle -- one color per
 * point here). `size_x1000` is the point diameter in thousandths of a pixel
 * (clamped to a sane minimum of 1.0 px).
 *
 * Rendered with additive blending (glBlendFunc(GL_SRC_ALPHA, GL_ONE)) so
 * overlapping particles accumulate into bright cores instead of the last one
 * drawn simply covering the rest, round point sprites via GL_POINT_SMOOTH
 * where the driver supports it, and depth writes disabled for the duration
 * of the call (glDepthMask(GL_FALSE)) so a glowing particle never occludes
 * geometry behind it -- it's still depth-*tested*, so particles behind solid
 * geometry are correctly hidden by it. All of this GL state is restored to
 * whatever it was before the call returns, so gl_draw_points composes
 * cleanly with gl_draw_tris in either order within the same frame.
 *
 * Uses whatever matrices are currently loaded via gl_set_projection /
 * gl_set_modelview, exactly like gl_draw_tris. Returns 0. */
extern int id_gl_draw_points(IdList* positions, IdList* colors, int count,
                              int size_x1000);

/* ---- live window size / aspect --------------------------------------------
 * The window can be resized at runtime by the window manager/user (see
 * gl_linux.c's ConfigureNotify handling); the viewport is kept in sync
 * automatically, but a program's *projection* matrix (built once via
 * gl_mat_perspective and cached) is NOT -- it was built from whatever aspect
 * ratio was true at the time. To avoid a stretched image after a resize, a
 * demo should rebuild its perspective matrix every frame (or at least after
 * detecting a change) using the LIVE aspect from gl_aspect_x1000(), e.g.:
 *
 *   proj = gl_mat_perspective(60000, gl_aspect_x1000(), 100, 100000)
 *   gl_set_projection(proj)
 *
 * done once per frame, this keeps the image correctly proportioned across
 * any resize with no other code changes. */

/* The window's current drawable width/height in pixels. Reflects the size
 * given to gfx_open until a resize is observed (see gl_linux.c's
 * ConfigureNotify handling), after which it tracks the live size. 0 if no
 * window is open. */
/* Pointer state, in window pixels, as of the last poll. Buttons are a bitmask:
 * bit 0 left, bit 1 middle, bit 2 right. Same contract as the software
 * backend. */
extern int id_glwin_mouse_x(void);
extern int id_glwin_mouse_y(void);
extern int id_glwin_mouse_buttons(void);

/* Read the rendered frame back into an int[] of w*h 0xRRGGBB pixels, row-major
 * with the top row first -- the same layout gfx_present consumes, so a GL
 * frame can be written out as a PPM by the very code that dumps a software
 * one. Call between the last draw call and gl_end_frame: it reads the buffer
 * being drawn into, because after the swap the front buffer belongs to the
 * compositor and reads back black.
 *
 * This exists because the GL path had no off-screen verification at all: the
 * software path could dump pixels from pure `id`, and GPU output could only be
 * eyeballed through an external window grabber. `fb` must hold at least
 * gl_width()*gl_height() elements; it is filled up to whichever is smaller.
 * Returns the number of pixels written.
 *
 * The values are whatever the drawable actually holds, which is not always
 * what was asked for: on a visual with fewer than 8 bits per channel, or with
 * dithering, a clear to (20, 40, 160) can read back as (20, 38, 160). Compare
 * with a tolerance, or use channel values that survive any format. */
extern int id_gl_read_pixels(IdList* fb);

extern int id_gl_width(void);
extern int id_gl_height(void);

/* The window's current aspect ratio (width/height), in thousandths, suitable
 * to pass straight as gl_mat_perspective's aspect_x1000 argument. Returns
 * 1000 (1:1) if height is currently 0 (e.g. no window open yet) to avoid a
 * divide-by-zero. */
extern int id_gl_aspect_x1000(void);

#endif /* ID_GL_H */
