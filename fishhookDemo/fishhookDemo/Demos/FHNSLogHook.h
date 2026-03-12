//
//  FHNSLogHook.h
//  fishhookDemo
//
//  NSLog 拦截演示：
//  通过 fishhook Hook `NSLogv`（NSLog 内部调用的底层函数），
//  在每条日志输出前追加 "[🪝 HOOK]" 前缀和当前时间，
//  同时将日志内容回调给调用方用于 UI 展示。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FHNSLogHook : NSObject

/// 当前 hook 是否已启用
@property (class, nonatomic, readonly) BOOL isEnabled;

/**
 * 启用 NSLog 拦截 Hook。
 * 首次调用后，进程内所有 NSLog 调用均会被拦截。
 * 重复调用无副作用。
 */
+ (void)enable;

/**
 * 禁用 NSLog 拦截 Hook，恢复原始 NSLog 行为。
 * 重复调用无副作用。
 */
+ (void)disable;

/**
 * 日志回调，每次有 NSLog 被拦截时触发，在主线程回调。
 * 传入参数为格式化后的完整日志字符串（含前缀和时间戳）。
 */
@property (class, nonatomic, copy, nullable) void (^logHandler)(NSString *formattedLog);

/**
 * 触发一组测试日志，用于验证 Hook 是否生效。
 */
+ (void)triggerTestLogs;

@end

NS_ASSUME_NONNULL_END
