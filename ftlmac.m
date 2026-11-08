// ftlmac.m
//
// Makes the iPad game behave like a Mac game:
//  - Window: opens at 80% of the screen with the screen's shape (the game
//    fixes its canvas to the window's shape at startup), keeps that shape
//    while resizing, and letterboxes in full screen. The titlebar no longer
//    covers the top of the game.
//  - Keyboard: keys go to the game as its own key events; the desktop
//    game's hotkeys work (hooks.c answers the hotkey lookup).
//  - Mouse: the left button stays the finger Mac Catalyst makes of it. The
//    right button is Back (Escape), or a right click for Hyperspace mods that
//    listen for one; the wheel and trackpad pinch zoom the view, the middle
//    button and two-finger scrolling pan it.
//
// AppKit is only reached through the Objective-C runtime: Catalyst code
// can't include its headers, but the classes are loaded in every Catalyst app.
//
// Environment variables:
//   FTLMAC_TEST=<fifo>   read test commands from a FIFO (see test_command)

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>
#include <pthread.h>

#include "hooks.h"
#include "hyperspace.h"
#include "hyperspace_host.h"

// ---------------------------------------------------------------------------------
// AppKit through the runtime

#define MSG(ret, ...) ((ret (*)(id, SEL, ##__VA_ARGS__))objc_msgSend)
static id nsapp(void) { return MSG(id)((id)NSClassFromString(@"NSApplication"), @selector(sharedApplication)); }

// NSEvent types and masks
enum {
    EV_LEFT_DOWN = 1, EV_LEFT_UP = 2, EV_RIGHT_DOWN = 3, EV_RIGHT_UP = 4, EV_MOVED = 5,
    EV_LEFT_DRAGGED = 6, EV_RIGHT_DRAGGED = 7, EV_KEY_DOWN = 10, EV_KEY_UP = 11, EV_FLAGS = 12,
    EV_SCROLL = 22, EV_OTHER_DOWN = 25, EV_OTHER_UP = 26, EV_OTHER_DRAGGED = 27, EV_MAGNIFY = 30,
};
#define EV_MASK(t) (1ull << (t))
// NSEventModifierFlags
enum { MOD_CAPS = 1 << 16, MOD_SHIFT = 1 << 17, MOD_CTRL = 1 << 18, MOD_ALT = 1 << 19, MOD_CMD = 1 << 20 };
// device-dependent bits: left / right modifier keys
enum { DEV_LCTRL = 0x1, DEV_LSHIFT = 0x2, DEV_RSHIFT = 0x4, DEV_LCMD = 0x8, DEV_RCMD = 0x10,
       DEV_LALT = 0x20, DEV_RALT = 0x40, DEV_RCTRL = 0x2000 };
enum { STYLE_FULL_SIZE_CONTENT = 1 << 15, STYLE_FULLSCREEN = 1 << 14 };

static NSUInteger ev_type(id e) { return MSG(NSUInteger)(e, @selector(type)); }
static NSUInteger ev_flags(id e) { return MSG(NSUInteger)(e, @selector(modifierFlags)); }
static unsigned short ev_keycode(id e) { return MSG(unsigned short)(e, @selector(keyCode)); }
static CGPoint ev_location(id e) { return MSG(CGPoint)(e, @selector(locationInWindow)); }
static id ev_window(id e) { return MSG(id)(e, @selector(window)); }

static CGRect ns_frame(id view_or_window) { return MSG(CGRect)(view_or_window, @selector(frame)); }
static id ns_content_view(id w) { return MSG(id)(w, @selector(contentView)); }

// ---------------------------------------------------------------------------------
// the game's view, letterboxed and zoomable

// The container holds a clip view in the letterboxed rectangle, which holds
// the game's view. Zooming scales and moves the game's view inside the clip
// view; UIKit undoes that transform for touches.
@interface FTLMacHost : UIView
@property(nonatomic, strong) UIView *clip, *game;
@property(nonatomic) CGFloat aspect;  // the game's canvas, width / height
@property(nonatomic) CGFloat zoom, x0, y0;  // zoom >= 1, the shown part's top left (view points)
@end

