//
//  FHMallocHook.h
//  fishhookDemo
//
//  malloc/free 计数演示：
//  通过 fishhook Hook `malloc` 和 `free`，使用原子计数器统计调用次数。
//
//  ⚠️ 注意：malloc 在系统内部被极高频调用（UI 渲染、字符串操作等均涉及内存分配），
//  因此 Hook 实现中严禁做任何会触发内存分配的操作（如 NSLog、创建 NSString 等），
//  否则会造成无限递归。本实现使用线程局部变量（__thread）防范重入。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FHMallocHook : NSObject

/// 当前 hook 是否已启用
@property (class, nonatomic, readonly) BOOL isEnabled;

/// 累计 malloc 调用次数（自 enable 起计）
@property (class, nonatomic, readonly) int64_t mallocCount;

/// 累计 free 调用次数（自 enable 起计）
@property (class, nonatomic, readonly) int64_t freeCount;

/**
 * 启用 malloc/free 计数 Hook。
 */
+ (void)enable;

/**
 * 禁用 Hook 并重置计数器。
 */
+ (void)disable;

/**
 * 重置计数器（不改变 hook 状态）。
 */
+ (void)resetCounters;

/**
 * 日志回调，在主线程触发，传入当前统计快照字符串。
 * 调用 triggerSnapshot 时触发一次。
 */
@property (class, nonatomic, copy, nullable) void (^logHandler)(NSString *snapshot);

/**
 * 主动触发一次统计快照回调，将当前 malloc/free 计数上报给 logHandler。
 */
+ (void)triggerSnapshot;

@end

NS_ASSUME_NONNULL_END
