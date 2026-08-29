/* gfx_macos.m -- macOS backend for the `id` graphics ABI (see gfx.h).
 *
 * Zero third-party dependencies: just Cocoa + QuartzCore from the system SDK,
 * compiled by the same clang that builds the rest of `id`. A software
 * framebuffer is presented through a layer-backed NSView as a CGImage.
 *
 * The hard part on macOS is that `id` drives its own frame loop (draw ->
 * present -> poll -> sleep) and must NOT hand control to [NSApp run]. So we
 * finishLaunching the app once, then on every present/poll we *pump* the event
 * queue non-blockingly with nextEventMatchingMask:untilDate:distantPast. This
 * is the standard "embed Cocoa in a custom loop" pattern.
 *
 * Built with -fobjc-arc, so no manual retain/release.
 *
 * NOT VERIFIED HERE. The development machine for the current work is Linux, so
 * gfx_linux.c is the backend every claim in the docs was measured against.
 * What follows implements the same gfx.h contract -- extended key codes, key
 * release, pointer state, and the surface-size queries -- but none of it has
 * been compiled or run on macOS. Treat it as a faithful translation awaiting a
 * machine, not as a tested backend.
 */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <string.h>
#include "gfx.h"

/* ---- pixel surface --------------------------------------------------------
 * We keep one uint32 buffer in 0xAARRGGBB layout. Paired with
 * (kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little) this is the
 * canonical "ARGB word" software-framebuffer format on little-endian macOS:
 * each 32-bit word displays as the color you wrote, no byte juggling. */

/* The view that owns the pixels and draws them. Flipped so row 0 is the top. */
@interface GfxView : NSView {
@public
    uint32_t* pixels;
    int pxw, pxh;
}
@end

@implementation GfxView
- (BOOL)isFlipped { return YES; }      /* top-left origin: matches our buffer */
- (BOOL)acceptsFirstResponder { return YES; }  /* so keyDown reaches us       */
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (!pixels || pxw <= 0 || pxh <= 0) return;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bmp = CGBitmapContextCreate(
        pixels, pxw, pxh, 8, (size_t)pxw * 4, cs,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = bmp ? CGBitmapContextCreateImage(bmp) : NULL;
    if (img) {
        /* nearest-neighbour scale to the view (crisp pixels if resized) */
        CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
        CGContextDrawImage(ctx, self.bounds, img);
        CGImageRelease(img);
    }
    if (bmp) CGContextRelease(bmp);
    CGColorSpaceRelease(cs);
}
@end

/* The window's delegate: turns a close request into the -2 quit signal. */
@interface GfxDelegate : NSObject <NSWindowDelegate>
@end
static int g_quit = 0;
@implementation GfxDelegate
- (BOOL)windowShouldClose:(NSWindow*)sender { (void)sender; g_quit = 1; return NO; }
@end

/* ---- backend state -------------------------------------------------------- */
static NSWindow*   g_window = nil;
static GfxView*    g_view   = nil;
static GfxDelegate* g_delegate = nil;
static int g_w = 0, g_h = 0;
static int g_mx = 0, g_my = 0;   /* pointer position, view pixels */
static int g_btn = 0;            /* button bitmask, bit 0 = left   */

/* tiny key ring drained by id_gfx_poll */
#define GFX_KEYQ 256
static int g_keyq[GFX_KEYQ];
static int g_keyhead = 0, g_keytail = 0;
static void key_push(int code) {
    int n = (g_keytail + 1) % GFX_KEYQ;
    if (n == g_keyhead) return;          /* full: drop oldest-safe (skip)   */
    g_keyq[g_keytail] = code;
    g_keytail = n;
}
static int key_pop(void) {
    if (g_keyhead == g_keytail) return -1;
    int code = g_keyq[g_keyhead];
    g_keyhead = (g_keyhead + 1) % GFX_KEYQ;
    return code;
}

/* Non-blocking event pump. Capture key codes; let everything else flow to the
 * app so the window stays live. keyDown is consumed here (not forwarded) to
 * avoid the system beep on keys no responder handles. */
