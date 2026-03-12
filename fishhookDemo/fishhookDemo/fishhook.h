// Copyright (c) 2013, Facebook, Inc.
// All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//   * Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//   * Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//   * Neither the name Facebook nor the names of its contributors may be used to
//     endorse or promote products derived from this software without specific
//     prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#ifndef fishhook_h
#define fishhook_h

#include <stddef.h>
#include <stdint.h>

/**
 * 符号可见性控制宏。
 *
 * 默认情况下（未定义 FISHHOOK_EXPORT），fishhook 的公开函数对外隐藏（hidden），
 * 即只在当前编译单元或动态库内部可见，不会暴露到全局符号表，避免与宿主 App 中的
 * 同名符号发生冲突。
 *
 * 若需要将 fishhook 编译为独立动态库并对外导出符号，可在编译时定义 FISHHOOK_EXPORT
 * 宏，此时可见性切换为 default（公开导出）。
 */
#if !defined(FISHHOOK_EXPORT)
#define FISHHOOK_VISIBILITY __attribute__((visibility("hidden")))
#else
#define FISHHOOK_VISIBILITY __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif //__cplusplus

/**
 * 描述一次符号重绑定（hook）的结构体。
 *
 * fishhook 通过修改 Mach-O __DATA 段中的函数指针来实现 hook，
 * 每个 rebinding 描述"把哪个符号替换成什么，同时把原始实现保存到哪里"。
 */
struct rebinding {
  /**
   * 需要 hook 的符号名称（C 字符串，不含前导下划线）。
   * 例如：hook `close` 系统调用时填写 "close"。
   */
  const char *name;

  /**
   * 替换函数的指针（即 hook 实现）。
   * __DATA 段中对应的函数指针将被改写为该值。
   */
  void *replacement;

  /**
   * 用于接收原始函数指针的二级指针（可为 NULL）。
   * hook 生效前，fishhook 会将原始指针写入 *replaced，
   * 以便 hook 实现在内部调用原始函数，形成调用链而非死递归。
   */
  void **replaced;
};

/**
 * 对当前进程中所有已加载镜像（以及后续动态加载的镜像）执行符号重绑定。
 *
 * 该函数会遍历 rebindings 数组中的每一项，将各镜像 __DATA 段（包括
 * __DATA_CONST）中匹配符号名称的函数指针替换为对应的 replacement。
 *
 * 注意事项：
 * - 可多次调用：每次调用的绑定项会追加到全局链表头部，后注册的绑定优先生效。
 * - 首次调用时会通过 `_dyld_register_func_for_add_image` 注册回调，
 *   使后续动态加载的库也能自动被 hook。
 * - 非首次调用时仅对当前已加载镜像重新执行绑定。
 *
 * @param rebindings     rebinding 结构体数组，每项描述一个 hook。
 * @param rebindings_nel rebindings 数组的元素个数。
 * @return 成功返回 0，内存分配失败返回 -1。
 */
FISHHOOK_VISIBILITY
int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

/**
 * 仅对指定的单个 Mach-O 镜像执行符号重绑定，不影响其他镜像，也不注册全局回调。
 *
 * 适用于只想 hook 某一特定库（而非进程中所有镜像）的场景。
 * 与 rebind_symbols 不同，此函数执行完毕后会立即释放临时分配的绑定链表，
 * 不保留全局状态。
 *
 * @param header         目标镜像的 Mach-O 头部指针（mach_header / mach_header_64）。
 * @param slide          目标镜像的 ASLR 偏移量（通过 dyld API 获取）。
 * @param rebindings     rebinding 结构体数组，每项描述一个 hook。
 * @param rebindings_nel rebindings 数组的元素个数。
 * @return 成功返回 0，内存分配失败返回 -1。
 */
FISHHOOK_VISIBILITY
int rebind_symbols_image(void *header,
                         intptr_t slide,
                         struct rebinding rebindings[],
                         size_t rebindings_nel);

#ifdef __cplusplus
}
#endif //__cplusplus

#endif //fishhook_h
