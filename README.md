# fishhook

__fishhook__ 是一个非常简单的库，能够在 iOS 模拟器和真机上运行的 Mach-O 二进制文件中动态地重新绑定符号。其功能类似于在 macOS 上使用 [`DYLD_INTERPOSE`][interpose]。在 Facebook 内部，我们发现它非常适合用于调试和追踪目的，例如 hook libSystem 中的调用（比如审计文件描述符的双重关闭问题）。

[interpose]: http://opensource.apple.com/source/dyld/dyld-210.2.3/include/mach-o/dyld-interposing.h "<mach-o/dyld-interposing.h>"

## 使用方法

将 `fishhook.h` 和 `fishhook.c` 添加到你的项目后，即可按如下方式重新绑定符号：

```Objective-C
#import <dlfcn.h>

#import <UIKit/UIKit.h>

#import "AppDelegate.h"
#import "fishhook.h"
 
static int (*orig_close)(int);
static int (*orig_open)(const char *, int, ...);
 
int my_close(int fd) {
  printf("Calling real close(%d)\n", fd);
  return orig_close(fd);
}
 
int my_open(const char *path, int oflag, ...) {
  va_list ap = {0};
  mode_t mode = 0;
 
  if ((oflag & O_CREAT) != 0) {
    // mode 仅在 O_CREAT 时适用
    va_start(ap, oflag);
    mode = va_arg(ap, int);
    va_end(ap);
    printf("Calling real open('%s', %d, %d)\n", path, oflag, mode);
    return orig_open(path, oflag, mode);
  } else {
    printf("Calling real open('%s', %d)\n", path, oflag);
    return orig_open(path, oflag, mode);
  }
}
 
int main(int argc, char * argv[])
{
  @autoreleasepool {
    rebind_symbols((struct rebinding[2]){{"close", my_close, (void *)&orig_close}, {"open", my_open, (void *)&orig_open}}, 2);
 
    // 打开自身的二进制文件并打印前 4 个字节
    // （所有同架构的 Mach-O 二进制文件的魔数相同）
    int fd = open(argv[0], O_RDONLY);
    uint32_t magic_number = 0;
    read(fd, &magic_number, 4);
    printf("Mach-O Magic Number: %x \n", magic_number);
    close(fd);
 
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
```

### 示例输出

```
Calling real open('/var/mobile/Applications/161DA598-5B83-41F5-8A44-675491AF6A2C/Test.app/Test', 0)
Mach-O Magic Number: feedface 
Calling real close(3)
...
```

## 工作原理

`dyld` 通过更新 Mach-O 二进制文件 `__DATA` 段特定节区中的指针来绑定懒加载（lazy）和非懒加载（non-lazy）符号。__fishhook__ 通过确定传入 `rebind_symbols` 的每个符号名称所对应的指针位置，并将其替换为对应的新实现，从而实现符号的重新绑定。

对于一个给定的镜像（image），`__DATA` 段中可能包含两个与动态符号绑定相关的节区：`__nl_symbol_ptr` 和 `__la_symbol_ptr`。`__nl_symbol_ptr` 是一个指向非懒加载数据的指针数组（在库加载时即完成绑定），而 `__la_symbol_ptr` 是一个指向导入函数的指针数组，通常由 `dyld_stub_binder` 在该符号第一次被调用时填充（也可以指定 `dyld` 在启动时绑定这些符号）。

为了找到与某个节区中特定位置对应的符号名称，需要经历多层间接寻址：对于上述两个相关节区，节区头（`<mach-o/loader.h>` 中的 `struct section`）的 `reserved1` 字段提供了一个偏移量，指向所谓的**间接符号表**（indirect symbol table）。间接符号表位于二进制文件的 `__LINKEDIT` 段，它是一个索引数组，指向符号表（同样在 `__LINKEDIT` 中），其顺序与非懒加载和懒加载符号节区中的指针顺序完全对应。

因此，对于 `struct section nl_symbol_ptr`，该节区第一个地址在符号表中对应的索引为 `indirect_symbol_table[nl_symbol_ptr->reserved1]`。符号表本身是一个 `struct nlist` 数组（见 `<mach-o/nlist.h>`），每个 `nlist` 包含一个指向 `__LINKEDIT` 中字符串表的索引，符号的实际名称就存储在那里。

这样，对于 `__nl_symbol_ptr` 和 `__la_symbol_ptr` 中的每一个指针，我们都能找到对应的符号，进而找到对应的字符串与目标符号名进行比较。一旦匹配，就将该节区中的指针替换为新的实现。

在懒加载或非懒加载指针表中查找某个条目名称的完整流程如下所示：

![原理示意图](http://i.imgur.com/HVXqHCz.png)