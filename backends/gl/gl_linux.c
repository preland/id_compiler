/* gl_linux.c -- Linux/GLX backend for the `id` hardware-accelerated graphics
 * ABI (see gl.h).
 *
 * Opens an X11 window with a GLX-capable visual, creates a legacy
 * (fixed-function) OpenGL context with glXCreateContext, and drives it with
 * immediate-mode glBegin/glEnd -- the simplest thing that reliably works
 * against mesa's software/hardware GLX implementation, per the task's
 * guidance to prefer "actually renders via GPU" over modern-GL purity.
 *
 * Like backends/gfx/gfx_linux.c, `id` drives its own frame loop, so events
 * are drained non-blockingly with XPending/XNextEvent each poll/end_frame --
 * never XNextEvent in a blocking loop.
 *
 * Headless/CI testing: GFX_MAX_FRAMES works exactly like the gfx backend
 * (see gfx_linux.c's header comment): after N calls to id_gl_end_frame, the
 * next id_glwin_poll() reports quit (-2).
 */
#include <GL/gl.h>
#include <GL/glx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gl.h"

/* M_PI is a glibc/POSIX extension, not ISO C -- <math.h> only defines it when
 * a feature-test macro (_DEFAULT_SOURCE etc.) is active, which isn't
 * guaranteed under every -std= a caller might build this with. Define our own
 * so this file doesn't depend on the compiler's default feature-test mode. */
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ---- window / GLX state --------------------------------------------------- */
static Display*     g_dpy = NULL;
static Window       g_win = 0;
static GLXContext   g_ctx = NULL;
static XVisualInfo* g_vi = NULL;
static Colormap     g_cmap = 0;
static Atom         g_wm_delete = 0;
static int          g_w = 0, g_h = 0;
static int          g_quit = 0;

/* tiny key ring, same contract as backends/gfx */
#define GFX_KEYQ 256
static int g_keyq[GFX_KEYQ];
static int g_keyhead = 0, g_keytail = 0;
/* Key codes, pointer state and the auto-repeat filter are the software
 * backend's, verbatim in behaviour: a program should not have to ask which
 * window system it is talking to in order to know what Left means. See
 * gfx.h's key-code block -- gl.h repeats the same constants. */
static int g_mx = 0, g_my = 0, g_btn = 0;

static int special_code(KeySym ks) {
    switch (ks) {
    case XK_Left:      return 256;
    case XK_Right:     return 257;
    case XK_Up:        return 258;
    case XK_Down:      return 259;
    case XK_Home:      return 260;
    case XK_End:       return 261;
    case XK_Page_Up:   return 262;
    case XK_Page_Down: return 263;
    case XK_Insert:    return 264;
    case XK_Delete:    return 265;
    case XK_Shift_L: case XK_Shift_R:     return 278;
    case XK_Control_L: case XK_Control_R: return 279;
    case XK_Alt_L: case XK_Alt_R:         return 280;
    default: break;
    }
    if (ks >= XK_F1 && ks <= XK_F12) return 266 + (int)(ks - XK_F1);
    return -1;
}

static int event_code(XKeyEvent* ke) {
    char buf[8];
    KeySym ks = 0;
    int n = XLookupString(ke, buf, sizeof(buf), &ks, NULL);
    if (n > 0) return (unsigned char)buf[0];
    return special_code(ks);
}

static void key_push(int code) {
    int n = (g_keytail + 1) % GFX_KEYQ;
    if (n == g_keyhead) return;
    g_keyq[g_keytail] = code; g_keytail = n;
}
static int key_pop(void) {
    if (g_keyhead == g_keytail) return -1;
    int code = g_keyq[g_keyhead];
    g_keyhead = (g_keyhead + 1) % GFX_KEYQ;
    return code;
}