@interface FTLMacHostController : UIViewController
@end
@implementation FTLMacHostController
- (BOOL)prefersStatusBarHidden { return YES; }
@end

static void install_event_monitor(void);

static FTLMacHost *g_host;
static UIWindow *g_window;
static id g_nswindow;  // its UINSWindow
static CGSize g_canvas;  // the game's view size at startup (UIKit points)

static const CGFloat ZOOM_MAX = 3.0;

@implementation FTLMacHost
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    if (area.size.width <= 0 || area.size.height <= 0 || self.aspect <= 0) return;
    CGFloat w = area.size.width, h = round(w / self.aspect);
    if (h > area.size.height) {
        h = area.size.height;
        w = round(h * self.aspect);
    }
    CGRect r = CGRectMake(area.origin.x + floor((area.size.width - w) / 2), area.origin.y + floor((area.size.height - h) / 2), w, h);
    if (!CGRectEqualToRect(self.clip.frame, r)) {
        // Keep the same part of the game in view when the size changes.
        CGFloat k = self.clip.bounds.size.width > 0 ? w / self.clip.bounds.size.width : 1;
        self.x0 *= k;
        self.y0 *= k;
        self.clip.frame = r;
    }
    [self applyView];
}
- (void)applyView {
    CGSize s = self.clip.bounds.size;
    CGFloat z = self.zoom < 1 ? 1 : self.zoom;
    self.x0 = fmax(0, fmin(self.x0, s.width - s.width / z));
    self.y0 = fmax(0, fmin(self.y0, s.height - s.height / z));
    self.game.transform = CGAffineTransformIdentity;
    self.game.frame = CGRectMake(0, 0, s.width, s.height);
    // screen = c + z * (p - c) + t, and x0 must land on the left edge
    CGFloat tx = -s.width / 2 - z * (self.x0 - s.width / 2), ty = -s.height / 2 - z * (self.y0 - s.height / 2);
    self.game.transform = CGAffineTransformMake(z, 0, 0, z, tx, ty);
}
// Zoom by `factor`, keeping the game point under `p` (clip view points) in place.
- (void)zoomBy:(CGFloat)factor at:(CGPoint)p {
    CGFloat z = self.zoom < 1 ? 1 : self.zoom, nz = fmin(ZOOM_MAX, fmax(1, z * factor));
    if (nz < 1.03) nz = 1;
    CGFloat gx = self.x0 + p.x / z, gy = self.y0 + p.y / z;
    self.zoom = nz;
    self.x0 = gx - p.x / nz;
    self.y0 = gy - p.y / nz;
    [self applyView];
}
// Move the shown part with the pointer / fingers by (dx, dy) clip view points.
- (void)panBy:(CGPoint)d {
    if (self.zoom <= 1) return;
    self.x0 -= d.x / self.zoom;
    self.y0 -= d.y / self.zoom;
    [self applyView];
}
@end

// UIKit points per Mac point (Catalyst's iPad idiom draws at 77%).
static CGFloat ui_per_ns(void) {
    CGFloat ns = g_nswindow ? ns_frame(ns_content_view(g_nswindow)).size.width : 0;
    return ns > 0 ? g_window.bounds.size.width / ns : 1 / 0.77;
}

// NSWindow content point (origin bottom left) -> UIWindow point
static CGPoint ns_to_ui(CGPoint p) {
    CGRect c = ns_frame(ns_content_view(g_nswindow));
    CGFloat k = ui_per_ns();
    return CGPointMake(p.x * k, (c.size.height - p.y) * k);
}
static CGPoint ui_to_ns(CGPoint p) {
    CGRect c = ns_frame(ns_content_view(g_nswindow));
    CGFloat k = ui_per_ns();
    return CGPointMake(p.x / k, c.size.height - p.y / k);
}

