//
//  HIDOffload.m
//  MinisApp
//
//  ly patch — apple-hid：系统级触控注入 / 全屏截图 / 文本输入
//
//  这是「让 agent 驱动别的 App」的地基。原理：
//   1) 触控注入走私有 IOHIDEventSystemClient，可以往**任意前台 App**
//      投递合成触摸事件（不是在本进程里伪造触摸，系统会当成真实手指）。
//   2) 全屏截图走私有 CARenderServerRenderDisplay，能拿到**整个屏幕**，
//      包含别的 App 的画面（不是本进程的 view 快照）。
//   3) 文本输入：ASCII 走键盘事件；CJK 走「写剪贴板 + Cmd+V」，
//      这在 iPadOS 上对外接键盘语义成立，落到任何输入框都有效。
//
//  ⚠️ 依赖私有 entitlement，只有 TrollStore(巨魔) 签名才会被 AMFI 放行：
//      com.apple.private.hid.client.event-dispatch
//      com.apple.private.hid.client.event-filter
//      com.apple.private.iosurface
//  见 Minis.entitlements。普通签名环境下 apple-hid probe 会明确报告哪一条被拒。
//
//  所有私有符号一律 dlsym 动态解析 —— 不在链接期依赖私有 framework，
//  避免 Xcode 工程需要改 link phase，也避免符号缺失直接崩 dyld。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdarg.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <mach-o/dyld.h>
#import <stdlib.h>
#import <unistd.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"

// ── IOKit HID 私有类型（不 import 私有头，自己声明） ──
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef uint32_t IOHIDDigitizerTransducerType;

static const IOHIDDigitizerTransducerType kLyTransducerHand = 3;   // kIOHIDDigitizerTransducerTypeHand
static const uint32_t kLyFieldIsDisplayIntegrated = 0x00000001;    // kIOHIDEventFieldDigitizerIsDisplayIntegrated
// digitizer event mask 位
static const uint32_t kLyMaskRange = 0x00000001;
static const uint32_t kLyMaskTouch = 0x00000002;
static const uint32_t kLyMaskPosition = 0x00000004;

// ── 动态符号 ──
typedef IOHIDEventSystemClientRef (*fn_client_create)(CFAllocatorRef);
typedef void  (*fn_client_dispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*fn_create_digitizer)(CFAllocatorRef, uint64_t, IOHIDDigitizerTransducerType,
                                             uint32_t, uint32_t, uint32_t,
                                             double, double, double, double, double, double,
                                             uint32_t, uint32_t);
typedef IOHIDEventRef (*fn_create_keyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t);
typedef void  (*fn_event_set_int)(IOHIDEventRef, uint32_t, CFIndex);
typedef int   (*fn_render_display)(uint32_t, CFStringRef, void *surface, uint32_t, uint32_t);
typedef uint32_t (*fn_render_server_port)(void *);
typedef void *(*fn_iosurface_create)(CFDictionaryRef);
typedef int   (*fn_iosurface_lock)(void *, uint32_t, uint32_t *);
typedef void *(*fn_iosurface_base)(void *);

static IOHIDEventSystemClientRef g_client = NULL;
static fn_client_dispatch   p_dispatch = NULL;
static fn_create_digitizer  p_digi = NULL;
static fn_create_keyboard   p_kbd = NULL;
static fn_event_set_int     p_setint = NULL;
static void                *g_iokit = NULL;

#ifndef MAX
#define MAX(a,b) ((a) > (b) ? (a) : (b))
#endif
#ifndef MIN
#define MIN(a,b) ((a) < (b) ? (a) : (b))
#endif

static NSString *const TOOL_NAME = @"apple-hid";

// ── 符号解析 ──
static BOOL ly_hid_bootstrap(void) {
    if (g_client) return YES;

    if (!g_iokit) g_iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    void *h = g_iokit ? g_iokit : RTLD_DEFAULT;

    fn_client_create p_create =
        (fn_client_create)dlsym(h, "IOHIDEventSystemClientCreate");
    p_dispatch = (fn_client_dispatch)dlsym(h, "IOHIDEventSystemClientDispatchEvent");
    p_digi  = (fn_create_digitizer)dlsym(h, "IOHIDEventCreateDigitizerEvent");
    p_kbd   = (fn_create_keyboard)dlsym(h, "IOHIDEventCreateKeyboardEvent");
    p_setint = (fn_event_set_int)dlsym(h, "IOHIDEventSetIntegerValue");

    if (!p_create || !p_dispatch || !p_digi) return NO;

    g_client = p_create(kCFAllocatorDefault);
    if (!g_client) return NO;
    return YES;
}

static NSString *ly_hid_reason(void) {
    if (!g_iokit) return @"IOKit.framework not loadable";
    if (!p_dispatch) return @"IOHIDEventSystemClientDispatchEvent symbol missing";
    if (!p_digi) return @"IOHIDEventCreateDigitizerEvent symbol missing";
    if (!g_client) return @"IOHIDEventSystemClientCreate returned NULL (likely entitlement denied)";
    return @"(none)";
}


// ── 触摸事件 ──
static BOOL ly_touch_event(int finger, uint32_t mask, double x, double y) {
    if (!ly_hid_bootstrap()) return NO;
    IOHIDEventRef ev = p_digi(kCFAllocatorDefault, mach_absolute_time(),
                              kLyTransducerHand, 0, (uint32_t)finger, mask,
                              x, y, 0, 0, 0, 0, 0, 0);
    if (!ev) return NO;
    if (p_setint) p_setint(ev, kLyFieldIsDisplayIntegrated, 1);
    p_dispatch(g_client, ev);
    CFRelease(ev);
    return YES;
}

static void ly_tap(double x, double y) {
    ly_touch_event(1, kLyMaskRange | kLyMaskTouch, x, y);
    usleep(40 * 1000);
    ly_touch_event(1, kLyMaskTouch, x, y);
    usleep(15 * 1000);
    ly_touch_event(1, 0, x, y);
}

