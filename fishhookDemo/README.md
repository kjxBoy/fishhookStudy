# fishhook Demo 工程说明

## 什么是 fishhook

fishhook 是 Facebook 开源的一个轻量级 C 库，能够在 iOS 模拟器和真机上**动态替换 Mach-O 二进制文件中的符号**，其原理类似于 macOS 上的 `DYLD_INTERPOSE`。

它的核心 API 只有两个函数：

```c
// 对当前进程所有镜像（及后续动态加载的镜像）执行符号重绑定
int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

// 仅对指定的单个镜像执行符号重绑定（一次性，不注册全局回调）
int rebind_symbols_image(void *header, intptr_t slide,
                         struct rebinding rebindings[], size_t rebindings_nel);
```

每次 hook 只需填写一个 `rebinding` 结构体，描述"把哪个符号替换成什么，以及把原始实现保存到哪里"：

```c
struct rebinding {
    const char *name;      // 要 hook 的符号名（不含前导下划线）
    void       *replacement;  // 替换函数指针
    void      **replaced;     // 接收原始函数指针（用于调用链延续）
};
```

---

## 工作原理

`dyld` 通过修改 Mach-O `__DATA` 段中的函数指针来完成符号绑定。fishhook 的做法是：

1. 遍历镜像的 Load Commands，找到 `__LINKEDIT` 段、`LC_SYMTAB`、`LC_DYSYMTAB`；
2. 根据 `__LINKEDIT` 的 `vmaddr - fileoff + slide` 计算出符号表、字符串表、间接符号表的运行时地址；
3. 再次遍历 Load Commands，在 `__DATA` 和 `__DATA_CONST` 段中找到懒加载（`__la_symbol_ptr`）和非懒加载（`__nl_symbol_ptr`）符号指针节区；
4. 对每个指针槽位，通过"间接符号表 → 符号表 → 字符串表"三层索引还原符号名，与目标名称比对，命中后调用 `vm_protect` 解除写保护并写入新的函数指针。

查找流程如下图：

![原理示意图](http://i.imgur.com/HVXqHCz.png)

> **只能 hook 外部符号（C 函数、动态库导入函数）**，ObjC 方法走 `objc_msgSend` 分发，不经过 GOT，无法用 fishhook 直接拦截。

---

## Demo 工程结构

```
fishhookDemo/fishhookDemo/
├── fishhook.h / fishhook.c      核心库源文件
├── Demos/
│   ├── FHNSLogHook.h / .m       Demo 1：NSLog 拦截
│   ├── FHMallocHook.h / .m      Demo 2：malloc/free 计数
│   └── FHFileHook.h / .m        Demo 3：文件操作追踪
└── ViewController.m             主界面（UITableView + 日志控制台）
```

---

## 三个 Demo 场景

### Demo 1 — NSLog 拦截（FHNSLogHook）

**Hook 目标**：`NSLogv(NSString *format, va_list args)`

`NSLog` 是可变参数函数，C 语言无法将 `va_list` 透传给另一个可变参数函数，因此选择 hook 其内部实际调用的 `NSLogv`。开启后，进程内**所有** NSLog 输出（包括系统框架内的）都会被拦截，在日志前追加 `[🪝 HOOK]` 前缀和时间戳。

```objc
[FHNSLogHook enable];   // 开启
[FHNSLogHook disable];  // 关闭，恢复原始行为
```

---

### Demo 2 — malloc/free 计数（FHMallocHook）

**Hook 目标**：`malloc(size_t)` / `free(void *)`

`malloc` 在系统内部被极高频调用，Hook 实现中**严禁做任何触发内存分配的操作**（如 `NSLog`、创建 `NSString`），否则会无限递归。本 Demo 使用两个技术手段保证安全：

- `atomic_fetch_add`：无锁原子计数，多线程安全；
- `__thread` 线程局部重入标志：检测并阻断同一线程内的递归调用。

```objc
[FHMallocHook enable];        // 开启并清零计数器
[FHMallocHook triggerSnapshot]; // 上报当前 malloc/free 次数及差值
[FHMallocHook disable];       // 关闭
```

---

### Demo 3 — 文件操作追踪（FHFileHook）

**Hook 目标**：`open(const char *, int, ...)` / `close(int)`

`open` 是可变参数函数，第三个参数 `mode_t` 仅在 `O_CREAT` 标志存在时有意义，需用 `va_list` 正确透传，否则栈帧错乱。默认只上报路径包含 App 沙盒标识（`/Containers/`、`/Documents/` 等）的文件，避免系统文件噪音刷屏。

```objc
[FHFileHook enable];                         // 开启
[FHFileHook setFilterAppSandboxOnly:NO];     // 关闭过滤，查看全量操作
[FHFileHook triggerTestFileOperation];       // 在 Documents 创建临时文件触发演示
[FHFileHook disable];                        // 关闭
```

---

## 使用注意事项

| 限制 | 说明 |
|---|---|
| 仅限外部 C 符号 | 只能 hook 经过 GOT/PLT 的动态绑定符号，静态内联函数无效 |
| 重复调用叠加 | 多次调用 `rebind_symbols` 的规则会叠加，后注册的优先生效 |
| 恢复方式 | 将 `replacement` 改回 `orig_xxx` 再次调用 `rebind_symbols` 即可还原 |
| malloc hook 重入 | hook 内部严禁触发内存分配，必须使用线程局部变量防重入 |
| __DATA_CONST 写保护 | iOS 12+ 对该段施加写保护，必须在写入前调用 `vm_protect` 解除 |