static void pump(void) {
    if (!g_dpy) return;
    while (XPending(g_dpy)) {
        XEvent ev;
        XNextEvent(g_dpy, &ev);
        if (ev.type == ClientMessage) {
            if ((Atom)ev.xclient.data.l[0] == g_wm_delete) g_quit = 1;
        } else if (ev.type == KeyPress) {
            int code = event_code(&ev.xkey);
            if (code >= 0) key_push(code);
        } else if (ev.type == KeyRelease) {
            /* X sends release+press at one timestamp while a key repeats;
               reporting those releases makes a held key look like a tap. */
            XEvent nxt;
            int repeat = XPending(g_dpy) && (XPeekEvent(g_dpy, &nxt), 1)
                       && nxt.type == KeyPress
                       && nxt.xkey.time == ev.xkey.time
                       && nxt.xkey.keycode == ev.xkey.keycode;
            if (!repeat) {
                int code = event_code(&ev.xkey);
                if (code >= 0) key_push(code + GFX_RELEASED);
            }
        } else if (ev.type == ButtonPress || ev.type == ButtonRelease) {
            if (ev.xbutton.button >= 1 && ev.xbutton.button <= 5) {
                if (ev.type == ButtonPress) g_btn |=  1 << (ev.xbutton.button - 1);
                else                        g_btn &= ~(1 << (ev.xbutton.button - 1));
            }
            g_mx = ev.xbutton.x; g_my = ev.xbutton.y;
        } else if (ev.type == MotionNotify) {
            g_mx = ev.xmotion.x; g_my = ev.xmotion.y;
        } else if (ev.type == ConfigureNotify) {
            /* The window's drawable size changed (interactive resize, or a
             * window manager honoring a resize request). Track the new size
             * and re-point the GL viewport at it so subsequent frames render
             * into the full window instead of the stale open()-time
             * rectangle. The id side is responsible for rebuilding its
             * projection matrix's aspect ratio too -- see id_gl_aspect_x1000
             * below -- otherwise the image stays correctly *sized* but
             * stretched. */
            int nw = ev.xconfigure.width, nh = ev.xconfigure.height;
            if (nw > 0 && nh > 0 && (nw != g_w || nh != g_h)) {
                g_w = nw; g_h = nh;
                glViewport(0, 0, g_w, g_h);
                fprintf(stderr, "gl_linux: resized to %dx%d, viewport updated\n", g_w, g_h);
            }
        }
    }
}

/* GFX_MAX_FRAMES headless self-terminate hook -- identical convention to
 * backends/gfx/gfx_linux.c. */
static int g_max_frames = -1;
static int g_max_frames_read = 0;
static int g_frame_count = 0;

static int max_frames(void) {
    if (!g_max_frames_read) {
        g_max_frames_read = 1;
        const char* s = getenv("GFX_MAX_FRAMES");
        if (s && *s) g_max_frames = atoi(s);
    }
    return g_max_frames;
}

int id_glwin_open(int w, int h, const char* title) {
    if (g_dpy) return 1;
    if (w <= 0 || h <= 0) return 0;
    g_dpy = XOpenDisplay(NULL);
    if (!g_dpy) return 0;

    int screen = DefaultScreen(g_dpy);
    /* Ask for a double-buffered RGBA visual with a depth buffer -- the
     * minimum a 3D scene needs. */
    int attrs[] = { GLX_RGBA, GLX_DEPTH_SIZE, 16, GLX_DOUBLEBUFFER, None };
    g_vi = glXChooseVisual(g_dpy, screen, attrs);
    if (!g_vi) {
        /* fall back to single-buffered in case the display can't double-buffer */
        int attrs_sb[] = { GLX_RGBA, GLX_DEPTH_SIZE, 16, None };
        g_vi = glXChooseVisual(g_dpy, screen, attrs_sb);
    }
    if (!g_vi) { XCloseDisplay(g_dpy); g_dpy = NULL; return 0; }

    g_cmap = XCreateColormap(g_dpy, RootWindow(g_dpy, screen), g_vi->visual, AllocNone);
    XSetWindowAttributes swa;
    memset(&swa, 0, sizeof(swa));
    swa.colormap = g_cmap;
    swa.event_mask = ExposureMask | KeyPressMask | KeyReleaseMask |
                     ButtonPressMask | ButtonReleaseMask | PointerMotionMask |
                     StructureNotifyMask;

    g_win = XCreateWindow(g_dpy, RootWindow(g_dpy, screen), 0, 0, w, h, 0,
                          g_vi->depth, InputOutput, g_vi->visual,
                          CWColormap | CWEventMask, &swa);
    XStoreName(g_dpy, g_win, title ? title : "id");
    /* WM_CLASS, so a window manager can recognise an `id` program. Without it
       the class is empty and every rule has to match on the title, which is
       whatever the program passed to glwin_open. See tools/headless.sh. */
    {
        XClassHint ch;
        ch.res_name = (char*)"id";
        ch.res_class = (char*)"id-gl";
        XSetClassHint(g_dpy, g_win, &ch);
    }
    g_wm_delete = XInternAtom(g_dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(g_dpy, g_win, &g_wm_delete, 1);

    g_ctx = glXCreateContext(g_dpy, g_vi, NULL, GL_TRUE);
    if (!g_ctx) {
        /* no direct rendering available (common headlessly) -- retry indirect */
        g_ctx = glXCreateContext(g_dpy, g_vi, NULL, GL_FALSE);
    }
    if (!g_ctx) {
        XDestroyWindow(g_dpy, g_win); g_win = 0;
        XCloseDisplay(g_dpy); g_dpy = NULL;
        return 0;
    }

    XMapWindow(g_dpy, g_win);
    XFlush(g_dpy);

    if (!glXMakeCurrent(g_dpy, g_win, g_ctx)) {
        glXDestroyContext(g_dpy, g_ctx); g_ctx = NULL;
        XDestroyWindow(g_dpy, g_win); g_win = 0;
        XCloseDisplay(g_dpy); g_dpy = NULL;
        return 0;
    }

    glViewport(0, 0, w, h);
    glEnable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);   /* correctness over perf for a small demo mesh */

    g_w = w; g_h = h; g_quit = 0;
    g_keyhead = g_keytail = 0;
    g_frame_count = 0;
    fprintf(stderr, "gl_linux: opened %dx%d window, GL_RENDERER=%s GL_VERSION=%s\n",
            w, h, (const char*)glGetString(GL_RENDERER),
            (const char*)glGetString(GL_VERSION));
    return 1;
}