static void ly_swipe(double x1, double y1, double x2, double y2, double seconds) {
    int steps = (int)(seconds * 60.0);
    if (steps < 8) steps = 8;
    ly_touch_event(1, kLyMaskRange | kLyMaskTouch, x1, y1);
    usleep(20 * 1000);
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        double x = x1 + (x2 - x1) * t;
        double y = y1 + (y2 - y1) * t;
        ly_touch_event(1, kLyMaskPosition, x, y);
        usleep((useconds_t)(seconds * 1e6 / steps));
    }
    ly_touch_event(1, kLyMaskTouch, x2, y2);
    usleep(15 * 1000);
    ly_touch_event(1, 0, x2, y2);
}

static void ly_long_press(double x, double y, double seconds) {
    ly_touch_event(1, kLyMaskRange | kLyMaskTouch, x, y);
    usleep((useconds_t)(seconds * 1e6));
    ly_touch_event(1, kLyMaskTouch, x, y);
    usleep(15 * 1000);
    ly_touch_event(1, 0, x, y);
}

// ── 键盘 ──
// HID usage codes（USB HID Keyboard/Keypad page 0x07）
static uint32_t ly_usage_for_char(char c) {
    if (c >= 'a' && c <= 'z') return 0x04 + (c - 'a');
    if (c >= 'A' && c <= 'Z') return 0x04 + (c - 'A');
    if (c >= '1' && c <= '9') return 0x1E + (c - '1');
    switch (c) {
        case '0': return 0x27;
        case ' ': return 0x2C;
        case '-': return 0x2D; case '=': return 0x2E;
        case '[': return 0x2F; case ']': return 0x30;
        case '\\': return 0x31; case ';': return 0x33;
        case '\'': return 0x34; case '`': return 0x35;
        case ',': return 0x36; case '.': return 0x37; case '/': return 0x38;
        case '\n': return 0x28;
        default: return 0;
    }
}

static BOOL ly_key(uint32_t usage, BOOL down) {
    if (!ly_hid_bootstrap() || !p_kbd) return NO;
    IOHIDEventRef ev = p_kbd(kCFAllocatorDefault, mach_absolute_time(), usage, down ? 1 : 0, 0, 0);
    if (!ev) return NO;
    p_dispatch(g_client, ev);
    CFRelease(ev);
    return YES;
}

/// Cmd+V（iPadOS 上对所有输入框生效的粘贴快捷键）
static void ly_cmd_v(void) {
    ly_key(0xE3, YES);              // Left GUI (Cmd)
    usleep(20 * 1000);
    ly_key(0x19, YES);              // 'v'
    usleep(20 * 1000);
    ly_key(0x19, NO);
    usleep(20 * 1000);
    ly_key(0xE3, NO);
}

// ══════════════════════════════════════════════════════════════════
//  全屏截图 —— 多策略
//
//  实测：CARenderServerRenderDisplay 这条路在本机(iOS 16.6.1)上
//  dlsym 就取不到符号（probe 里 screen_capture=0）。
//  所以这里改成多策略依次尝试，并让 probe 报告哪一种可用。
//
//  S1  _UICreateScreenUIImage()   UIKit 私有函数，直接返回整屏 UIImage。
//      历史最久、最常用，不依赖 IOSurface 手工管理。
//  S2  CARenderServerRenderDisplay + IOSurface  经典路径，需要
//      com.apple.private.coregraphics / iosurface 生效。
// ══════════════════════════════════════════════════════════════════

typedef UIImage *(*fn_create_screen_uiimage)(void);

/// 记录上次"全镜像搜索"命中的库名（供 probe 报告）
static NSString *g_lastSymImage = nil;

/// 暴力遍历所有已加载镜像找符号。
/// 有些私有符号（如 CARenderServerRenderDisplay）不一定出现在
/// RTLD_DEFAULT 的全局命名空间里，也不一定由 CoreGraphics 导出，
/// 所以这里把所有 image 都过一遍，并记录究竟是哪个库提供的。
static void *ly_sym_anywhere(const char *name) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h) continue;
        void *p = dlsym((void *)h, name);
        if (p) {
            const char *nm = _dyld_get_image_name(i);
            if (nm) g_lastSymImage = [NSString stringWithUTF8String:nm];
            return p;
        }
    }
    return NULL;
}

/// 从主可执行文件 + 显式 dlopen 的句柄 + 全镜像 里依次尝试取符号
static void *ly_sym(const char *name, void *h1, void *h2) {
    void *p = NULL;
    if (h1) p = dlsym(h1, name);
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    if (!p && h2) p = dlsym(h2, name);
    if (!p) p = ly_sym_anywhere(name);
    return p;
}

/// 判断一张图是不是全黑（全黑说明截到了但没内容，通常是权限问题）
static BOOL ly_image_is_mostly_black(UIImage *img) {
    if (!img) return YES;
    CGImageRef cg = img.CGImage;
    if (!cg) return YES;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (!w || !h) return YES;
    // 采样一个 16x16 网格，避免整图解码
    size_t gw = 16, gh = 16;
    unsigned char buf[16 * 16 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, gw, gh, 8, gw * 4, cs,
        (CGBitmapInfo)(kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast));
    CGColorSpaceRelease(cs);
    if (!ctx) return YES;
    CGContextDrawImage(ctx, CGRectMake(0, 0, gw, gh), cg);
    CGContextRelease(ctx);
    unsigned long sum = 0;
    for (size_t i = 0; i < gw * gh; i++) {
        sum += buf[i*4] + buf[i*4+1] + buf[i*4+2];
    }
    double mean = (double)sum / (double)(gw * gh * 3);
    return mean < 3.0;   // 几乎全黑
}

