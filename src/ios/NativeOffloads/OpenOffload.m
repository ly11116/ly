//
//  OpenOffload.m
//  MinisApp
//
//  Native offload handler for `apple-open`.
//  Opens URLs, URL schemes, and system settings via UIApplication.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-open";

static NSString *const HELP_TEXT =
    @"apple-open - Open URLs, apps, and system settings\n"
     "\n"
     "USAGE:\n"
     "  apple-open <url>\n"
     "  apple-open settings[://page]\n"
     "\n"
     "ARGUMENTS:\n"
     "  <url>            URL to open (http, https, tel, mailto, sms, app schemes)\n"
     "  settings         Open iOS Settings app\n"
     "  settings://wifi  Open specific settings page\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h       Show this help message\n"
     "  --compact        Minimize JSON output\n"
     "  -q, --quiet      Output only data field\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-open \"https://example.com\"\n"
     "  apple-open \"tel:10086\"\n"
     "  apple-open \"mailto:user@example.com\"\n"
     "  apple-open settings\n"
     "  apple-open \"maps://?q=coffee\"\n";

// Map shorthand settings names to URL strings
static NSString *resolve_settings_url(NSString *input) {
    if ([input isEqualToString:@"settings"]) {
        return UIApplicationOpenSettingsURLString;
    }
    // settings://wifi → App-Prefs:root=WIFI (approximate; actual deep links vary by iOS version)
    // We use the standard openSettingsURLString which goes to our app's settings
    // For system-level deep links, the user can pass the full prefs: URL
    if ([input hasPrefix:@"settings://"]) {
        NSString *page = [input substringFromIndex:@"settings://".length];
        NSDictionary *map = @{
            @"wifi":          @"App-Prefs:root=WIFI",
            @"bluetooth":     @"App-Prefs:root=Bluetooth",
            @"notifications": @"App-Prefs:root=NOTIFICATIONS_ID",
            @"general":       @"App-Prefs:root=General",
            @"display":       @"App-Prefs:root=DISPLAY",
            @"sounds":        @"App-Prefs:root=Sounds",
            @"battery":       @"App-Prefs:root=BATTERY_USAGE",
            @"privacy":       @"App-Prefs:root=Privacy",
            @"cellular":      @"App-Prefs:root=MOBILE_DATA_SETTINGS_ID",
        };
        NSString *url = map[page.lowercaseString];
        return url ?: [NSString stringWithFormat:@"App-Prefs:root=%@", page];
    }
    return input;
}

static int open_handler(int argc, char **argv,
                         int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    // The URL is the first positional argument (subcommand position)
    NSString *urlArg = noff_get_subcommand(argc, argv);
    if (!urlArg) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"open",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No URL specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *resolvedURL = resolve_settings_url(urlArg);
    NSURL *url = [NSURL URLWithString:resolvedURL];
    if (!url) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"open",
                                             NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"Invalid URL: %@", urlArg]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    __block BOOL opened = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url
                                         options:@{}
                               completionHandler:^(BOOL success) {
            opened = success;
            dispatch_semaphore_signal(sem);
        }];
    });

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    NSDictionary *data = @{
        @"url": urlArg,
        @"resolved_url": resolvedURL,
        @"opened": @(opened),
    };
    NSDictionary *result = noff_json_envelope(TOOL_NAME, @"open", data);
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

void open_offload_register(void) {
    int err = native_offload_add_handler("apple-open", open_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-open");
        NSLog(@"NativeOffloads: apple-open handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-open handler (err=%d)", err);
    }
}

// =====================================================================
//  ly 二改追加：apple-apps —— 已安装 App 枚举 / 启动
//  巨魔(TrollStore)环境下可直接使用 LSApplicationWorkspace 私有 API，
//  因为 TrollStore 重签时给了 platform-application / no-sandbox 权限。
//  非巨魔环境会自动降级为「仅尝试 URL scheme 启动」。
// =====================================================================

#import <objc/message.h>

static NSString *const APPS_TOOL_NAME = @"apple-apps";

