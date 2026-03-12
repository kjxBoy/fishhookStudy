//
//  FHFileHook.h
//  fishhookDemo
//
//  文件操作追踪演示：
//  通过 fishhook Hook POSIX `open` 和 `close` 系统调用，
//  实时记录 App 打开和关闭的文件路径及文件描述符（fd）。
//
//  为避免系统噪音，默认只上报路径包含 App 沙盒目录或 Documents/tmp 的文件，
//  可通过 filterAppSandboxOnly 关闭过滤以查看全量文件操作。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FHFileHook : NSObject

/// 当前 hook 是否已启用
@property (class, nonatomic, readonly) BOOL isEnabled;

/// 是否仅上报 App 沙盒内的文件（默认 YES，减少系统路径噪音）
@property (class, nonatomic, assign) BOOL filterAppSandboxOnly;

/**
 * 启用文件操作追踪 Hook。
 */
+ (void)enable;

/**
 * 禁用 Hook，恢复原始 open/close。
 */
+ (void)disable;

/**
 * 日志回调，每次捕获到 open/close 操作时在主线程触发。
 */
@property (class, nonatomic, copy, nullable) void (^logHandler)(NSString *log);

/**
 * 触发一次测试：在 Documents 目录创建并读取一个临时文件，验证 Hook 生效。
 */
+ (void)triggerTestFileOperation;

@end

NS_ASSUME_NONNULL_END