/// S1: _UICreateScreenUIImage
static UIImage *ly_capture_uiimage(void) {
    static fn_create_screen_uiimage p = NULL;
    static BOOL probed = NO;
    if (!probed) {
        probed = YES;
        // 不同 iOS 版本 / 不同框架导出名不一致，逐个候选试
        static const char *cands[] = {
            "_UICreateScreenUIImage",
            "UICreateScreenUIImage",
            "_UICreateScreenUIImageFromWindow",
            "UIGraphicsCreateScreenUIImage",
        };
        for (size_t i = 0; i < sizeof(cands)/sizeof(cands[0]) && !p; i++) {
            p = (fn_create_screen_uiimage)ly_sym(cands[i], NULL, NULL);
        }
    }
    if (!p) return nil;
    // UIKit 截图 API 应在主线程调用；用带超时的变体避免
    // 主线程被长时间占用触发 8BADF00D watchdog。
    BOOL timedOut = NO;
    __block UIImage *img = nil;
    id r = noff_dispatch_main_sync_timeout(3.0, &timedOut, ^id{
        UIImage *u = nil;
        u = p();
        return u;
    });
    if (!timedOut) img = (UIImage *)r;
    return img;
}

/// S2: CARenderServerRenderDisplay + IOSurface
static UIImage *ly_capture_render(void) {
    void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
    void *is = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!is) is = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    fn_render_display  p_render = (fn_render_display) ly_sym("CARenderServerRenderDisplay", cg, NULL);
    fn_iosurface_create p_create = (fn_iosurface_create)ly_sym("IOSurfaceCreate", is, NULL);
    fn_iosurface_lock   p_lock   = (fn_iosurface_lock)  ly_sym("IOSurfaceLock", is, NULL);
    fn_iosurface_base   p_base   = (fn_iosurface_base)  ly_sym("IOSurfaceGetBaseAddress", is, NULL);
    // 关键：CARenderServerRenderDisplay 的第一个参数必须是真实 server port，
    // 直接传 0 在多数版本上会失败（这就是之前截图全挂的原因之一）。
    fn_render_server_port p_port =
        (fn_render_server_port)ly_sym("CARenderServerGetServerPort", cg, NULL);
    uint32_t server = 0;
    if (p_port) {
        __block uint32_t sp = 0;
        noff_try_objc(^{ sp = p_port(NULL); });
        server = sp;
    }

    if (!p_render || !p_create || !p_lock || !p_base) return nil;

    CGSize sz = [UIScreen mainScreen].bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    int w = (int)(sz.width * scale), h = (int)(sz.height * scale);
    if (w <= 0 || h <= 0) return nil;

    NSDictionary *props = @{
        @"IOSurfaceWidth": @(w), @"IOSurfaceHeight": @(h),
        @"IOSurfaceBytesPerElement": @(4), @"IOSurfaceBytesPerRow": @(w * 4),
        @"IOSurfacePixelFormat": @(0x42475241),
        @"IOSurfaceAllocSize": @(w * h * 4),
    };
    __block void *surf = NULL;
    noff_try_objc(^{ surf = p_create((__bridge CFDictionaryRef)props); });
    if (!surf) return nil;

    uint32_t seed = 0;
    (void)p_lock(surf, 0, &seed);
    __block int rendered = -1;
    BOOL timedOut2 = NO;
    noff_dispatch_main_sync_timeout(3.0, &timedOut2, ^id{
        rendered = p_render(server, CFSTR("LCD"), surf, 0, 0);
        return nil;
    });
    if (timedOut2 || rendered != 0) return nil;

    void *base = p_base(surf);
    if (!base) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bi = (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, w * 4, cs, bi);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGImageRef cgimg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!cgimg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cgimg];
    CGImageRelease(cgimg);
    return img;
}

/// 渲染 server port 是否可用（probe 用）
static BOOL ly_render_server_available(void) {
    void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
    fn_render_server_port p = (fn_render_server_port)ly_sym("CARenderServerGetServerPort", cg, NULL);
    if (!p) return NO;
    __block uint32_t sp = 0;
    noff_try_objc(^{ sp = p(NULL); });
    return sp != 0;
}

/// 统一入口：返回 (image, strategyName)
static UIImage *ly_capture_screen(NSString **strategy) {
    UIImage *img = ly_capture_uiimage();
    if (img) { if (strategy) *strategy = @"uiimage"; return img; }
    img = ly_capture_render();
    if (img) { if (strategy) *strategy = @"render"; return img; }
    if (strategy) *strategy = @"none";
    return nil;
}

static NSString *ly_write_png(UIImage *img, NSString *path) {
    NSData *png = UIImagePNGRepresentation(img);
    if (!png) return @"PNG encode failed";
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (dir.length) {
        NSError *we = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:&we];
    }
    if (![png writeToFile:path atomically:YES]) {
        return [NSString stringWithFormat:@"write failed: %@", path];
    }
    return nil;
}

static NSString *ly_screen_write_png(NSString *path) {
    NSString *strat = nil;
    UIImage *img = ly_capture_screen(&strat);
    if (!img) {
        return @"screenshot unavailable: 所有策略都失败（_UICreateScreenUIImage / CARenderServerRenderDisplay）";
    }
    if (ly_image_is_mostly_black(img)) {
        return [NSString stringWithFormat:
                @"screenshot all-black (strategy=%@) —— 取到图了但没内容，通常是权限不足", strat];
    }
    NSString *err = ly_write_png(img, path);
    return err;
}