/* Cocoa's function-key unicodes -> the shared special-key range in gfx.h. */
static int special_code(unichar c) {
    switch (c) {
    case NSLeftArrowFunctionKey:  return GFX_KEY_LEFT;
    case NSRightArrowFunctionKey: return GFX_KEY_RIGHT;
    case NSUpArrowFunctionKey:    return GFX_KEY_UP;
    case NSDownArrowFunctionKey:  return GFX_KEY_DOWN;
    case NSHomeFunctionKey:       return GFX_KEY_HOME;
    case NSEndFunctionKey:        return GFX_KEY_END;
    case NSPageUpFunctionKey:     return GFX_KEY_PGUP;
    case NSPageDownFunctionKey:   return GFX_KEY_PGDN;
    case NSInsertFunctionKey:     return GFX_KEY_INSERT;
    case NSDeleteFunctionKey:     return GFX_KEY_DELETE;
    default: break;
    }
    if (c >= NSF1FunctionKey && c <= NSF12FunctionKey)
        return GFX_KEY_F1 + (int)(c - NSF1FunctionKey);
    return -1;
}

/* The code an event carries: the character if it makes one, else its special
 * code. Cocoa reports arrows and F-keys as private-use unicodes above 0xF700,
 * which are not characters `id` should ever see as bytes. */
static int event_code(NSEvent* ev) {
    NSString* s = ev.charactersIgnoringModifiers;
    if (s.length == 0) return -1;
    unichar c = [s characterAtIndex:0];
    if (c >= 0xF700) return special_code(c);
    return (int)c;
}

/* Non-blocking event pump. Capture key codes and pointer state; let everything
 * else flow to the app so the window stays live. keyDown is consumed here (not
 * forwarded) to avoid the system beep on keys no responder handles. */
static void pump(void) {
    NSApplication* app = [NSApplication sharedApplication];
    for (;;) {
        NSEvent* ev = [app nextEventMatchingMask:NSEventMaskAny
                                       untilDate:[NSDate distantPast]
                                          inMode:NSDefaultRunLoopMode
                                         dequeue:YES];
        if (!ev) break;
        if (ev.type == NSEventTypeKeyDown) {
            if (!ev.isARepeat) {          /* a repeat is not a new press */
                int code = event_code(ev);
                if (code >= 0) key_push(code);
            }
            continue;
        }
        if (ev.type == NSEventTypeKeyUp) {
            int code = event_code(ev);
            if (code >= 0) key_push(code + GFX_RELEASED);
            continue;
        }
        if (ev.type == NSEventTypeFlagsChanged) {
            /* Cocoa reports bare modifiers as a state change, not a key. */
            NSEventModifierFlags f = ev.modifierFlags;
            static NSEventModifierFlags prev = 0;
            NSEventModifierFlags ch = f ^ prev;
            if (ch & NSEventModifierFlagShift)
                key_push(GFX_KEY_SHIFT + ((f & NSEventModifierFlagShift) ? 0 : GFX_RELEASED));
            if (ch & NSEventModifierFlagControl)
                key_push(GFX_KEY_CTRL + ((f & NSEventModifierFlagControl) ? 0 : GFX_RELEASED));
            if (ch & NSEventModifierFlagOption)
                key_push(GFX_KEY_ALT + ((f & NSEventModifierFlagOption) ? 0 : GFX_RELEASED));
            prev = f;
        }
        if (ev.type == NSEventTypeMouseMoved || ev.type == NSEventTypeLeftMouseDragged ||
            ev.type == NSEventTypeRightMouseDragged || ev.type == NSEventTypeOtherMouseDragged ||
            ev.type == NSEventTypeLeftMouseDown || ev.type == NSEventTypeLeftMouseUp ||
            ev.type == NSEventTypeRightMouseDown || ev.type == NSEventTypeRightMouseUp ||
            ev.type == NSEventTypeOtherMouseDown || ev.type == NSEventTypeOtherMouseUp ||
            ev.type == NSEventTypeScrollWheel) {
            NSPoint p = [g_view convertPoint:ev.locationInWindow fromView:nil];
            g_mx = (int)p.x; g_my = (int)p.y;   /* the view is flipped: row 0 is the top */
            if (ev.type == NSEventTypeLeftMouseDown)  g_btn |=  1;
            if (ev.type == NSEventTypeLeftMouseUp)    g_btn &= ~1;
            if (ev.type == NSEventTypeRightMouseDown) g_btn |=  4;
            if (ev.type == NSEventTypeRightMouseUp)   g_btn &= ~4;
            /* Middle is "other": AppKit numbers it 2 and reports it separately
             * from left and right. Anything past three buttons is ignored, which
             * matches the mask's three real buttons. */
            if (ev.type == NSEventTypeOtherMouseDown && ev.buttonNumber == 2) g_btn |=  2;
            if (ev.type == NSEventTypeOtherMouseUp   && ev.buttonNumber == 2) g_btn &= ~2;
            /* The wheel is a latch, not a state: a scroll has no duration to
             * report, so a notch sets its bit and reading the mask clears it
             * (id_gfx_mouse_buttons). scrollingDeltaY is positive scrolling up.
             * A zero delta is a trackpad's momentum settling and sets nothing. */
            if (ev.type == NSEventTypeScrollWheel) {
                if (ev.scrollingDeltaY > 0) g_btn |= (1 << 3);
                if (ev.scrollingDeltaY < 0) g_btn |= (1 << 4);
            }
        }
        [app sendEvent:ev];
    }
}