int id_glwin_poll(void) {
    if (!g_dpy) return -1;
    pump();
    if (g_quit) return -2;
    return key_pop();
}

int id_glwin_close(void) {
    if (!g_dpy) return 0;
    fprintf(stderr, "gl_linux: closing after %d frame(s) rendered\n", g_frame_count);
    if (g_ctx) { glXMakeCurrent(g_dpy, None, NULL); glXDestroyContext(g_dpy, g_ctx); g_ctx = NULL; }
    if (g_win) { XDestroyWindow(g_dpy, g_win); g_win = 0; }
    if (g_cmap) { XFreeColormap(g_dpy, g_cmap); g_cmap = 0; }
    if (g_vi) { XFree(g_vi); g_vi = NULL; }
    XCloseDisplay(g_dpy);
    g_dpy = NULL; g_w = g_h = 0;
    return 0;
}

/* ---- live window size / aspect --------------------------------------------- */

int id_glwin_mouse_x(void) { return g_mx; }
int id_glwin_mouse_y(void) { return g_my; }
int id_glwin_mouse_buttons(void) { return g_btn; }

int id_gl_width(void) { return g_w; }
int id_gl_height(void) { return g_h; }

int id_gl_aspect_x1000(void) {
    if (g_h <= 0) return 1000; /* guard div-by-zero; 1:1 is a harmless fallback */
    return (int)((long long)g_w * 1000 / g_h);
}

/* ---- per-frame ------------------------------------------------------------ */

int id_gl_begin_frame(int r, int g, int b) {
    glClearColor((float)r / 255.0f, (float)g / 255.0f, (float)b / 255.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    return 0;
}

int id_gl_end_frame(void) {
    if (g_dpy) glXSwapBuffers(g_dpy, g_win);
    pump();
    g_frame_count++;
    /* Throttle to ~1/sec (assuming a ~60fps caller) so a long-running windowed
     * session doesn't spam stderr, while still proving draw calls are
     * happening; headless GFX_MAX_FRAMES runs are short enough that the
     * final "reached" line below is the important signal anyway. */
    if (g_frame_count == 1 || g_frame_count % 60 == 0)
        fprintf(stderr, "gl_linux: rendered %d frame(s)\n", g_frame_count);
    int max = max_frames();
    if (max >= 0 && g_frame_count >= max) {
        fprintf(stderr, "gl_linux: GFX_MAX_FRAMES=%d reached, synthesizing quit\n", max);
        g_quit = 1;
    }
    return g_frame_count;
}

/* Read the rendered frame back as 0xRRGGBB pixels, top row first.
 *
 * glReadPixels hands back the framebuffer bottom row first, so the rows are
 * reversed on the way out: `id` has one pixel layout, the one gfx_present
 * consumes, and a GL frame that came back upside down would silently be a
 * different thing from a software frame.
 *
 * Reads GL_BACK -- the buffer the frame was just drawn into -- so this belongs
 * between the last draw call and gl_end_frame. Reading GL_FRONT after the swap
 * looks more natural and does not work: under a compositor the front buffer is
 * the compositor's to define, and it comes back black. */
int id_gl_read_pixels(IdList* fb) {
    if (!g_dpy || !fb || g_w <= 0 || g_h <= 0) return 0;
    size_t n = (size_t)g_w * (size_t)g_h;
    unsigned char* rgb = (unsigned char*)malloc(n * 3);
    if (!rgb) return 0;
    glReadBuffer(GL_BACK);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, g_w, g_h, GL_RGB, GL_UNSIGNED_BYTE, rgb);
    int wrote = 0;
    for (int y = 0; y < g_h; y++) {
        const unsigned char* row = rgb + (size_t)(g_h - 1 - y) * g_w * 3;
        for (int x = 0; x < g_w; x++) {
            int i = y * g_w + x;
            if (i >= fb->len) { free(rgb); return wrote; }
            fb->data[i] = ((long long)row[x * 3] << 16)
                        | ((long long)row[x * 3 + 1] << 8)
                        |  (long long)row[x * 3 + 2];
            wrote++;
        }
    }
    free(rgb);
    return wrote;
}