// ── 帮助 ──
static NSString *const HELP_TEXT =
    @"apple-hid - System-wide touch injection, screenshot and text input\n"
     "\n"
     "USAGE:\n"
     "  apple-hid probe                        Check which private APIs are usable\n"
     "  apple-hid size                         Screen size + scale\n"
     "  apple-hid tap <x> <y>\n"
     "  apple-hid swipe <x1> <y1> <x2> <y2> [seconds]\n"
     "  apple-hid long <x> <y> [seconds]\n"
     "  apple-hid type <text>                  ASCII via keyboard events\n"
     "  apple-hid paste <text>                 Set clipboard then Cmd+V (any text)\n"
     "  apple-hid key <usage-hex|name>         e.g. 0x28(=enter) home\n"
     "  apple-hid screenshot <path>            Full screen, INCLUDING other apps\n"
     "  apple-hid ui [depth]                   Dump foreground app's accessibility UI tree\n"
     "  apple-hid dbg                          Step-by-step capability diagnosis (plain text)\n"
     "                                         (labels + exact frames — better than screenshots)\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h       Show this help message\n"
     "  --compact        Minimize JSON output\n"
     "  -q, --quiet      Output only data field\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-hid probe\n"
     "  apple-hid tap 200 700\n"
     "  apple-hid swipe 200 700 200 300 0.4\n"
     "  apple-hid paste \"黄焖鸡米饭\"\n"
     "  apple-hid screenshot /var/minis/attachments/screen.png\n"
     "\n"
     "NOTE: requires TrollStore (巨魔) install — private HID entitlements are\n"
     "      rejected under a normal signature. Run `probe` first.\n";

// ══════════════════════════════════════════════════════════════════
//  辅助功能(AX)读 UI 树
//
//  比截图 + 视觉模型更好的路子：
//    - 直接拿到控件的 label / role / 精确 frame，不用猜坐标
//    - 不花 token、不受网络影响
//    - 屏幕内容变化时元素树同步变化
//  这是把"驱动别的 App"做稳的关键。若 AX 不可用才退回截图。
// ══════════════════════════════════════════════════════════════════

typedef struct __AXUIElement *AXUIElementRef;
typedef int AXError;

#define kAXErrorSuccess 0u

typedef AXUIElementRef (*fn_ax_create_app)(int pid);
typedef AXUIElementRef (*fn_ax_create_syswide)(void);
typedef AXError (*fn_ax_copy_attr)(AXUIElementRef, CFStringRef, CFTypeRef *);
typedef AXError (*fn_ax_copy_attr_names)(AXUIElementRef, CFArrayRef *);
typedef int      (*fn_ax_get_pid)(AXUIElementRef);

static void *g_ax = NULL;
static fn_ax_create_app      p_ax_app = NULL;
static fn_ax_create_syswide  p_ax_syswide = NULL;
static fn_ax_copy_attr       p_ax_copy = NULL;
static fn_ax_get_pid         p_ax_getpid = NULL;

static BOOL ly_ax_bootstrap(void) {
    if (p_ax_app || p_ax_copy) return YES;
    if (g_ax) return YES;
    // 三个可能的框架都试；AX 符号在不同系统上位置不同
    const char *fw[] = {
        "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
        "/System/Library/PrivateFrameworks/AccessibilityUIUtilities.framework/AccessibilityUIUtilities",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
    };
    for (size_t i = 0; i < sizeof(fw)/sizeof(fw[0]) && !g_ax; i++) {
        g_ax = dlopen(fw[i], RTLD_NOW);
    }
    p_ax_app     = (fn_ax_create_app)    ly_sym("AXUIElementCreateApplication", g_ax, NULL);
    p_ax_syswide = (fn_ax_create_syswide)ly_sym("AXUIElementCreateSystemWide", g_ax, NULL);
    p_ax_copy    = (fn_ax_copy_attr)     ly_sym("AXUIElementCopyAttributeValue", g_ax, NULL);
    p_ax_getpid  = (fn_ax_get_pid)       ly_sym("AXUIElementGetPid", g_ax, NULL);
    return p_ax_app != NULL && p_ax_copy != NULL;
}

// 供 probe 用：渲染 server port 是否可用（避免重复实现）
static BOOL ly_render_server_available(void);

/// 取 AX 属性（返回已 +1 的 CFTypeRef，调用方需 CFRelease）
static CFTypeRef ly_ax_val(AXUIElementRef el, CFStringRef attr) {
    if (!el || !p_ax_copy) return NULL;
    __block CFTypeRef v = NULL;   // __block: 需要在 block 里取地址写入
    __block AXError e = 1;
    noff_try_objc(^{ e = p_ax_copy(el, attr, &v); });
    if (e != kAXErrorSuccess) return NULL;
    return v;
}

static NSString *ly_ax_str(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = ly_ax_val(el, attr);
    if (!v) return nil;
    NSString *out = nil;
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        out = [NSString stringWithString:(__bridge NSString *)v];
    } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        out = [(__bridge NSNumber *)v stringValue];
    }
    CFRelease(v);
    return out;
}

/// 把元素压成一行摘要
static NSDictionary *ly_ax_node(AXUIElementRef el) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSString *role  = ly_ax_str(el, CFSTR("AXRole"));
    NSString *label = ly_ax_str(el, CFSTR("AXLabel"));
    NSString *title = ly_ax_str(el, CFSTR("AXTitle"));
    NSString *value = ly_ax_str(el, CFSTR("AXValue"));
    NSString *ident = ly_ax_str(el, CFSTR("AXIdentifier"));
    if (role)  d[@"role"] = role;
    if (label.length) d[@"label"] = label;
    if (title.length) d[@"title"] = title;
    if (value.length) d[@"value"] = value;
    if (ident.length) d[@"id"] = ident;

    // frame = position + size（AXValue 包裹 CGPoint/CGSize）
    CFTypeRef pos = ly_ax_val(el, CFSTR("AXPosition"));
    CFTypeRef siz = ly_ax_val(el, CFSTR("AXSize"));
    if (pos || siz) {
        double px=0, py=0, sw=0, sh=0;
        // AXValueGetValue 是系统函数，用 dlsym 取（避免链接期依赖）
        typedef BOOL (*fn_axv_get)(CFTypeRef, int, void *);
        static fn_axv_get p_axv = NULL;
        if (!p_axv) {
            void *as_ = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW);
            p_axv = (fn_axv_get)ly_sym("AXValueGetValue", as_, NULL);
        }
        if (p_axv) {
            // kAXValueCGPointType = 1, kAXValueCGSizeType = 2
            if (pos) { double p2[2]={0,0}; if (p_axv(pos, 1, p2)) { px=p2[0]; py=p2[1]; } }
            if (siz) { double s2[2]={0,0}; if (p_axv(siz, 2, s2)) { sw=s2[0]; sh=s2[1]; } }
        }
        if (px || py || sw || sh) {
            d[@"x"] = @(px); d[@"y"] = @(py);
            d[@"w"] = @(sw); d[@"h"] = @(sh);
        }
    }
    if (pos) CFRelease(pos);
    if (siz) CFRelease(siz);
    return d.count ? d : nil;
}