// The event's position in the clip view.
static CGPoint clip_point(id e) {
    CGPoint p = ev_location(e);
    if (ev_window(e) != g_nswindow) {  // screen coordinates
        CGRect f = ns_frame(g_nswindow);
        p = CGPointMake(p.x - f.origin.x, p.y - f.origin.y);
    }
    return [g_window convertPoint:ns_to_ui(p) toView:g_host.clip];
}

// ---------------------------------------------------------------------------------
// the window

// The window's size before the game reads it: the screen's shape, 80% of its
// width or height, whichever fits, plus the titlebar.
static CGSize initial_size(UIScreen *screen) {
    CGSize s = screen.bounds.size;  // Mac points
    CGFloat titlebar = 28, w = s.width * 0.8, h = w * s.height / s.width;
    if (h + titlebar > s.height * 0.8) {
        h = s.height * 0.8 - titlebar;
        w = h * s.width / s.height;
    }
    CGFloat k = 1 / 0.77;  // Catalyst's scale; the window doesn't exist yet to ask
    return CGSizeMake(round(w * k), round((h + titlebar) * k));
}

static void scene_will_connect(NSNotification *n) {
    if (![n.object isKindOfClass:[UIWindowScene class]]) return;
    UIWindowScene *scene = n.object;
    if (![scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) return;
    CGSize s = initial_size(scene.screen);
    scene.sizeRestrictions.minimumSize = s;
    scene.sizeRestrictions.maximumSize = s;
}

// Once the Mac window exists: free its size again, keeping the game's shape,
// center it and move the content out from under the titlebar.
static void setup_nswindow(id nw) {
    if (g_nswindow || !g_host || ![NSStringFromClass([nw class]) isEqualToString:@"UINSWindow"]) return;
    g_nswindow = nw;
    UIWindowScene *scene = g_window.windowScene;
    scene.sizeRestrictions.minimumSize = CGSizeMake(g_canvas.width * 0.3, g_canvas.height * 0.3);
    scene.sizeRestrictions.maximumSize = CGSizeMake(100000, 100000);
    // Catalyst windows draw their content under the titlebar, which would
    // cover the top of the game.
    NSUInteger style = MSG(NSUInteger)(nw, @selector(styleMask));
    if (style & STYLE_FULL_SIZE_CONTENT) {
        CGRect f = ns_frame(nw);
        MSG(void, NSUInteger)(nw, @selector(setStyleMask:), style & ~(NSUInteger)STYLE_FULL_SIZE_CONTENT);
        MSG(void, CGRect, BOOL)(nw, @selector(setFrame:display:), f, YES);
    }
    MSG(void, CGSize)(nw, NSSelectorFromString(@"setContentAspectRatio:"), g_canvas);
    // Center it. UIKit places the scene's window itself, so ask the scene.
    if (@available(iOS 16.0, *)) {
        CGRect f = ns_frame(nw), screen = UIScreen.mainScreen.bounds;  // Mac points
        CGRect want = CGRectMake(round((screen.size.width - f.size.width) / 2), round((screen.size.height - f.size.height) / 2),
                                 f.size.width, f.size.height);
        [scene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesMac alloc] initWithSystemFrame:want]
                                       errorHandler:^(NSError *e) { NSLog(@"[ftlmac] can't move the window: %@", e); }];
    }
    NSLog(@"[ftlmac] game canvas %.0fx%.0f, window %@, content %@", g_canvas.width, g_canvas.height,
          NSStringFromCGRect(ns_frame(nw)), NSStringFromCGRect(ns_frame(ns_content_view(nw))));
}

// Catalyst makes the Mac window a little after the UIWindow shows.
static void find_nswindow(void) {
    for (id nw in MSG(id)(nsapp(), @selector(windows))) setup_nswindow(nw);
    if (!g_nswindow)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ find_nswindow(); });
}

