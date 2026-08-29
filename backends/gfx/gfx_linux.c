/* gfx_linux.c -- Linux/X11 backend for the `id` graphics ABI (see gfx.h).
 *
 * The Linux counterpart to gfx_macos.m, behind the identical header: an Xlib
 * window with a software framebuffer blitted by XPutImage. Zero third-party
 * dependencies -- only libX11, which ships with every X server. Like the macOS
 * backend it never blocks: id_gfx_poll drains the X event queue with XPending,
 * so `id` keeps driving its own frame loop.
 *
 * Status: validated on Linux (X11/XWayland) -- builds and runs demos/gfxdemo
 * headlessly via the GFX_MAX_FRAMES self-terminate hook (see below). It is the
 * concrete proof that the seam is platform-agnostic. A Wayland backend would
 * slot in the same way -- another object behind the same gfx.h.
 *
 * Headless/CI testing: if the environment variable GFX_MAX_FRAMES is set to a
 * positive integer N, id_gfx_present counts calls and, once N presents have
 * happened, makes the *next* id_gfx_poll() report quit (-2). This lets a build
 * run a bounded number of frames and exit 0 with no human closing the window.
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gfx.h"

static Display* g_dpy = NULL;
static Window   g_win = 0;
static GC       g_gc  = 0;
static XImage*  g_img = NULL;
static uint32_t* g_px = NULL;          /* 0x00RRGGBB words, 32bpp            */
static Atom     g_wm_delete = 0;
static int      g_w = 0, g_h = 0;
static int      g_quit = 0;
static int      g_mx = 0, g_my = 0;    /* pointer position, surface pixels   */
static int      g_btn = 0;             /* button bitmask, bit 0 = left       */

/* Map an X keysym that produced no character to the shared special-key range
 * (see gfx.h). XLookupString gives bytes, and an arrow key is not a byte --
 * which is why arrows, F-keys and bare modifiers were invisible to `id` until
 * now. Returns -1 for a keysym with no code of its own. */
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

/* The code an event carries, press or release: the character if the key makes
 * one, else its special code. */
static int event_code(XKeyEvent* ke) {
    char buf[8];
    KeySym ks = 0;
    int n = XLookupString(ke, buf, sizeof(buf), &ks, NULL);
    if (n > 0) return (unsigned char)buf[0];
    return special_code(ks);
}

/* GFX_MAX_FRAMES headless self-terminate hook (see file header). -1 = unset
 * (never auto-quit), otherwise the number of id_gfx_present calls to allow
 * before synthesizing a quit signal on the next id_gfx_poll. */
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

/* tiny key ring, same contract as the macOS backend */
#define GFX_KEYQ 256
static int g_keyq[GFX_KEYQ];
static int g_keyhead = 0, g_keytail = 0;
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

/* Reallocate the surface to the window's new size. XDestroyImage frees the
 * pixel buffer it was created over, so the two are always replaced together. */
static void resize_surface(int w, int h) {
    if (w <= 0 || h <= 0 || (w == g_w && h == g_h)) return;
    uint32_t* px = (uint32_t*)calloc((size_t)w * h, sizeof(uint32_t));
    if (!px) return;                    /* keep the old surface rather than none */
    if (g_img) XDestroyImage(g_img);    /* frees the old g_px */
    g_px = px;
    g_img = XCreateImage(g_dpy, DefaultVisual(g_dpy, DefaultScreen(g_dpy)),
                         DefaultDepth(g_dpy, DefaultScreen(g_dpy)), ZPixmap, 0,
                         (char*)g_px, w, h, 32, 0);
    g_w = w; g_h = h;
}

/* X sends a KeyRelease immediately followed by a KeyPress of the same key, at
 * the same timestamp, when a key is auto-repeating. Reporting those releases
 * would make a held key look like a rapid tap, which is exactly the question
 * "is this key down" needs answered correctly. */
static int is_autorepeat(XEvent* rel) {
    XEvent nxt;
    if (!XPending(g_dpy)) return 0;
    XPeekEvent(g_dpy, &nxt);
    return nxt.type == KeyPress
        && nxt.xkey.time == rel->xkey.time
        && nxt.xkey.keycode == rel->xkey.keycode;
}

/* drain everything X has queued without blocking */
static void pump(void) {
    if (!g_dpy) return;
    while (XPending(g_dpy)) {
        XEvent ev;
        int code;
        XNextEvent(g_dpy, &ev);
        switch (ev.type) {
        case ClientMessage:
            if ((Atom)ev.xclient.data.l[0] == g_wm_delete) g_quit = 1;
            break;
        case KeyPress:
            code = event_code(&ev.xkey);
            if (code >= 0) key_push(code);
            break;
        case KeyRelease:
            if (is_autorepeat(&ev)) break;
            code = event_code(&ev.xkey);
            if (code >= 0) key_push(code + GFX_RELEASED);
            break;
        case ButtonPress:
            if (ev.xbutton.button >= 1 && ev.xbutton.button <= 5)
                g_btn |= 1 << (ev.xbutton.button - 1);
            g_mx = ev.xbutton.x; g_my = ev.xbutton.y;
            break;
        case ButtonRelease:
            /* Buttons 4 and 5 are the wheel, and X delivers a notch as a press
             * immediately followed by a release. Clearing them here made a notch
             * invisible: pump() drains the whole queue in one call, so both
             * events are consumed before `id` reads the mask, and the bit was
             * always back to 0 by the time anyone looked. They are cleared when
             * the mask is *read* instead -- see id_gfx_mouse_buttons -- which is
             * what makes "set for one frame", as the README has always
             * described it, actually true. */
            if (ev.xbutton.button >= 1 && ev.xbutton.button <= 3)
                g_btn &= ~(1 << (ev.xbutton.button - 1));
            g_mx = ev.xbutton.x; g_my = ev.xbutton.y;
            break;
        case MotionNotify:
            g_mx = ev.xmotion.x; g_my = ev.xmotion.y;
            break;
        case ConfigureNotify:
            resize_surface(ev.xconfigure.width, ev.xconfigure.height);
            break;
        default:
            break;
        }
    }
}