static void ly_ax_walk(AXUIElementRef el, int depth, int maxDepth, NSMutableArray *out) {
    if (!el || depth > maxDepth || out.count > 800) return;
    NSDictionary *n = ly_ax_node(el);
    if (n) [out addObject:n];
    if (depth == maxDepth) return;
    CFTypeRef kids = ly_ax_val(el, CFSTR("AXChildren"));
    if (kids && CFGetTypeID(kids) == CFArrayGetTypeID()) {
        CFArrayRef arr = (CFArrayRef)kids;
        CFIndex cnt = CFArrayGetCount(arr);
        for (CFIndex i = 0; i < cnt && out.count < 800; i++) {
            AXUIElementRef k = (AXUIElementRef)CFArrayGetValueAtIndex(arr, i);
            if (k) ly_ax_walk(k, depth + 1, maxDepth, out);
        }
    }
    if (kids) CFRelease(kids);
}

/// 返回前台 App 的 UI 树（或指定 bundle id 对应进程）
static NSDictionary *ly_ax_capture(int depth, NSString *bundleID) {
    if (!ly_ax_bootstrap()) {
        return @{ @"ok": @NO, @"error": @"AX 符号不可用（AXUIElementCreateApplication / CopyAttributeValue）" };
    }
    AXUIElementRef target = NULL;
    int pid = 0;

    if (bundleID.length) {
        // 通过 LSApplicationWorkspace 查 pid 比较麻烦；这里退化为不行就报错
        return @{ @"ok": @NO, @"error": @"指定 bundle id 暂未支持，先用前台 App" };
    }

    if (p_ax_syswide) {
        AXUIElementRef sys = p_ax_syswide();
        if (sys) {
            CFTypeRef focused = ly_ax_val(sys, CFSTR("AXFocusedApplication"));
            if (focused) { target = (AXUIElementRef)focused; }
            // sys 自身不释放（AX 对象生命周期与 CF 不同，保守起见跳过）
        }
    }
    if (!target) {
        return @{ @"ok": @NO, @"error": @"拿不到前台 App 的 AX 元素（可能需要辅助功能授权）" };
    }
    if (p_ax_getpid) pid = p_ax_getpid(target);

    NSMutableArray *nodes = [NSMutableArray array];
    BOOL timedOut = NO;
    noff_dispatch_main_sync_timeout(8.0, &timedOut, ^id{
        ly_ax_walk(target, 0, depth, nodes);
        return nil;
    });
    if (timedOut) {
        return @{ @"ok": @NO, @"error": @"读取 UI 树超时" };
    }
    return @{
        @"ok": @YES,
        @"pid": @(pid),
        @"depth": @(depth),
        @"count": @(nodes.count),
        @"nodes": nodes,
    };
}

// ══════════════════════════════════════════════════════════════════
//  诊断：逐步骤打印（纯文本，便于直接阅读/截图）
//  目的：不再靠猜，明确每个符号是否找到、来自哪个库、每步返回值
// ══════════════════════════════════════════════════════════════════
static void ly_dbg_line(int fd, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *out = [m stringByAppendingString:@"\n"];
    write(fd, out.UTF8String, strlen(out.UTF8String));
}