int id_gfx_open(int w, int h, const char* title) {
    if (g_window) return 1;              /* already open                     */
    if (w <= 0 || h <= 0) return 0;
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSRect frame = NSMakeRect(0, 0, w, h);
        NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable;
        g_window = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:style
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
        g_delegate = [GfxDelegate new];
        g_window.delegate = g_delegate;
        g_window.releasedWhenClosed = NO;
        [g_window setTitle:[NSString stringWithUTF8String:(title ? title : "id")]];

        g_view = [[GfxView alloc] initWithFrame:frame];
        g_view->pxw = w; g_view->pxh = h;
        g_view->pixels = (uint32_t*)calloc((size_t)w * h, sizeof(uint32_t));
        g_window.contentView = g_view;

        [g_window center];
        [g_window makeKeyAndOrderFront:nil];
        [g_window makeFirstResponder:g_view];
        [app activateIgnoringOtherApps:YES];
        [app finishLaunching];           /* ready to pump, without -run      */

        g_w = w; g_h = h; g_quit = 0;
        g_keyhead = g_keytail = 0;
    }
    return g_view->pixels ? 1 : 0;
}

int id_gfx_present(IdList* fb) {
    if (!g_window || !g_view || !g_view->pixels) return 0;
    @autoreleasepool {
        int n = g_w * g_h;
        int have = (fb ? fb->len : 0);
        uint32_t* dst = g_view->pixels;
        for (int i = 0; i < n; i++) {
            uint32_t rgb = (i < have) ? (uint32_t)(fb->data[i] & 0xFFFFFF) : 0u;
            dst[i] = 0xFF000000u | rgb;   /* opaque ARGB word                 */
        }
        [g_view setNeedsDisplay:YES];
        [g_view displayIfNeeded];         /* draw now, inside our loop        */
        pump();
    }
    return 0;
}

/* The surface's current size. macOS does not resize the surface behind `id`'s
 * back -- the window is created at gfx_open's size -- so these report what was
 * asked for. They exist so that `id` can ask the same question of either
 * platform. */
int id_gfx_width(void)  { return g_w; }
int id_gfx_height(void) { return g_h; }

int id_gfx_mouse_x(void) { return g_mx; }
int id_gfx_mouse_y(void) { return g_my; }
/* The wheel bits are latched rather than held: a notch sets one and this clears
 * it, so exactly one read sees it. The three real buttons are state and are not
 * touched. This mirrors gfx_linux.c, where the same latch exists because X
 * delivers a notch as a press and a release together. */
int id_gfx_mouse_buttons(void) {
    int b = g_btn;
    g_btn &= ~((1 << 3) | (1 << 4));
    return b;
}

int id_gfx_poll(void) {
    if (!g_window) return -1;
    pump();
    if (g_quit) return -2;
    return key_pop();
}

int id_gfx_close(void) {
    if (!g_window) return 0;
    @autoreleasepool {
        if (g_view && g_view->pixels) { free(g_view->pixels); g_view->pixels = NULL; }
        [g_window close];
        g_window = nil; g_view = nil; g_delegate = nil;
        g_w = g_h = 0;
    }
    return 0;
}