int id_gfx_open(int w, int h, const char* title) {
    if (g_dpy) return 1;
    if (w <= 0 || h <= 0) return 0;
    g_dpy = XOpenDisplay(NULL);
    if (!g_dpy) return 0;

    int screen = DefaultScreen(g_dpy);
    g_win = XCreateSimpleWindow(g_dpy, RootWindow(g_dpy, screen), 0, 0, w, h, 0,
                                BlackPixel(g_dpy, screen),
                                BlackPixel(g_dpy, screen));
    XStoreName(g_dpy, g_win, title ? title : "id");
    /* WM_CLASS, so a window manager can recognise an `id` program. Without it
       the class is empty and every rule has to match on the title, which is
       whatever the program passed to gfx_open. See tools/headless.sh. */
    {
        XClassHint ch;
        ch.res_name = (char*)"id";
        ch.res_class = (char*)"id-gfx";
        XSetClassHint(g_dpy, g_win, &ch);
    }
    XSelectInput(g_dpy, g_win,
                 ExposureMask | KeyPressMask | KeyReleaseMask |
                 ButtonPressMask | ButtonReleaseMask | PointerMotionMask |
                 StructureNotifyMask);
    g_wm_delete = XInternAtom(g_dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(g_dpy, g_win, &g_wm_delete, 1);

    g_gc = XCreateGC(g_dpy, g_win, 0, NULL);
    g_px = (uint32_t*)calloc((size_t)w * h, sizeof(uint32_t));
    if (!g_px) return 0;
    /* 32bpp TrueColor image over our buffer; on the common little-endian
     * 24/32-bit visual a 0x00RRGGBB word renders as that color directly. */
    g_img = XCreateImage(g_dpy, DefaultVisual(g_dpy, screen),
                         DefaultDepth(g_dpy, screen), ZPixmap, 0,
                         (char*)g_px, w, h, 32, 0);
    if (!g_img) return 0;

    XMapWindow(g_dpy, g_win);
    XFlush(g_dpy);
    g_w = w; g_h = h; g_quit = 0;
    g_keyhead = g_keytail = 0;
    g_frame_count = 0;
    g_mx = g_my = 0; g_btn = 0;
    return 1;
}

/* The surface's current size. A tiling window manager resizes on map, so these
 * can differ from what gfx_open asked for before the first frame is drawn --
 * which is why `id` must ask rather than assume. */
int id_gfx_width(void)  { return g_w; }
int id_gfx_height(void) { return g_h; }

/* Pointer state rather than pointer events: a click is an edge, and `id` can
 * see an edge by comparing this frame's buttons with last frame's. That keeps
 * the seam at four small functions instead of an event encoding. */
int id_gfx_mouse_x(void) { return g_mx; }
int id_gfx_mouse_y(void) { return g_my; }
/* The wheel bits are latched rather than held: a notch sets one and this clears
 * it, so exactly one read sees it however long ago in the frame it happened. The
 * three real buttons are state and are not touched. Two notches inside one frame
 * collapse into one, which is the cost of a bitmask rather than a counter and is
 * invisible at any plausible frame rate. */
int id_gfx_mouse_buttons(void) {
    int b = g_btn;
    g_btn &= ~((1 << 3) | (1 << 4));   /* bits 3-4: wheel up, wheel down */
    return b;
}

int id_gfx_present(IdList* fb) {
    if (!g_dpy || !g_px) return 0;
    int n = g_w * g_h;
    int have = (fb ? fb->len : 0);
    for (int i = 0; i < n; i++)
        g_px[i] = (i < have) ? (uint32_t)(fb->data[i] & 0xFFFFFF) : 0u;
    XPutImage(g_dpy, g_win, g_gc, g_img, 0, 0, 0, 0, g_w, g_h);
    XFlush(g_dpy);
    pump();
    g_frame_count++;
    int max = max_frames();
    if (max >= 0 && g_frame_count >= max) {
        fprintf(stderr, "gfx_linux: GFX_MAX_FRAMES=%d reached, presented %d frame(s), "
                        "synthesizing quit\n", max, g_frame_count);
        g_quit = 1;
    }
    return 0;
}

int id_gfx_poll(void) {
    if (!g_dpy) return -1;
    pump();
    if (g_quit) return -2;
    return key_pop();
}

int id_gfx_close(void) {
    if (!g_dpy) return 0;
    if (g_img) { XDestroyImage(g_img); g_img = NULL; g_px = NULL; } /* frees g_px */
    if (g_gc)  { XFreeGC(g_dpy, g_gc); g_gc = 0; }
    if (g_win) { XDestroyWindow(g_dpy, g_win); g_win = 0; }
    XCloseDisplay(g_dpy);
    g_dpy = NULL; g_w = g_h = 0;
    return 0;
}