static void ly_dbg(int fd) {
    ly_dbg_line(fd, @"════════ apple-hid 诊断 ════════");
    ly_dbg_line(fd, @"UIDevice: %@  iOS %@", [[UIDevice currentDevice] model],
                [[UIDevice currentDevice] systemVersion]);
    ly_dbg_line(fd, @"屏幕: %.0fx%.0f pt, scale=%.1f", [UIScreen mainScreen].bounds.size.width,
                [UIScreen mainScreen].bounds.size.height, [UIScreen mainScreen].scale);
    ly_dbg_line(fd, @"已加载镜像数: %u", _dyld_image_count());

    // ── 1) 符号逐项 ──
    ly_dbg_line(fd, @"");
    ly_dbg_line(fd, @"【1】符号解析");
    struct { const char *name; const char *fw; } cands[] = {
        {"_UICreateScreenUIImage",              NULL},
        {"UICreateScreenUIImage",               NULL},
        {"_UICreateScreenUIImageFromWindow",    NULL},
        {"UIGraphicsCreateScreenUIImage",       NULL},
        {"CARenderServerRenderDisplay",         "CoreGraphics"},
        {"CARenderServerGetServerPort",         "CoreGraphics"},
        {"CARenderServerRenderDisplaySync",     "CoreGraphics"},
        {"IOSurfaceCreate",                     "IOSurface"},
        {"IOSurfaceLock",                       "IOSurface"},
        {"IOSurfaceGetBaseAddress",             "IOSurface"},
        {"AXUIElementCreateSystemWide",         "AX"},
        {"AXUIElementCreateApplication",        "AX"},
        {"AXUIElementCopyAttributeValue",       "AX"},
        {"AXUIElementSetAttributeValue",        "AX"},
        {"AXUIElementPerformAction",            "AX"},
        {"AXUIElementGetPid",                   "AX"},
    };
    void *hCG = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
    void *hIS = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!hIS) hIS = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    void *hAX1 = dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW);
    void *hAX2 = dlopen("/System/Library/PrivateFrameworks/AccessibilityUIUtilities.framework/AccessibilityUIUtilities", RTLD_NOW);
    void *hAX3 = dlopen("/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility", RTLD_NOW);
    void *hAX4 = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW);
    ly_dbg_line(fd, @"  dlopen CoreGraphics: %s", hCG ? "OK" : "FAIL");
    ly_dbg_line(fd, @"  dlopen IOSurface:    %s", hIS ? "OK" : "FAIL");
    ly_dbg_line(fd, @"  dlopen AccessibilityUtilities:   %s", hAX1 ? "OK" : "FAIL");
    ly_dbg_line(fd, @"  dlopen AccessibilityUIUtilities: %s", hAX2 ? "OK" : "FAIL");
    ly_dbg_line(fd, @"  dlopen Accessibility:            %s", hAX3 ? "OK" : "FAIL");
    ly_dbg_line(fd, @"  dlopen ApplicationServices:      %s", hAX4 ? "OK" : "FAIL");

    for (size_t i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
        void *h1 = NULL;
        if (cands[i].fw && strcmp(cands[i].fw, "CoreGraphics") == 0) h1 = hCG;
        if (cands[i].fw && strcmp(cands[i].fw, "IOSurface") == 0)    h1 = hIS;
        if (cands[i].fw && strcmp(cands[i].fw, "AX") == 0)           h1 = hAX1 ? hAX1 : (hAX2 ? hAX2 : (hAX3 ? hAX3 : hAX4));
        g_lastSymImage = nil;
        void *p = ly_sym(cands[i].name, h1, NULL);
        NSString *where = g_lastSymImage ? g_lastSymImage.lastPathComponent : @"-";
        ly_dbg_line(fd, @"  %-32s %-10s %@", cands[i].name, p ? "FOUND" : "NOT FOUND", p ? where : @"");
    }

    // ── 2) 截图逐步骤 ──
    ly_dbg_line(fd, @"");
    ly_dbg_line(fd, @"【2】截图 S2 (CARenderServerRenderDisplay) 逐步骤");
    fn_render_server_port p_port = (fn_render_server_port)ly_sym("CARenderServerGetServerPort", hCG, NULL);
    ly_dbg_line(fd, @"  GetServerPort 符号: %s", p_port ? "有" : "无");
    uint32_t sp = 0;
    if (p_port) { __block uint32_t t = 0; noff_try_objc(^{ t = p_port(NULL); }); sp = t; }
    ly_dbg_line(fd, @"  server port = %u %@", sp, sp ? @"(OK)" : @"(← 拿到 0，渲染调用必然失败)");

    fn_iosurface_create p_c = (fn_iosurface_create)ly_sym("IOSurfaceCreate", hIS, NULL);
    if (p_c) {
        CGSize sz = [UIScreen mainScreen].bounds.size;
        CGFloat sc = [UIScreen mainScreen].scale;
        int w = (int)(sz.width*sc), h = (int)(sz.height*sc);
        NSDictionary *props = @{ @"IOSurfaceWidth": @(w), @"IOSurfaceHeight": @(h),
            @"IOSurfaceBytesPerElement": @(4), @"IOSurfaceBytesPerRow": @(w*4),
            @"IOSurfacePixelFormat": @(0x42475241), @"IOSurfaceAllocSize": @(w*h*4) };
        __block void *surf = NULL;
        noff_try_objc(^{ surf = p_c((__bridge CFDictionaryRef)props); });
        ly_dbg_line(fd, @"  IOSurfaceCreate(%dx%d) = %s", w, h, surf ? "OK" : "NULL ← 权限或参数问题");
        if (surf) {
            fn_iosurface_lock p_l = (fn_iosurface_lock)ly_sym("IOSurfaceLock", hIS, NULL);
            fn_iosurface_base p_b = (fn_iosurface_base)ly_sym("IOSurfaceGetBaseAddress", hIS, NULL);
            uint32_t seed = 0;
            ly_dbg_line(fd, @"  IOSurfaceLock      = %s", p_l ? ((p_l(surf,0,&seed)==0) ? @"OK" : @"非0") : @"符号缺失");
            void *base = p_b ? p_b(surf) : NULL;
            ly_dbg_line(fd, @"  GetBaseAddress     = %s", base ? "OK" : "NULL");
            fn_render_display p_r = (fn_render_display)ly_sym("CARenderServerRenderDisplay", hCG, NULL);
            if (p_r) {
                __block int rc = -999;
                BOOL to = NO;
                noff_dispatch_main_sync_timeout(3.0, &to, ^id{ rc = p_r(sp, CFSTR("LCD"), surf, 0, 0); return nil; });
                ly_dbg_line(fd, @"  RenderDisplay(port=%u) = %d %@", sp, rc, to ? @"(超时)" : (rc==0?@"(OK)":@"(← 失败)"));
            } else {
                ly_dbg_line(fd, @"  RenderDisplay 符号缺失");
            }
        }
    } else {
        ly_dbg_line(fd, @"  IOSurfaceCreate 符号缺失");
    }

    ly_dbg_line(fd, @"");
    ly_dbg_line(fd, @"【3】截图 S1 (_UICreateScreenUIImage)");
    {
        NSString *strat = nil;
        UIImage *img = ly_capture_uiimage();
        ly_dbg_line(fd, @"  结果: %s", img ? "拿到图" : "nil");
        if (img) {
            ly_dbg_line(fd, @"  尺寸: %.0fx%.0f  全黑=%s",
                        CGImageGetWidth(img.CGImage), CGImageGetHeight(img.CGImage),
                        ly_image_is_mostly_black(img) ? "是" : "否");
        }
        strat = nil;
        UIImage *img2 = ly_capture_screen(&strat);
        ly_dbg_line(fd, @"  总入口: %s (strategy=%@)", img2 ? "成功" : "失败", strat ?: @"none");
    }

    // ── 4) AX 逐步骤 ──
    ly_dbg_line(fd, @"");
    ly_dbg_line(fd, @"【4】辅助功能 AX");
    BOOL axok = ly_ax_bootstrap();
    ly_dbg_line(fd, @"  bootstrap: %s", axok ? "OK" : "符号缺失");
    ly_dbg_line(fd, @"  CreateSystemWide: %s", p_ax_syswide ? "有" : "无");
    ly_dbg_line(fd, @"  CreateApplication: %s", p_ax_app ? "有" : "无");
    ly_dbg_line(fd, @"  CopyAttributeValue: %s", p_ax_copy ? "有" : "无");
    if (axok && p_ax_syswide) {
        AXUIElementRef sys = p_ax_syswide();
        ly_dbg_line(fd, @"  SystemWide 元素 = %s", sys ? "非空" : "NULL");
        if (sys) {
            CFTypeRef v = NULL;
            AXError e = p_ax_copy(sys, CFSTR("AXFocusedApplication"), &v);
            ly_dbg_line(fd, @"  AXFocusedApplication 错误码 = %d %@", e,
                        e==0 ? @"(OK)" : (e==-25211 ? @"(← APIDisabled，缺辅助功能权限)" :
                                          (e==-25205 ? @"(← CannotComplete)" :
                                           (e==-25203 ? @"(← InvalidUIElement)" : @""))));
            if (v) {
                int pid = p_ax_getpid ? p_ax_getpid((AXUIElementRef)v) : 0;
                ly_dbg_line(fd, @"  前台 App pid = %d", pid);
                NSDictionary *r = ly_ax_capture(3, nil);
                ly_dbg_line(fd, @"  UI 树: ok=%@ count=%@ err=%@",
                            r[@"ok"], r[@"count"], r[@"error"] ?: @"-");
            }
        }
    }
    ly_dbg_line(fd, @"════════ 诊断结束 ════════");
}