// Puts the game's view into a host view that letterboxes and zooms it.
static void install_host(UIWindow *w) {
    UIViewController *game_vc = w.rootViewController;
    UIView *game = game_vc.view;
    if (!game || g_host) return;
    g_window = w;
    // The game made its drawable when it started, the size of the screen:
    // that's the shape it draws in, whatever the window's shape.
    g_canvas = w.screen.bounds.size;

    FTLMacHostController *vc = [FTLMacHostController new];
    FTLMacHost *host = [[FTLMacHost alloc] initWithFrame:w.bounds];
    host.backgroundColor = UIColor.blackColor;
    host.aspect = g_canvas.width / g_canvas.height;
    host.zoom = 1;
    host.clip = [[UIView alloc] initWithFrame:w.bounds];
    host.clip.clipsToBounds = YES;
    host.clip.backgroundColor = UIColor.blackColor;
    [host addSubview:host.clip];
    vc.view = host;
    w.rootViewController = vc;
    [vc addChildViewController:game_vc];
    host.game = game;
    [host.clip addSubview:game];
    [game_vc didMoveToParentViewController:vc];
    g_host = host;
    install_event_monitor();
    find_nswindow();
}

// ---------------------------------------------------------------------------------
// keyboard

static bool g_text_editing;     // a text field has the keyboard (naming the ship)
static int g_key_down[128];     // the SIL code sent for each Mac key code that's down

static int sil_for_char(unichar c) {
    if (c >= 'a' && c <= 'z') return SIL_A + (c - 'a');
    if (c >= 'A' && c <= 'Z') return SIL_A + (c - 'A');
    if (c >= '0' && c <= '9') return SIL_0 + (c - '0');
    switch (c) {
    case ' ': return SIL_SPACE;
    case '\'': return SIL_QUOTE;
    case ',': return SIL_COMMA;
    case '-': return SIL_MINUS;
    case '.': return SIL_PERIOD;
    case '/': return SIL_SLASH;
    case ';': return SIL_SEMICOLON;
    case '=': return SIL_EQUALS;
    case '[': return SIL_LBRACKET;
    case '\\': return SIL_BACKSLASH;
    case ']': return SIL_RBRACKET;
    case '`': return SIL_GRAVE;
    default: return 0;
    }
}

// Keys that don't type a character, by Mac virtual key code (kVK_*).
static int sil_for_keycode(unsigned short k) {
    switch (k) {
    case 36: return SIL_ENTER;
    case 48: return SIL_TAB;
    case 49: return SIL_SPACE;
    case 51: return SIL_BACKSPACE;
    case 53: return SIL_ESCAPE;
    case 117: return SIL_FORWARD_DEL;
    case 115: return SIL_HOME;
    case 119: return SIL_END;
    case 116: return SIL_PAGE_UP;
    case 121: return SIL_PAGE_DOWN;
    case 123: return SIL_LEFT;
    case 124: return SIL_RIGHT;
    case 125: return SIL_DOWN;
    case 126: return SIL_UP;
    case 76: return SIL_NUMPAD_ENTER;
    case 122: return SIL_F1;
    case 120: return SIL_F1 + 1;
    case 99: return SIL_F1 + 2;
    case 118: return SIL_F1 + 3;
    case 96: return SIL_F1 + 4;
    case 97: return SIL_F1 + 5;
    case 98: return SIL_F1 + 6;
    case 100: return SIL_F1 + 7;
    case 101: return SIL_F1 + 8;
    case 109: return SIL_F1 + 9;
    case 103: return SIL_F1 + 10;
    case 111: return SIL_F1 + 11;
    case 82: return SIL_NUMPAD_0;
    case 83: case 84: case 85: case 86: case 87: case 88: case 89: return SIL_NUMPAD_0 + 1 + (k - 83);
    case 91: return SIL_NUMPAD_0 + 8;
    case 92: return SIL_NUMPAD_0 + 9;
    default: return 0;
    }
}

// Letters follow the keyboard layout, like the desktop game's keys did.
static int sil_for_key_event(id e) {
    unsigned short k = ev_keycode(e);
    int sil = sil_for_keycode(k);
    if (sil) return sil;
    NSString *chars = MSG(id, NSUInteger)(e, NSSelectorFromString(@"charactersByApplyingModifiers:"), 0);
    return chars.length == 1 ? sil_for_char([chars characterAtIndex:0]) : 0;
}

