//
//  FHFileHook.m
//  fishhookDemo
//

#import "FHFileHook.h"
#import "../fishhook.h"
#include <fcntl.h>
#include <stdarg.h>
#include <unistd.h>

// ─────────────────────────────────────────────────────────────
// 原始函数指针
// ─────────────────────────────────────────────────────────────
static int (*orig_open)(const char *path, int oflag, ...);
static int (*orig_close)(int fd);

// ─────────────────────────────────────────────────────────────
// 全局状态
// ─────────────────────────────────────────────────────────────
static BOOL  g_file_hook_enabled = NO;
static BOOL  g_filter_sandbox    = YES;
static void (^g_file_log_handler)(NSString *) = nil;

// 重入保护：防止在 hook 内部调用 NSLog/open 时再次触发
static __thread BOOL g_in_file_hook = NO;

// ─────────────────────────────────────────────────────────────
// 内部工具：安全地向主线程分发日志（不分配 ObjC 对象的快速路径）
// ─────────────────────────────────────────────────────────────
static void dispatch_log(const char *prefix, const char *path, int fd) {
    if (!g_file_log_handler || g_in_file_hook) return;

    // 在当前线程（可能是非主线程）构造 NSString，然后派发到主线程回调
    g_in_file_hook = YES;
    NSString *pathStr = path ? @(path) : @"(null)";
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *ts = [fmt stringFromDate:[NSDate date]];
    NSString *log = [NSString stringWithFormat:@"[📁 File][%@] %s | fd=%d | %@",
                     ts, prefix, fd, pathStr];
    g_in_file_hook = NO;

    void (^handler)(NSString *) = g_file_log_handler;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(log);
    });
}

// ─────────────────────────────────────────────────────────────
// 过滤：是否应该上报该路径
// ─────────────────────────────────────────────────────────────
static BOOL should_report(const char *path) {
    if (!path) return NO;
    if (!g_filter_sandbox) return YES;

    // 只上报路径含有 App 沙盒标识字符串的文件
    // 典型路径：/var/mobile/Containers/Data/Application/<UUID>/...
    return strstr(path, "/Containers/") != NULL
        || strstr(path, "/Documents/")  != NULL
        || strstr(path, "/tmp/")        != NULL
        || strstr(path, "/Library/")    != NULL;
}

// ─────────────────────────────────────────────────────────────
// 替换函数
// ─────────────────────────────────────────────────────────────

static int my_open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    // open 的第三个参数 mode 仅在 O_CREAT 标志存在时有意义
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = va_arg(ap, int);
        va_end(ap);
    }

    int fd = (oflag & O_CREAT) ? orig_open(path, oflag, mode) : orig_open(path, oflag);

    if (should_report(path)) {
        dispatch_log("open ", path, fd);
    }
    return fd;
}

static int my_close(int fd) {
    int ret = orig_close(fd);

    // close 时无法再拿到路径，仅记录 fd
    if (!g_in_file_hook && g_file_log_handler) {
        g_in_file_hook = YES;
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
        NSString *ts = [fmt stringFromDate:[NSDate date]];
        NSString *log = [NSString stringWithFormat:@"[📁 File][%@] close | fd=%d | ret=%d", ts, fd, ret];
        g_in_file_hook = NO;

        // close 调用极为频繁，仅在过滤关闭时才记录，避免日志刷屏
        if (!g_filter_sandbox) {
            void (^handler)(NSString *) = g_file_log_handler;
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(log);
            });
        }
    }
    return ret;
}

// ─────────────────────────────────────────────────────────────
// 实现
// ─────────────────────────────────────────────────────────────
@implementation FHFileHook

+ (BOOL)isEnabled {
    return g_file_hook_enabled;
}

+ (BOOL)filterAppSandboxOnly {
    return g_filter_sandbox;
}

+ (void)setFilterAppSandboxOnly:(BOOL)filter {
    g_filter_sandbox = filter;
}

+ (void (^)(NSString *))logHandler {
    return g_file_log_handler;
}

+ (void)setLogHandler:(void (^)(NSString *))logHandler {
    g_file_log_handler = [logHandler copy];
}

+ (void)enable {
    if (g_file_hook_enabled) return;

    rebind_symbols((struct rebinding[]){
        {"open",  my_open,  (void **)&orig_open },
        {"close", my_close, (void **)&orig_close},
    }, 2);

    g_file_hook_enabled = YES;
    NSLog(@"[FHFileHook] open/close Hook 已启用 ✅（仅沙盒路径过滤: %@）",
          g_filter_sandbox ? @"ON" : @"OFF");
}

+ (void)disable {
    if (!g_file_hook_enabled) return;

    if (orig_open) {
        rebind_symbols((struct rebinding[]){
            {"open",  orig_open,  (void **)&orig_open },
            {"close", orig_close, (void **)&orig_close},
        }, 2);
    }

    g_file_hook_enabled = NO;
    NSLog(@"[FHFileHook] open/close Hook 已禁用 ❌");
}

+ (void)triggerTestFileOperation {
    // 在 Documents 目录创建临时测试文件，触发 open/close hook
    NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *testPath = [docDir stringByAppendingPathComponent:@"fishhook_test.txt"];
    const char *cPath = testPath.UTF8String;

    // 写入
    int fd = open(cPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        const char *content = "fishhook open/close hook test\n";
        write(fd, content, strlen(content));
        close(fd);
    }

    // 读取
    fd = open(cPath, O_RDONLY);
    if (fd >= 0) {
        char buf[64] = {0};
        read(fd, buf, sizeof(buf) - 1);
        close(fd);
        NSLog(@"[FHFileHook] 测试文件内容: %s", buf);
    }

    // 清理
    unlink(cPath);
}

@end