// ── 主处理 ──
static int hid_handler(int argc, char **argv,
                       int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }
    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet   = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *sub = noff_get_subcommand(argc, argv);
    NSArray *pos = noff_positional_args(argc, argv);

    if (!sub || [sub isEqualToString:@"probe"]) {
        BOOL ok = ly_hid_bootstrap();
        BOOL kbd = (p_kbd != NULL);

        // ── 截图能力逐项检测 ──
        void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
        void *is = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
        if (!is) is = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_NOW);
        g_lastSymImage = nil;
        BOOL sym_uiimage = ly_sym("_UICreateScreenUIImage", NULL, NULL) != NULL;
        NSString *uiimageFrom = g_lastSymImage;
        g_lastSymImage = nil;
        BOOL sym_render  = ly_sym("CARenderServerRenderDisplay", cg, NULL) != NULL;
        NSString *renderFrom = g_lastSymImage;
        g_lastSymImage = nil;
        BOOL sym_surface = ly_sym("IOSurfaceCreate", is, NULL) != NULL;
        NSString *surfaceFrom = g_lastSymImage;
        g_lastSymImage = nil;

        // 实际试一次：拿到图 + 判断是否全黑
        NSString *strat = nil;
        NSString *captureNote = @"not attempted";
        BOOL captureOk = NO, nonBlack = NO;
        if (ok) {   // 只在能有 UI 上下文时试
            UIImage *img = ly_capture_screen(&strat);
            if (img) {
                captureOk = YES;
                nonBlack = !ly_image_is_mostly_black(img);
                CGSize px = CGSizeMake(CGImageGetWidth(img.CGImage), CGImageGetHeight(img.CGImage));
                captureNote = [NSString stringWithFormat:@"%@ px=%.0fx%.0f %@",
                               strat, px.width, px.height, nonBlack ? @"non-black" : @"ALL-BLACK"];
            } else {
                captureNote = @"all strategies failed";
            }
        }

        // ── 辅助功能(AX)可用性探测：为后续"读 UI 树"做准备 ──
        NSDictionary *data = @{
            @"hid_client_ok": @(ok),
            @"reason": ly_hid_reason(),
            @"touch_injection": @(ok),
            @"keyboard_injection": @(kbd),
            @"iokit_loaded": @(g_iokit != NULL),

            @"screenshot_symbol_uiimage": @(sym_uiimage),
            @"screenshot_symbol_render":  @(sym_render),
            @"screenshot_symbol_iosurface": @(sym_surface),
            @"sym_image_uiimage": uiimageFrom ? uiimageFrom.lastPathComponent : @"(not found)",
            @"sym_image_render":  renderFrom ? renderFrom.lastPathComponent : @"(not found)",
            @"sym_image_iosurface": surfaceFrom ? surfaceFrom.lastPathComponent : @"(not found)",
            @"dyld_image_count": @(_dyld_image_count()),
            @"render_server_port_nonzero": @(ly_render_server_available()),
            @"screenshot_capture_ok": @(captureOk),
            @"screenshot_non_black": @(nonBlack),
            @"screenshot_strategy": strat ?: @"none",
            @"screenshot_note": captureNote,
            @"screen_capture": @(captureOk && nonBlack),

            @"ax_available": @(ly_ax_bootstrap()),
            @"ax_bootstrap_result": ly_ax_bootstrap() ? @"ok" : @"symbols missing",

            @"note": ok ? @"ready" : @"touch injection unavailable — check TrollStore entitlements",
        };
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"probe", data), compact, quiet);
        return ok ? NOFF_EXIT_SUCCESS : NOFF_EXIT_NOT_AVAILABLE;
    }

    if ([sub isEqualToString:@"size"]) {
        CGSize sz = [UIScreen mainScreen].bounds.size;
        NSDictionary *data = @{
            @"width": @(sz.width), @"height": @(sz.height),
            @"scale": @([UIScreen mainScreen].scale),
            @"px_width": @(sz.width * [UIScreen mainScreen].scale),
            @"px_height": @(sz.height * [UIScreen mainScreen].scale),
        };
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"size", data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    if ([sub isEqualToString:@"tap"] || [sub isEqualToString:@"long"]) {
        if (pos.count < 2) {
            noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, sub, NOFF_ERR_INVALID_ARGS,
                @"Usage: apple-hid tap <x> <y>"), compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        double x = [pos[0] doubleValue], y = [pos[1] doubleValue];
        BOOL ready = ly_hid_bootstrap();
        if (!ready) {
            noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, sub, NOFF_ERR_NOT_AVAILABLE,
                [NSString stringWithFormat:@"touch injection unavailable: %@", ly_hid_reason()]), compact, quiet);
            return NOFF_EXIT_NOT_AVAILABLE;
        }
        if ([sub isEqualToString:@"tap"]) ly_tap(x, y);
        else ly_long_press(x, y, pos.count > 2 ? [pos[2] doubleValue] : 0.6);
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, sub,
            @{@"x": @(x), @"y": @(y), @"injected": @YES}), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    if ([sub isEqualToString:@"swipe"]) {
        if (pos.count < 4) {
            noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, sub, NOFF_ERR_INVALID_ARGS,
                @"Usage: apple-hid swipe <x1> <y1> <x2> <y2> [seconds]"), compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        if (!ly_hid_bootstrap()) {
            noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, sub, NOFF_ERR_NOT_AVAILABLE,
                [NSString stringWithFormat:@"touch injection unavailable: %@", ly_hid_reason()]), compact, quiet);
            return NOFF_EXIT_NOT_AVAILABLE;
        }
        ly_swipe([pos[0] doubleValue], [pos[1] doubleValue],
                 [pos[2] doubleValue], [pos[3] doubleValue],
                 pos.count > 4 ? [pos[4] doubleValue] : 0.35);
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, sub, @{@"ok": @YES}), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    if ([sub isEqualToString:@"type"]) {
        // 位置参数可能被空格拆散，还原成原串
        NSString *text = pos.count ? [pos componentsJoinedByString:@" "] : @"";
        if (text.length == 0) {
            noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, sub, NOFF_ERR_INVALID_ARGS,
                @"Usage: apple-hid type <ascii-text>"), compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        int typed = 0;
        for (NSUInteger i = 0; i < text.length; i++) {
            char c = [text characterAtIndex:i];
            if (c > 127) { continue; }                 // 非 ASCII 跳过，用 paste
            uint32_t usage = ly_usage_for_char(c);
            if (!usage) continue;
            ly_key(usage, YES); usleep(12 * 1000);
            ly_key(usage, NO);  usleep(12 * 1000);
            typed++;
        }
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, sub,
            @{@"typed": @(typed), @"skipped_non_ascii": @((NSInteger)text.length - typed)}), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    if ([sub isEqualToString:@"paste"]) {
        NSString *text = pos.count ? [pos componentsJoinedByString:@" "] : @"";
        if (text.length == 0) {
            noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, sub, NOFF_ERR_INVALID_ARGS,
                @"Usage: apple-hid paste <text>"), compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        __block BOOL set = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIPasteboard generalPasteboard].string = text;
            set = YES;
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        usleep(250 * 1000);          // 给剪贴板同步留时间
        ly_cmd_v();
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, sub,
            @{@"clipboard_set": @(set), @"length": @(text.length)}), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    if ([sub isEqualToString:@"key"]) {
        if (pos.count < 1) {
            noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, sub, NOFF_ERR_INVALID_ARGS,
                @"Usage: apple-hid key <usage-hex|enter|escape|home|space>"), compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        NSString *k = [pos[0] lowercaseString];
        uint32_t usage = 0;
        if ([k isEqualToString:@"enter"]) usage = 0x28;
        else if ([k isEqualToString:@"escape"] || [k isEqualToString:@"esc"]) usage = 0x29;
        else if ([k isEqualToString:@"space"]) usage = 0x2C;
        else if ([k isEqualToString:@"tab"]) usage = 0x2B;
        else if ([k isEqualToString:@"home"]) { ly_key(0xE3, YES); ly_key(0x4A, YES); usleep(20000); ly_key(0x4A, NO); ly_key(0xE3, NO); 
            noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, sub, @{@"key": k}), compact, quiet);
            return NOFF_EXIT_SUCCESS; }
        else if ([k hasPrefix:@"0x"]) usage = (uint32_t)strtoul([[k substringFromIndex:2] UTF8String], NULL, 16);
        else usage = (uint32_t)[k intValue];

        ly_key(usage, YES); usleep(20 * 1000); ly_key(usage, NO);
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, sub, @{@"key": k, @"usage": @(usage)}), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    if ([sub isEqualToString:@"dbg"]) {
        ly_dbg(stdout_fd);
        return NOFF_EXIT_SUCCESS;
    }

    if ([sub isEqualToString:@"ui"]) {
        int depth = 6;
        if (pos.count) depth = MAX(1, MIN(12, [pos[0] intValue]));
        NSDictionary *r = ly_ax_capture(depth, nil);
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"ui", r), compact, quiet);
        return [r[@"ok"] boolValue] ? NOFF_EXIT_SUCCESS : NOFF_EXIT_ERROR;
    }

    if ([sub isEqualToString:@"screenshot"]) {
        NSString *guestPath = pos.count ? pos[0] : @"/var/minis/attachments/screen.png";
        NSString *hostPath = noff_resolve_host_path(guestPath);
        if (!hostPath) {
            noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, sub, NOFF_ERR_INVALID_ARGS,
                [NSString stringWithFormat:@"Cannot resolve path: %@", guestPath]), compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        NSString *err = ly_screen_write_png(hostPath);
        if (err) {
            noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, sub, NOFF_ERR_INTERNAL_ERROR, err), compact, quiet);
            return NOFF_EXIT_ERROR;
        }
        CGSize sz = [UIScreen mainScreen].bounds.size;
        NSDictionary *data = @{
            @"path": guestPath,
            @"width": @(sz.width), @"height": @(sz.height),
            @"scale": @([UIScreen mainScreen].scale),
        };
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, sub, data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    noff_emit_json(stdout_fd, noff_json_error(TOOL_NAME, sub, NOFF_ERR_INVALID_ARGS,
        [NSString stringWithFormat:@"Unknown subcommand '%@'. Use --help.", sub]), compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void hid_offload_register(void) {
    int err = native_offload_add_handler("apple-hid", hid_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-hid");
        NSLog(@"NativeOffloads: apple-hid handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-hid handler (err=%d)", err);
    }
}