// Returns whether the event was used.
static bool handle_key(id e, NSUInteger type) {
    unsigned short k = ev_keycode(e);
    if (k >= 128) return false;
    if (type == EV_KEY_UP) {
        int sil = g_key_down[k];
        if (!sil) return false;
        g_key_down[k] = 0;
        game_key(sil, false);
        return true;
    }
    // Menu shortcuts (Cmd+Q, Cmd+H, ...) and typing into a text field stay with macOS.
    if (g_text_editing || (ev_flags(e) & MOD_CMD)) return false;
    if (MSG(BOOL)(e, @selector(isARepeat))) return g_key_down[k] != 0;
    int sil = sil_for_key_event(e);
    if (!sil) return false;
    g_key_down[k] = sil;
    game_key(sil, true);
    return true;
}

static void handle_flags(id e) {
    static const struct { unsigned short key; NSUInteger bit; int sil; } MODS[] = {
        {56, DEV_LSHIFT, SIL_LSHIFT}, {60, DEV_RSHIFT, SIL_RSHIFT}, {59, DEV_LCTRL, SIL_LCTRL},
        {62, DEV_RCTRL, SIL_RCTRL},   {58, DEV_LALT, SIL_LALT},     {61, DEV_RALT, SIL_RALT},
    };
    unsigned short k = ev_keycode(e);
    NSUInteger flags = ev_flags(e);
    for (size_t i = 0; i < sizeof MODS / sizeof *MODS; i++) {
        if (MODS[i].key != k) continue;
        bool down = (flags & MODS[i].bit) != 0;
        if (down == (g_key_down[k] != 0)) return;
        g_key_down[k] = down ? MODS[i].sil : 0;
        game_key(MODS[i].sil, down);
    }
}

// Let go of every key when the window loses focus; their key-ups won't come.
static void release_keys(void) {
    for (int k = 0; k < 128; k++)
        if (g_key_down[k]) {
            game_key(g_key_down[k], false);
            g_key_down[k] = 0;
        }
}

// ---------------------------------------------------------------------------------
// mouse

static bool g_middle_down;
static CGPoint g_middle_at;
static bool g_right_to_mods;  // the right button is down and goes to Hyperspace

// A right-button action for Hyperspace, at the event's position in the game's
// screen pixels (its drawable: the screen's size when it started, at 2x).
static void right_to_mods(int action, id e) {
    UIView *game = g_host.game;
    CGPoint p = [g_host.clip convertPoint:clip_point(e) toView:game];
    CGSize b = game.bounds.size;
    CGFloat k = game.layer.contentsScale;
    if (b.width <= 0 || b.height <= 0) return;
    hyperspace_right_button(action, (int)lround(p.x / b.width * g_canvas.width * k),
                            (int)lround(p.y / b.height * g_canvas.height * k));
}

// Right button: Escape, which closes the open window or opens the game menu,
// like the desktop game (the iPad build has no other use for it, but mods may).
static void back(void) {
    game_key(SIL_ESCAPE, true);
    game_key(SIL_ESCAPE, false);
}