static NSString *const APPS_HELP_TEXT =
    @"apple-apps - List and launch installed iOS apps\n"
     "\n"
     "USAGE:\n"
     "  apple-apps list [--filter <kw>] [--limit N] [--user-only]\n"
     "  apple-apps info <bundle-id>\n"
     "  apple-apps schemes <bundle-id>\n"
     "  apple-apps open <bundle-id | scheme://... | app-name>\n"
     "  apple-apps frontmost\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h       Show this help message\n"
     "  --compact        Minimize JSON output\n"
     "  -q, --quiet      Output only data field\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-apps list --filter 微信\n"
     "  apple-apps list --user-only --limit 50\n"
     "  apple-apps open com.tencent.xin\n"
     "  apple-apps open weixin://\n"
     "  apple-apps open Safari\n";

typedef id   (*ly_msg_id)     (id, SEL);
typedef BOOL (*ly_msg_bool_id)(id, SEL, id);
typedef NSArray *(*ly_msg_arr)(id, SEL);

/// 获取 LSApplicationWorkspace 单例；不可用时返回 nil（非巨魔环境可能出现）
static id ly_app_workspace(void) {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) return nil;
    __block id ws = nil;
    noff_try_objc(^{
        ws = ((ly_msg_id)objc_msgSend)((id)cls, sel_registerName("defaultWorkspace"));
    });
    return ws;
}

/// 安全读取 proxy 上返回对象的方法
static id ly_proxy_get(id proxy, const char *selName) {
    if (!proxy || ![proxy respondsToSelector:sel_registerName(selName)]) return nil;
    __block id v = nil;
    noff_try_objc(^{ v = ((ly_msg_id)objc_msgSend)(proxy, sel_registerName(selName)); });
    return v;
}

