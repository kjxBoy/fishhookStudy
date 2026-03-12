//
//  FHMallocHook.m
//  fishhookDemo
//

#import "FHMallocHook.h"
#import "../fishhook.h"
#include <stdatomic.h>
#include <stdlib.h>

// ─────────────────────────────────────────────────────────────
// 原始函数指针
// ─────────────────────────────────────────────────────────────
static void *(*orig_malloc)(size_t size);
static void  (*orig_free)(void *ptr);

// ─────────────────────────────────────────────────────────────
// 原子计数器（多线程安全，且不需要锁）
// ─────────────────────────────────────────────────────────────
static atomic_llong g_malloc_count = 0;
static atomic_llong g_free_count   = 0;

// ─────────────────────────────────────────────────────────────
// 线程局部重入标志：防止在 hook 内部触发分配导致无限递归
// 例如：atomic_fetch_add 本身不分配内存，是安全的
// ─────────────────────────────────────────────────────────────
static __thread BOOL g_in_hook = NO;

// ─────────────────────────────────────────────────────────────
// 全局状态
// ─────────────────────────────────────────────────────────────
static BOOL g_malloc_hook_enabled = NO;
static void (^g_malloc_log_handler)(NSString *) = nil;

// ─────────────────────────────────────────────────────────────
// 替换函数
// ─────────────────────────────────────────────────────────────

static void *my_malloc(size_t size) {
    void *ptr = orig_malloc(size);
    // 重入保护：hook 内的任何分配不再计数
    if (!g_in_hook) {
        g_in_hook = YES;
        atomic_fetch_add(&g_malloc_count, 1);
        g_in_hook = NO;
    }
    return ptr;
}

static void my_free(void *ptr) {
    if (!g_in_hook) {
        g_in_hook = YES;
        atomic_fetch_add(&g_free_count, 1);
        g_in_hook = NO;
    }
    orig_free(ptr);
}

// ─────────────────────────────────────────────────────────────
// 实现
// ─────────────────────────────────────────────────────────────
@implementation FHMallocHook

+ (BOOL)isEnabled {
    return g_malloc_hook_enabled;
}

+ (int64_t)mallocCount {
    return (int64_t)atomic_load(&g_malloc_count);
}

+ (int64_t)freeCount {
    return (int64_t)atomic_load(&g_free_count);
}

+ (void (^)(NSString *))logHandler {
    return g_malloc_log_handler;
}

+ (void)setLogHandler:(void (^)(NSString *))logHandler {
    g_malloc_log_handler = [logHandler copy];
}

+ (void)enable {
    if (g_malloc_hook_enabled) return;

    atomic_store(&g_malloc_count, 0);
    atomic_store(&g_free_count, 0);

    rebind_symbols((struct rebinding[]){
        {"malloc", my_malloc, (void **)&orig_malloc},
        {"free",   my_free,   (void **)&orig_free  },
    }, 2);

    g_malloc_hook_enabled = YES;
    NSLog(@"[FHMallocHook] malloc/free Hook 已启用 ✅，计数器已清零");
}

+ (void)disable {
    if (!g_malloc_hook_enabled) return;

    if (orig_malloc) {
        rebind_symbols((struct rebinding[]){
            {"malloc", orig_malloc, (void **)&orig_malloc},
            {"free",   orig_free,   (void **)&orig_free  },
        }, 2);
    }

    g_malloc_hook_enabled = NO;
    NSLog(@"[FHMallocHook] malloc/free Hook 已禁用 ❌ | 本次共 malloc: %lld 次，free: %lld 次",
          (long long)atomic_load(&g_malloc_count),
          (long long)atomic_load(&g_free_count));
}

+ (void)resetCounters {
    atomic_store(&g_malloc_count, 0);
    atomic_store(&g_free_count, 0);
    NSLog(@"[FHMallocHook] 计数器已重置");
}

+ (void)triggerSnapshot {
    int64_t mc = (int64_t)atomic_load(&g_malloc_count);
    int64_t fc = (int64_t)atomic_load(&g_free_count);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *ts = [fmt stringFromDate:[NSDate date]];

    NSString *snapshot = [NSString stringWithFormat:
        @"[📊 malloc][%@] malloc: %lld 次 | free: %lld 次 | 差值(未释放): %lld",
        ts, mc, fc, mc - fc];

    NSLog(@"%@", snapshot);

    if (g_malloc_log_handler) {
        void (^handler)(NSString *) = g_malloc_log_handler;
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(snapshot);
        });
    }
}

@end