static id handle_event(id e) {
    if (!g_host || (ev_window(e) && ev_window(e) != g_nswindow)) return e;
    NSUInteger type = ev_type(e);
    switch (type) {
    case EV_KEY_DOWN:
    case EV_KEY_UP:
        return handle_key(e, type) ? nil : e;
    case EV_FLAGS:
        handle_flags(e);
        return e;
    case EV_RIGHT_DOWN:
        g_right_to_mods = hyperspace_wants_right_click();
        if (g_right_to_mods) right_to_mods(HS_RIGHT_BUTTON_DOWN, e);
        else back();
        return nil;
    case EV_RIGHT_DRAGGED:
        if (g_right_to_mods) right_to_mods(HS_RIGHT_BUTTON_MOVE, e);
        return nil;
    case EV_RIGHT_UP:
        if (g_right_to_mods) right_to_mods(HS_RIGHT_BUTTON_UP, e);
        g_right_to_mods = false;
        return nil;
    case EV_OTHER_DOWN:
        if (MSG(NSInteger)(e, @selector(buttonNumber)) == 2) {
            g_middle_down = true;
            g_middle_at = clip_point(e);
        }
        return nil;
    case EV_OTHER_DRAGGED:
        if (g_middle_down) {
            CGPoint p = clip_point(e);
            [g_host panBy:CGPointMake(p.x - g_middle_at.x, p.y - g_middle_at.y)];
            g_middle_at = p;
        }
        return nil;
    case EV_OTHER_UP:
        g_middle_down = false;
        return nil;
    case EV_SCROLL: {
        CGFloat dx = MSG(CGFloat)(e, @selector(scrollingDeltaX)), dy = MSG(CGFloat)(e, @selector(scrollingDeltaY));
        if (MSG(BOOL)(e, @selector(hasPreciseScrollingDeltas))) {
            // trackpad: two fingers pan (pinching zooms)
            CGFloat k = ui_per_ns();
            [g_host panBy:CGPointMake(dx * k, dy * k)];
        } else if (dy != 0) {
            // wheel: zoom where the pointer is
            [g_host zoomBy:(dy > 0 ? 1.25 : 0.8) at:clip_point(e)];
        }
        return nil;
    }
    case EV_MAGNIFY:
        [g_host zoomBy:1 + MSG(CGFloat)(e, @selector(magnification)) at:clip_point(e)];
        return nil;
    default:
        return e;
    }
}

static void install_event_monitor(void) {
    unsigned long long mask = EV_MASK(EV_KEY_DOWN) | EV_MASK(EV_KEY_UP) | EV_MASK(EV_FLAGS) |
                              EV_MASK(EV_RIGHT_DOWN) | EV_MASK(EV_RIGHT_UP) | EV_MASK(EV_RIGHT_DRAGGED) |
                              EV_MASK(EV_OTHER_DOWN) | EV_MASK(EV_OTHER_UP) | EV_MASK(EV_OTHER_DRAGGED) |
                              EV_MASK(EV_SCROLL) | EV_MASK(EV_MAGNIFY);
    id (^handler)(id) = ^id(id e) { return handle_event(e); };
    MSG(id, unsigned long long, id)((id)NSClassFromString(@"NSEvent"),
                                     NSSelectorFromString(@"addLocalMonitorForEventsMatchingMask:handler:"), mask, handler);
}

// ---------------------------------------------------------------------------------
// test commands (FTLMAC_TEST=<fifo>), one per line. Positions are fractions of
// the shown game image (0..1 across and down).
//   click X Y | down X Y | drag X Y | up X Y | rclick X Y | mdown X Y | mdrag X Y | mup X Y
//   wheel X Y DY | scroll X Y DX DY (trackpad) | key KEYCODE [shift|cmd] | frame X Y W H
//   corner DX DY (drag the window's corner)
//   fullscreen | info | quit

static CGPoint test_point(double fx, double fy, bool screen) {
    CGRect r = g_host.clip.bounds;
    CGPoint p = [g_host.clip convertPoint:CGPointMake(r.size.width * fx, r.size.height * fy) toView:g_window];
    CGPoint n = ui_to_ns(p);
    if (screen) {  // Quartz screen coordinates: origin top left of the main display
        CGRect f = ns_frame(g_nswindow);
        CGFloat main_h = UIScreen.mainScreen.bounds.size.height;
        n = CGPointMake(f.origin.x + n.x, main_h - (f.origin.y + n.y));
    }
    return n;
}

static void post(id e) { MSG(void, id, BOOL)(nsapp(), @selector(postEvent:atStart:), e, NO); }