/* ---- matrix pool ----------------------------------------------------------
 * A fixed ring of 4x4 column-major float matrices (OpenGL's own layout, so
 * glLoadMatrixf can consume one directly). Handles are just pool indices;
 * nothing is ever freed explicitly -- a demo rebuilds a handful of matrices
 * every frame, so the ring simply wraps and overwrites the oldest slot. */
#define MAT_POOL 1024
static float g_mat[MAT_POOL][16];
static int g_mat_next = 0;

static int mat_alloc(void) {
    int h = g_mat_next;
    g_mat_next = (g_mat_next + 1) % MAT_POOL;
    return h;
}

static void mat_set_identity(float* m) {
    memset(m, 0, sizeof(float) * 16);
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

int id_gl_mat_identity(void) {
    int h = mat_alloc();
    mat_set_identity(g_mat[h]);
    return h;
}

int id_gl_mat_perspective(int fov_deg_x1000, int aspect_x1000, int near_x1000, int far_x1000) {
    double fov = (double)fov_deg_x1000 / 1000.0 * (M_PI / 180.0);
    double aspect = (double)aspect_x1000 / 1000.0;
    double zn = (double)near_x1000 / 1000.0;
    double zf = (double)far_x1000 / 1000.0;
    double f = 1.0 / tan(fov / 2.0);
    int h = mat_alloc();
    float* m = g_mat[h];
    memset(m, 0, sizeof(float) * 16);
    m[0] = (float)(f / aspect);
    m[5] = (float)f;
    m[10] = (float)((zf + zn) / (zn - zf));
    m[11] = -1.0f;
    m[14] = (float)((2.0 * zf * zn) / (zn - zf));
    return h;
}

int id_gl_mat_rotate_x(int deg_x1000) {
    double a = (double)deg_x1000 / 1000.0 * (M_PI / 180.0);
    float c = (float)cos(a), s = (float)sin(a);
    int h = mat_alloc();
    float* m = g_mat[h];
    mat_set_identity(m);
    m[5] = c;  m[6] = s;
    m[9] = -s; m[10] = c;
    return h;
}

int id_gl_mat_rotate_y(int deg_x1000) {
    double a = (double)deg_x1000 / 1000.0 * (M_PI / 180.0);
    float c = (float)cos(a), s = (float)sin(a);
    int h = mat_alloc();
    float* m = g_mat[h];
    mat_set_identity(m);
    m[0] = c;  m[2] = -s;
    m[8] = s;  m[10] = c;
    return h;
}

int id_gl_mat_rotate_z(int deg_x1000) {
    double a = (double)deg_x1000 / 1000.0 * (M_PI / 180.0);
    float c = (float)cos(a), s = (float)sin(a);
    int h = mat_alloc();
    float* m = g_mat[h];
    mat_set_identity(m);
    m[0] = c; m[1] = s;
    m[4] = -s; m[5] = c;
    return h;
}

int id_gl_mat_translate(int x_x1000, int y_x1000, int z_x1000) {
    int h = mat_alloc();
    float* m = g_mat[h];
    mat_set_identity(m);
    m[12] = (float)x_x1000 / 1000.0f;
    m[13] = (float)y_x1000 / 1000.0f;
    m[14] = (float)z_x1000 / 1000.0f;
    return h;
}

int id_gl_mat_mul(int a, int b) {
    int h = mat_alloc();
    /* Guard bad handles from `id` (shouldn't happen, but link-time externs
     * have no type checking) by clamping into the pool. */
    a = ((a % MAT_POOL) + MAT_POOL) % MAT_POOL;
    b = ((b % MAT_POOL) + MAT_POOL) % MAT_POOL;
    const float* A = g_mat[a];
    const float* B = g_mat[b];
    float* R = g_mat[h];
    /* Both operands are column-major OpenGL matrices; column-major product
     * R = A*B: R[col*4+row] = sum_k A[k*4+row] * B[col*4+k]. */
    for (int col = 0; col < 4; col++) {
        for (int row = 0; row < 4; row++) {
            float sum = 0.0f;
            for (int k = 0; k < 4; k++) sum += A[k * 4 + row] * B[col * 4 + k];
            R[col * 4 + row] = sum;
        }
    }
    return h;
}

int id_gl_set_projection(int handle) {
    handle = ((handle % MAT_POOL) + MAT_POOL) % MAT_POOL;
    glMatrixMode(GL_PROJECTION);
    glLoadMatrixf(g_mat[handle]);
    glMatrixMode(GL_MODELVIEW);
    return 0;
}

int id_gl_set_modelview(int handle) {
    handle = ((handle % MAT_POOL) + MAT_POOL) % MAT_POOL;
    glMatrixMode(GL_MODELVIEW);
    glLoadMatrixf(g_mat[handle]);
    return 0;
}

/* ---- geometry -------------------------------------------------------------- */

int id_gl_draw_tris(IdList* verts, IdList* colors, int count) {
    if (!verts || !colors || count <= 0) return 0;
    int nv = count * 3;
    int have_v = verts->len / 3;      /* vertices actually available */
    int have_c = colors->len;         /* one packed color per vertex */
    if (nv > have_v) nv = have_v;
    if (nv > have_c) nv = have_c;

    glBegin(GL_TRIANGLES);
    for (int i = 0; i < nv; i++) {
        long long c = colors->data[i];
        float r = (float)((c / 65536) % 256) / 255.0f;
        float g = (float)((c / 256) % 256) / 255.0f;
        float b = (float)(c % 256) / 255.0f;
        glColor3f(r, g, b);
        float x = (float)verts->data[i * 3 + 0] / 1000.0f;
        float y = (float)verts->data[i * 3 + 1] / 1000.0f;
        float z = (float)verts->data[i * 3 + 2] / 1000.0f;
        glVertex3f(x, y, z);
    }
    glEnd();
    return 0;
}

int id_gl_draw_points(IdList* positions, IdList* colors, int count, int size_x1000) {
    if (!positions || !colors || count <= 0) return 0;
    int have_p = positions->len / 3;  /* 3 ints (x,y,z) per point */
    int have_c = colors->len;         /* 1 packed color per point */
    int n = count;
    if (n > have_p) n = have_p;
    if (n > have_c) n = have_c;
    if (n <= 0) return 0;

    float size = (float)size_x1000 / 1000.0f;
    if (size < 1.0f) size = 1.0f;

    /* Additive-blended, unlit glow: enable blending with a src+dst additive
     * function so overlapping particles accumulate into bright cores, turn
     * off depth writes so a glow sprite never occludes geometry behind it
     * (it still depth-*tests*, so particles behind solid geometry are
     * correctly hidden), and round the point sprite where the driver
     * supports it. All of this is restored before returning so this call
     * composes cleanly with gl_draw_tris either before or after it in the
     * same frame. */
    GLboolean was_blend = glIsEnabled(GL_BLEND);
    GLboolean was_point_smooth = glIsEnabled(GL_POINT_SMOOTH);
    GLboolean depth_mask_was;
    glGetBooleanv(GL_DEPTH_WRITEMASK, &depth_mask_was);

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE);
    glEnable(GL_POINT_SMOOTH);
    glHint(GL_POINT_SMOOTH_HINT, GL_NICEST);
    glDepthMask(GL_FALSE);
    glPointSize(size);

    glBegin(GL_POINTS);
    for (int i = 0; i < n; i++) {
        long long c = colors->data[i];
        float r = (float)((c / 65536) % 256) / 255.0f;
        float g = (float)((c / 256) % 256) / 255.0f;
        float b = (float)(c % 256) / 255.0f;
        glColor4f(r, g, b, 1.0f);
        float x = (float)positions->data[i * 3 + 0] / 1000.0f;
        float y = (float)positions->data[i * 3 + 1] / 1000.0f;
        float z = (float)positions->data[i * 3 + 2] / 1000.0f;
        glVertex3f(x, y, z);
    }
    glEnd();

    glDepthMask(depth_mask_was ? GL_TRUE : GL_FALSE);
    if (!was_point_smooth) glDisable(GL_POINT_SMOOTH);
    if (!was_blend) glDisable(GL_BLEND);
    return 0;
}