/// 从 app bundle 的 Info.plist 里读 URL schemes
static NSArray<NSString *> *ly_proxy_schemes(id proxy) {
    NSURL *bundleURL = ly_proxy_get(proxy, "bundleURL");
    if (![bundleURL isKindOfClass:[NSURL class]]) return @[];
    NSURL *plistURL = [bundleURL URLByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:plistURL];
    NSArray *types = info[@"CFBundleURLTypes"];
    if (![types isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSDictionary *t in types) {
        NSArray *schemes = t[@"CFBundleURLSchemes"];
        if ([schemes isKindOfClass:[NSArray class]]) [out addObjectsFromArray:schemes];
    }
    return out;
}

/// 一条 app 记录的 JSON 形态
static NSDictionary *ly_app_record(id proxy, BOOL includeSchemes) {
    NSString *bid  = ly_proxy_get(proxy, "bundleIdentifier");
    NSString *name = ly_proxy_get(proxy, "localizedName");
    NSString *type = ly_proxy_get(proxy, "applicationType");
    if (![bid isKindOfClass:[NSString class]]) return nil;

    NSMutableDictionary *rec = [NSMutableDictionary dictionary];
    rec[@"bundle_id"] = bid;
    if ([name isKindOfClass:[NSString class]]) rec[@"name"] = name;
    if ([type isKindOfClass:[NSString class]]) rec[@"type"] = type;
    if (includeSchemes) {
        NSArray *s = ly_proxy_schemes(proxy);
        if (s.count) rec[@"url_schemes"] = s;
    }
    return rec;
}

static int apps_handler(int argc, char **argv,
                        int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, APPS_HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet   = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *sub = noff_get_subcommand(argc, argv);
    if (!sub) sub = @"list";

    id ws = ly_app_workspace();
    if (!ws) {
        NSDictionary *err = noff_json_error(
            APPS_TOOL_NAME, sub, NOFF_ERR_NOT_AVAILABLE,
            @"LSApplicationWorkspace unavailable — needs TrollStore / platform-application entitlement.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_NOT_AVAILABLE;
    }

    // ---- list ----
    if ([sub isEqualToString:@"list"]) {
        NSString *filter = noff_find_arg(argc, argv, "--filter");
        NSString *limitStr = noff_find_arg(argc, argv, "--limit");
        NSInteger limit = limitStr ? [limitStr integerValue] : 0;
        BOOL userOnly = noff_has_flag(argc, argv, "--user-only");

        __block NSArray *raw = @[];
        noff_try_objc(^{
            raw = ((ly_msg_arr)objc_msgSend)(ws, sel_registerName("allInstalledApplications"));
        });
        if (![raw isKindOfClass:[NSArray class]]) raw = @[];

        NSMutableArray *records = [NSMutableArray array];
        NSInteger skippedSystem = 0;
        for (id proxy in raw) {
            NSDictionary *rec = ly_app_record(proxy, NO);
            if (!rec) continue;
            NSString *type = rec[@"type"];
            if (userOnly && type && ![type isEqualToString:@"User"]) { skippedSystem++; continue; }
            if (filter.length) {
                NSString *hay = [[NSString stringWithFormat:@"%@ %@",
                                  rec[@"bundle_id"] ?: @"", rec[@"name"] ?: @""] lowercaseString];
                if ([hay rangeOfString:filter.lowercaseString].location == NSNotFound) continue;
            }
            [records addObject:rec];
            if (limit > 0 && (NSInteger)records.count >= limit) break;
        }

        // NSComparator 的签名是 (id, id)；写成具体类型会触发
        // "incompatible block pointer types" 编译错误，所以用 id 再在块内转型。
        NSArray *sorted = [records sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            NSDictionary *da = (NSDictionary *)a, *db = (NSDictionary *)b;
            NSString *ka = da[@"name"] ?: da[@"bundle_id"];
            NSString *kb = db[@"name"] ?: db[@"bundle_id"];
            return [ka caseInsensitiveCompare:kb];
        }];

        NSDictionary *data = @{
            @"count": @(sorted.count),
            @"total_installed": @(raw.count),
            @"system_skipped": @(skippedSystem),
            @"apps": sorted,
        };
        noff_emit_json(stdout_fd, noff_json_envelope(APPS_TOOL_NAME, @"list", data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    // ---- info / schemes ----
    if ([sub isEqualToString:@"info"] || [sub isEqualToString:@"schemes"]) {
        NSArray *pos = noff_positional_args(argc, argv);
        NSString *needle = pos.count ? pos.firstObject : nil;
        if (!needle) {
            noff_emit_json(stdout_fd, noff_json_error(APPS_TOOL_NAME, sub,
                NOFF_ERR_INVALID_ARGS, @"Usage: apple-apps info <bundle-id>"), compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        __block NSArray *raw = @[];
        noff_try_objc(^{ raw = ((ly_msg_arr)objc_msgSend)(ws, sel_registerName("allInstalledApplications")); });

        NSDictionary *found = nil;
        for (id proxy in raw) {
            NSString *bid = ly_proxy_get(proxy, "bundleIdentifier");
            if ([bid isEqualToString:needle] ||
                [bid.lowercaseString isEqualToString:needle.lowercaseString]) {
                found = ly_app_record(proxy, YES);
                break;
            }
        }
        if (!found) {
            noff_emit_json(stdout_fd, noff_json_error(APPS_TOOL_NAME, sub, NOFF_ERR_NO_DATA,
                [NSString stringWithFormat:@"No installed app matches '%@'", needle]), compact, quiet);
            return NOFF_EXIT_ERROR;
        }
        noff_emit_json(stdout_fd, noff_json_envelope(APPS_TOOL_NAME, sub, found), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    // ---- frontmost ----
    if ([sub isEqualToString:@"frontmost"]) {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSDictionary *data = @{
            @"bundle_id": bid,
            @"note": @"in-process bundle id; SpringBoard-visible foreground app is not readable from a sandboxed process",
        };
        noff_emit_json(stdout_fd, noff_json_envelope(APPS_TOOL_NAME, @"frontmost", data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    // ---- open ----
    if ([sub isEqualToString:@"open"]) {
        NSArray *pos = noff_positional_args(argc, argv);
        NSString *target = pos.count ? pos.firstObject : nil;
        if (!target) {
            noff_emit_json(stdout_fd, noff_json_error(APPS_TOOL_NAME, @"open",
                NOFF_ERR_INVALID_ARGS, @"Usage: apple-apps open <bundle-id|scheme://|name>"), compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }

        BOOL ok = NO;
        NSString *method = @"none";
        NSString *resolvedBID = nil;

        // (1) 看起来是 URL scheme → 直接让系统打开
        if ([target rangeOfString:@"://"].location != NSNotFound) {
            NSURL *u = [NSURL URLWithString:target];
            if (u) {
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [UIApplication.sharedApplication openURL:u options:@{}
                                           completionHandler:^(BOOL success) {
                        ok = success; dispatch_semaphore_signal(sem);
                    }];
                });
                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
                method = @"ui_application_openurl";
            }
        }

        // (2) bundle id 或 app 名 → 走 LSApplicationWorkspace
        if (!ok) {
            NSString *bid = nil;
            if ([target rangeOfString:@"."].location != NSNotFound) {
                bid = target;                       // 看着像 bundle id
            } else {
                // 按显示名反查
                __block NSArray *raw = @[];
                noff_try_objc(^{ raw = ((ly_msg_arr)objc_msgSend)(ws, sel_registerName("allInstalledApplications")); });
                for (id proxy in raw) {
                    NSString *name = ly_proxy_get(proxy, "localizedName");
                    if ([name isKindOfClass:[NSString class]] &&
                        [name.lowercaseString isEqualToString:target.lowercaseString]) {
                        bid = ly_proxy_get(proxy, "bundleIdentifier");
                        break;
                    }
                }
            }
            if (bid) {
                resolvedBID = bid;
                __block BOOL r = NO;
                noff_try_objc(^{
                    r = ((ly_msg_bool_id)objc_msgSend)(ws, sel_registerName("openApplicationWithBundleID:"), bid);
                });
                if (r) { ok = YES; method = @"lsapplicationworkspace"; }
                else {
                    // 退化：用该 app 的第一个 URL scheme
                    __block NSArray *raw2 = @[];
                    noff_try_objc(^{ raw2 = ((ly_msg_arr)objc_msgSend)(ws, sel_registerName("allInstalledApplications")); });
                    for (id proxy in raw2) {
                        NSString *b = ly_proxy_get(proxy, "bundleIdentifier");
                        if (![b isEqualToString:bid]) continue;
                        NSArray *schemes = ly_proxy_schemes(proxy);
                        if (schemes.count) {
                            NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", schemes.firstObject]];
                            if (u) {
                                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [UIApplication.sharedApplication openURL:u options:@{}
                                                           completionHandler:^(BOOL s2) {
                                        ok = s2; dispatch_semaphore_signal(sem);
                                    }];
                                });
                                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
                                if (ok) method = @"url_scheme_fallback";
                            }
                        }
                        break;
                    }
                }
            }
        }

        NSMutableDictionary *data = [NSMutableDictionary dictionary];
        data[@"target"] = target;
        data[@"opened"] = @(ok);
        data[@"method"] = method;
        if (resolvedBID) data[@"bundle_id"] = resolvedBID;

        if (!ok) {
            noff_emit_json(stdout_fd, noff_json_error(APPS_TOOL_NAME, @"open", NOFF_ERR_NO_DATA,
                [NSString stringWithFormat:@"Could not open '%@' — bundle id not found or app has no launchable scheme.", target]),
                compact, quiet);
            return NOFF_EXIT_ERROR;
        }
        noff_emit_json(stdout_fd, noff_json_envelope(APPS_TOOL_NAME, @"open", data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    noff_emit_json(stdout_fd, noff_json_error(APPS_TOOL_NAME, sub, NOFF_ERR_INVALID_ARGS,
        [NSString stringWithFormat:@"Unknown subcommand '%@'. Use --help.", sub]), compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void apps_offload_register(void) {
    int err = native_offload_add_handler("apple-apps", apps_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-apps");
        NSLog(@"NativeOffloads: apple-apps handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-apps handler (err=%d)", err);
    }
}