static void post_mouse(NSUInteger type, CGPoint p) {
    id e = ((id (*)(id, SEL, NSUInteger, CGPoint, NSUInteger, double, NSInteger, id, NSInteger, NSInteger, float))objc_msgSend)(
        (id)NSClassFromString(@"NSEvent"),
        NSSelectorFromString(@"mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"),
        type, p, 0, NSProcessInfo.processInfo.systemUptime, MSG(NSInteger)(g_nswindow, @selector(windowNumber)), nil, 0, 1,
        type == EV_LEFT_UP || type == EV_RIGHT_UP ? 0.0f : 1.0f);
    post(e);
}

static void post_cg(CGEventRef cg) {
    CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointer, MSG(NSInteger)(g_nswindow, @selector(windowNumber)));
    CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                MSG(NSInteger)(g_nswindow, @selector(windowNumber)));
    post(MSG(id, CGEventRef)((id)NSClassFromString(@"NSEvent"), NSSelectorFromString(@"eventWithCGEvent:"), cg));
    CFRelease(cg);
}

static void post_key_event(unsigned short code, bool down, CGEventFlags flags, bool modifier) {
    CGEventRef cg = CGEventCreateKeyboardEvent(NULL, code, down);
    CGEventSetFlags(cg, flags);
    if (modifier) CGEventSetType(cg, kCGEventFlagsChanged);
    post(MSG(id, CGEventRef)((id)NSClassFromString(@"NSEvent"), NSSelectorFromString(@"eventWithCGEvent:"), cg));
    CFRelease(cg);
}

// With the modifier (Shift, Cmd) held for a few frames around the key, as a
// player would: the game takes the Shift state once per frame.
static void post_key(unsigned short code, NSString *modifier) {
    unsigned short mod_key = [modifier isEqualToString:@"cmd"] ? 55 : 56;
    CGEventFlags flags = !modifier ? 0
                       : mod_key == 55 ? (CGEventFlags)(MOD_CMD | DEV_LCMD) : (CGEventFlags)(MOD_SHIFT | DEV_LSHIFT);
    int64_t hold = modifier ? 100 * NSEC_PER_MSEC : 0;
    if (modifier) post_key_event(mod_key, true, flags, true);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, hold), dispatch_get_main_queue(), ^{
        post_key_event(code, true, flags, false);
        post_key_event(code, false, flags, false);
        if (modifier)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, hold), dispatch_get_main_queue(), ^{
                post_key_event(mod_key, false, 0, true);
            });
    });
}

