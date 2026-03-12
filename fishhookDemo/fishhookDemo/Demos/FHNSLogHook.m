//
//  FHNSLogHook.m
//  fishhookDemo
//

#import "FHNSLogHook.h"
#import "../fishhook.h"

// ─────────────────────────────────────────────────────────────
// 原始 NSLogv 函数指针（hook 前保存，用于调用链延续）
// NSLog 的可变参数最终通过 NSLogv(NSString*, va_list) 落地输出
// ─────────────────────────────────────────────────────────────
static void (*orig_NSLogv)(NSString *format, va_list args);

// ─────────────────────────────────────────────────────────────
// 全局状态（非原子量，所有修改均在主线程，无需加锁）
// ─────────────────────────────────────────────────────────────
static BOOL         g_nslog_hook_enabled = NO;
static void (^g_nslog_log_handler)(NSString *) = nil;

// ─────────────────────────────────────────────────────────────
// 替换函数：所有 NSLog 调用最终都会走到这里
// ─────────────────────────────────────────────────────────────
static void my_NSLogv(NSString *format, va_list args) {
    // 用 va_list 还原完整日志字符串
    NSString *original = [[NSString alloc] initWithFormat:format arguments:args];

    // 构造带前缀和时间戳的格式化输出
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];
    NSString *decorated = [NSString stringWithFormat:@"[🪝 HOOK][%@] %@", timestamp, original];

    // 调用原始 NSLogv 输出（传入已格式化的字符串，避免二次解析 format 符号）
    orig_NSLogv(@"%@", (va_list){(__bridge void *)decorated});

    // 回调给 UI 展示
    if (g_nslog_log_handler) {
        void (^handler)(NSString *) = g_nslog_log_handler;
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(decorated);
        });
    }
}

// ─────────────────────────────────────────────────────────────
// 实现
// ─────────────────────────────────────────────────────────────
@implementation FHNSLogHook

+ (BOOL)isEnabled {
    return g_nslog_hook_enabled;
}

+ (void (^)(NSString *))logHandler {
    return g_nslog_log_handler;
}

+ (void)setLogHandler:(void (^)(NSString *))logHandler {
    g_nslog_log_handler = [logHandler copy];
}

+ (void)enable {
    if (g_nslog_hook_enabled) return;

    // rebind_symbols 会对当前进程所有已加载镜像执行符号重绑定，
    // 同时注册 dyld 回调，确保后续动态加载的库也被 hook
    rebind_symbols((struct rebinding[]){
        {"NSLogv", my_NSLogv, (void **)&orig_NSLogv}
    }, 1);

    g_nslog_hook_enabled = YES;
    NSLog(@"[FHNSLogHook] NSLog Hook 已启用 ✅");
}

+ (void)disable {
    if (!g_nslog_hook_enabled) return;

    // 将符号重新绑回原始实现，恢复原始行为
    if (orig_NSLogv) {
        rebind_symbols((struct rebinding[]){
            {"NSLogv", orig_NSLogv, (void **)&orig_NSLogv}
        }, 1);
    }

    g_nslog_hook_enabled = NO;
    NSLog(@"[FHNSLogHook] NSLog Hook 已禁用 ❌");
}

+ (void)triggerTestLogs {
    NSLog(@"触发测试：这是第 1 条测试日志");
    NSLog(@"触发测试：当前时间 %@", [NSDate date]);
    NSLog(@"触发测试：来自 %s 的调用", __PRETTY_FUNCTION__);
    NSLog(@"触发测试：Bundle ID = %@", NSBundle.mainBundle.bundleIdentifier);
}

@end
