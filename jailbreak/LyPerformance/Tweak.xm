#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <os/log.h>
#include <os/proc.h>

static os_log_t lyLog;
static dispatch_source_t lyPressureSource;

static NSString *LyCacheDirectory(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: @"";
}

static void LyTrimOwnCaches(void) {
    NSString *root = LyCacheDirectory();
    if (root.length == 0) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:root error:&error];
    if (!items) return;
    NSUInteger removed = 0;
    for (NSString *item in items) {
        // Conservative: only remove known disposable cache buckets.
        if (![item hasPrefix:@"ly-"] && ![item isEqualToString:@"URLCache"] && ![item isEqualToString:@"WebKit"])
            continue;
        NSString *path = [root stringByAppendingPathComponent:item];
        if ([fm removeItemAtPath:path error:nil]) removed++;
    }
    os_log(lyLog, "trimmed own caches: %{public}lu", (unsigned long)removed);
}

static void LyInstallMonitors(void) {
    lyLog = os_log_create("com.ly.minis", "performance");
    NSProcessInfo *pi = NSProcessInfo.processInfo;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        os_log(lyLog, "memory warning; trimming own caches");
        LyTrimOwnCaches();
    }];
    lyPressureSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(lyPressureSource, ^{
        unsigned long data = dispatch_source_get_data(lyPressureSource);
        os_log(lyLog, "memory pressure event: %lu, available=%lluMB, thermal=%ld", data, os_proc_available_memory() / (1024ULL * 1024ULL), (long)pi.thermalState);
        if (data & (DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL)) LyTrimOwnCaches();
    });
    dispatch_resume(lyPressureSource);
}

%ctor {
    @autoreleasepool {
        LyInstallMonitors();
    }
}