static void test_command(NSString *line) {
    NSArray<NSString *> *a = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *cmd = a.firstObject;
    double v[4] = {0};
    for (NSUInteger i = 1; i < a.count && i <= 4; i++) v[i - 1] = a[i].doubleValue;
    if (!g_host) {
        NSLog(@"[ftlmac] test: not ready");
        return;
    }
    MSG(void, BOOL)(nsapp(), NSSelectorFromString(@"activateIgnoringOtherApps:"), YES);
    if ([cmd isEqualToString:@"click"]) {
        post_mouse(EV_LEFT_DOWN, test_point(v[0], v[1], false));
        post_mouse(EV_LEFT_UP, test_point(v[0], v[1], false));
    } else if ([cmd isEqualToString:@"down"]) {
        post_mouse(EV_LEFT_DOWN, test_point(v[0], v[1], false));
    } else if ([cmd isEqualToString:@"drag"]) {
        post_mouse(EV_LEFT_DRAGGED, test_point(v[0], v[1], false));
    } else if ([cmd isEqualToString:@"up"]) {
        post_mouse(EV_LEFT_UP, test_point(v[0], v[1], false));
    } else if ([cmd isEqualToString:@"rclick"]) {
        post_mouse(EV_RIGHT_DOWN, test_point(v[0], v[1], false));
        post_mouse(EV_RIGHT_UP, test_point(v[0], v[1], false));
    } else if ([cmd hasPrefix:@"m"] && ([cmd isEqualToString:@"mdown"] || [cmd isEqualToString:@"mdrag"] || [cmd isEqualToString:@"mup"])) {
        CGEventType t = [cmd isEqualToString:@"mdown"] ? kCGEventOtherMouseDown
                      : [cmd isEqualToString:@"mup"] ? kCGEventOtherMouseUp : kCGEventOtherMouseDragged;
        post_cg(CGEventCreateMouseEvent(NULL, t, test_point(v[0], v[1], true), kCGMouseButtonCenter));
    } else if ([cmd isEqualToString:@"wheel"] || [cmd isEqualToString:@"scroll"]) {
        bool wheel = [cmd isEqualToString:@"wheel"];
        CGEventRef cg = wheel ? CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, (int32_t)v[2])
                              : CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, (int32_t)v[3], (int32_t)v[2]);
        if (!wheel) CGEventSetIntegerValueField(cg, kCGScrollWheelEventIsContinuous, 1);
        CGEventSetLocation(cg, test_point(v[0], v[1], true));
        post_cg(cg);
    } else if ([cmd isEqualToString:@"key"]) {
        post_key((unsigned short)v[0], a.count > 2 ? a[2] : nil);
    } else if ([cmd isEqualToString:@"corner"]) {
        // drag the window's bottom right corner by (DX, DY) Mac points, through AppKit's resize loop
        CGRect f = ns_frame(g_nswindow);
        CGPoint p = CGPointMake(f.size.width - 2, 2);
        post_mouse(EV_LEFT_DOWN, p);
        for (int i = 1; i <= 20; i++) post_mouse(EV_LEFT_DRAGGED, CGPointMake(p.x + v[0] * i / 20, p.y - v[1] * i / 20));
        post_mouse(EV_LEFT_UP, CGPointMake(p.x + v[0], p.y - v[1]));
    } else if ([cmd isEqualToString:@"frame"]) {
        MSG(void, CGRect, BOOL)(g_nswindow, @selector(setFrame:display:), CGRectMake(v[0], v[1], v[2], v[3]), YES);
    } else if ([cmd isEqualToString:@"fullscreen"]) {
        MSG(void, id)(g_nswindow, NSSelectorFromString(@"toggleFullScreen:"), nil);
    } else if ([cmd isEqualToString:@"info"]) {
        double now, base = game_time_base_debug(&now);
        NSLog(@"[ftlmac] info: window %@ content %@ clip %@ zoom %.2f at %.0f,%.0f; time base %.3f now %.3f; hooks %d",
              NSStringFromCGRect(ns_frame(g_nswindow)), NSStringFromCGRect(ns_frame(ns_content_view(g_nswindow))),
              NSStringFromCGRect(g_host.clip.frame), g_host.zoom, g_host.x0, g_host.y0, base, now, hooks_active());
    } else if ([cmd isEqualToString:@"quit"]) {
        exit(0);
    }
}

static void *test_reader(void *path) {
    for (;;) {
        FILE *f = fopen(path, "r");
        if (!f) return NULL;
        char buf[256];
        while (fgets(buf, sizeof buf, f)) {
            NSString *line = [[NSString stringWithUTF8String:buf]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length) dispatch_async(dispatch_get_main_queue(), ^{ test_command(line); });
        }
        fclose(f);
    }
}

// ---------------------------------------------------------------------------------

__attribute__((constructor)) static void ftlmac_init(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UISceneWillConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        scene_will_connect(n);
    }];
    [nc addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        UIWindow *w = n.object;
        if (!g_host && [NSStringFromClass([w.rootViewController class]) isEqualToString:@"SILViewController"])
            dispatch_async(dispatch_get_main_queue(), ^{ install_host(w); });
    }];
    [nc addObserverForName:UITextFieldTextDidBeginEditingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        g_text_editing = true;
        release_keys();
    }];
    [nc addObserverForName:UITextFieldTextDidEndEditingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        g_text_editing = false;
    }];
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        release_keys();
        g_middle_down = false;
    }];

    const char *fifo = getenv("FTLMAC_TEST");
    if (fifo) {
        pthread_t t;
        pthread_create(&t, NULL, test_reader, strdup(fifo));
        pthread_detach(t);
    }
}
