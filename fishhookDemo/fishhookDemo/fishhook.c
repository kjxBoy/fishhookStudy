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

#include "fishhook.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

/**
 * 架构自适应类型别名。
 *
 * Mach-O 格式在 32 位和 64 位架构下使用不同的结构体（例如 mach_header vs
 * mach_header_64）。通过统一别名，后续代码无需关心具体位宽，直接使用
 * mach_header_t、segment_command_t 等类型即可跨架构编译。
 *
 * LC_SEGMENT_ARCH_DEPENDENT 同理，是 Load Command 中段命令的架构无关别名。
 */
#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

/**
 * __DATA_CONST 段名称定义。
 *
 * iOS 12+ / macOS 10.14+ 引入了 __DATA_CONST 段，用于存放编译期已知为只读的
 * 指针（如 non-lazy symbol pointers）。系统在加载时对其施加写保护（VM_PROT_READ）。
 * fishhook 需要在写入前通过 vm_protect 主动解除写保护。
 * 旧版 SDK 的头文件中未定义此宏，因此在此处补充定义。
 */
#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST  "__DATA_CONST"
#endif

/**
 * 重绑定条目链表节点。
 *
 * fishhook 将每次 rebind_symbols 调用传入的绑定数组封装为一个链表节点，
 * 并以头插法将其追加到全局链表 _rebindings_head 的前端。
 * 这样，后注册的绑定规则在遍历时会被优先匹配（越新越优先）。
 */
struct rebindings_entry {
  struct rebinding *rebindings;     // 当前节点持有的 rebinding 数组（堆内存，需手动释放）
  size_t rebindings_nel;            // 数组元素个数
  struct rebindings_entry *next;    // 指向前一次调用注册的节点，形成单向链表
};

/**
 * 全局重绑定链表头指针。
 *
 * 进程级单例，保存所有通过 rebind_symbols 注册的绑定规则。
 * 首次为 NULL，每次调用 rebind_symbols 后指向最新插入的节点。
 * 通过判断 _rebindings_head->next 是否为 NULL 可区分"首次调用"和"后续调用"。
 */
static struct rebindings_entry *_rebindings_head;

/**
 * 将新的重绑定条目以头插法追加到链表前端。
 *
 * 新节点会被分配在堆上，并深拷贝 rebindings 数组（避免调用方释放后悬空）。
 * 操作成功后 *rebindings_head 指向新节点。
 *
 * @param rebindings_head 链表头指针的地址（二级指针，用于修改链表头）。
 * @param rebindings      调用方传入的 rebinding 数组。
 * @param nel             数组元素个数。
 * @return 成功返回 0；malloc 失败返回 -1。
 */
static int prepend_rebindings(struct rebindings_entry **rebindings_head,
                              struct rebinding rebindings[],
                              size_t nel) {
  struct rebindings_entry *new_entry = (struct rebindings_entry *) malloc(sizeof(struct rebindings_entry));
  if (!new_entry) {
    return -1;
  }
  new_entry->rebindings = (struct rebinding *) malloc(sizeof(struct rebinding) * nel);
  if (!new_entry->rebindings) {
    free(new_entry);
    return -1;
  }
  memcpy(new_entry->rebindings, rebindings, sizeof(struct rebinding) * nel);
  new_entry->rebindings_nel = nel;
  // 头插：新节点的 next 指向原链表头，然后更新链表头为新节点
  new_entry->next = *rebindings_head;
  *rebindings_head = new_entry;
  return 0;
}

/**
 * [已禁用] 查询指定虚拟地址的内存保护属性。
 *
 * 此函数曾用于在修改 __DATA_CONST 前检查其当前 VM 保护标志，
 * 但由于 vm_region API 在部分 iOS/macOS 版本上返回的保护属性与实际不符，
 * 现已弃用，改为在 perform_rebinding_with_section 中无条件调用 vm_protect 解除写保护。
 */
#if 0
static int get_protection(void *addr, vm_prot_t *prot, vm_prot_t *max_prot) {
  mach_port_t task = mach_task_self();
  vm_size_t size = 0;
  vm_address_t address = (vm_address_t)addr;
  memory_object_name_t object;
#ifdef __LP64__
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  vm_region_basic_info_data_64_t info;
  kern_return_t info_ret = vm_region_64(
      task, &address, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_64_t)&info, &count, &object);
#else
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT;
  vm_region_basic_info_data_t info;
  kern_return_t info_ret = vm_region(task, &address, &size, VM_REGION_BASIC_INFO, (vm_region_info_t)&info, &count, &object);
#endif
  if (info_ret == KERN_SUCCESS) {
    if (prot != NULL)
      *prot = info.protection;

    if (max_prot != NULL)
      *max_prot = info.max_protection;

    return 0;
  }

  return -1;
}
#endif

/**
 * 针对单个 section（__la_symbol_ptr 或 __nl_symbol_ptr）执行符号重绑定的核心逻辑。
 *
 * 算法流程：
 * 1. 通过 section->reserved1 定位该 section 在间接符号表中的起始索引。
 * 2. 遍历该 section 内的每一个函数指针槽位（步长为 sizeof(void*)）：
 *    a. 从间接符号表取出该槽位对应的符号表索引 symtab_index。
 *    b. 跳过绝对符号（INDIRECT_SYMBOL_ABS）和本地符号（INDIRECT_SYMBOL_LOCAL）。
 *    c. 通过符号表找到字符串表偏移，取出符号名。
 *    d. 与全局重绑定链表中的每条规则逐一比较（跳过长度 <= 1 的符号名，
 *       符号名首字节是 '_'，实际比较从第二个字节开始）。
 *    e. 命中时：先保存原始指针到 replaced，再通过 vm_protect 解除写保护，
 *       最后将槽位替换为 replacement。
 *
 * @param rebindings        全局重绑定链表头。
 * @param section           当前处理的节区（懒加载或非懒加载符号指针节区）。
 * @param slide             镜像的 ASLR 滑动偏移量，用于将虚拟地址转换为运行时地址。
 * @param symtab            符号表首地址（nlist_t 数组）。
 * @param strtab            字符串表首地址。
 * @param indirect_symtab   间接符号表首地址（uint32_t 数组）。
 */
static void perform_rebinding_with_section(struct rebindings_entry *rebindings,
                                           section_t *section,
                                           intptr_t slide,
                                           nlist_t *symtab,
                                           char *strtab,
                                           uint32_t *indirect_symtab) {
  // section->reserved1 存储该 section 在间接符号表中的起始偏移（索引）
  uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
  // 将 section 的虚拟地址加上 ASLR slide，得到运行时实际的函数指针数组地址
  void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);

  for (uint i = 0; i < section->size / sizeof(void *); i++) {
    // 取出第 i 个槽位在符号表中的索引
    uint32_t symtab_index = indirect_symbol_indices[i];
    // 跳过绝对符号和本地符号，它们不需要（也无法）被 hook
    if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL ||
        symtab_index == (INDIRECT_SYMBOL_LOCAL   | INDIRECT_SYMBOL_ABS)) {
      continue;
    }
    // 通过符号表找到字符串表偏移，取出完整符号名（含前导 '_'）
    uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
    char *symbol_name = strtab + strtab_offset;
    // 符号名至少需要两个字符（'_' + 至少一个有效字符）才值得比较
    bool symbol_name_longer_than_1 = symbol_name[0] && symbol_name[1];
    struct rebindings_entry *cur = rebindings;
    while (cur) {
      for (uint j = 0; j < cur->rebindings_nel; j++) {
        // 从 symbol_name[1] 开始比较，跳过 Mach-O 符号名的前导下划线 '_'
        if (symbol_name_longer_than_1 && strcmp(&symbol_name[1], cur->rebindings[j].name) == 0) {
          kern_return_t err;

          // 若调用方提供了 replaced 指针，且当前槽位尚未被替换为 replacement，
          // 则先保存原始函数指针，供 hook 实现内部调用原函数使用
          if (cur->rebindings[j].replaced != NULL && indirect_symbol_bindings[i] != cur->rebindings[j].replacement)
            *(cur->rebindings[j].replaced) = indirect_symbol_bindings[i];

          /**
           * 无条件为整个 section 申请写权限（加上 VM_PROT_COPY 以触发写时复制）。
           * 不依赖 get_protection 的查询结果，原因是 vm_region API 在部分
           * iOS/macOS 版本上返回的保护属性与实际不一致（iOS 15 已修正 const 段保护）。
           * -- Lianfu Hao，2021年6月16日
           */
          err = vm_protect (mach_task_self (), (uintptr_t)indirect_symbol_bindings, section->size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
          if (err == KERN_SUCCESS) {
            /**
             * vm_protect 失败时绝对不能继续写入，否则会触发内存访问异常（EXC_BAD_ACCESS）。
             * -- Lionfore Hao，2021年6月11日
             */
            indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
          }
          // 当前槽位已处理完毕，跳出内层链表遍历，继续处理下一个槽位
          goto symbol_loop;
        }
      }
      cur = cur->next;
    }
  symbol_loop:;
  }
}

/**
 * 对单个 Mach-O 镜像执行完整的符号重绑定流程。
 *
 * 步骤：
 * 1. 通过 dladdr 验证 header 的合法性。
 * 2. 第一轮遍历 Load Commands，找到 __LINKEDIT 段、LC_SYMTAB 和 LC_DYSYMTAB。
 * 3. 根据 __LINKEDIT 段的 vmaddr 和 fileoff 以及 slide，计算符号表、字符串表
 *    和间接符号表的运行时地址：
 *      linkedit_base = slide + vmaddr - fileoff
 * 4. 第二轮遍历 Load Commands，在 __DATA 和 __DATA_CONST 段中找到
 *    懒加载符号指针节区（S_LAZY_SYMBOL_POINTERS）和
 *    非懒加载符号指针节区（S_NON_LAZY_SYMBOL_POINTERS），
 *    对每个节区调用 perform_rebinding_with_section 完成实际替换。
 *
 * @param rebindings 重绑定链表头。
 * @param header     目标镜像的 Mach-O 头部指针。
 * @param slide      目标镜像的 ASLR 偏移量。
 */
static void rebind_symbols_for_image(struct rebindings_entry *rebindings,
                                     const struct mach_header *header,
                                     intptr_t slide) {
  Dl_info info;
  // dladdr 无法识别该 header，说明镜像信息异常，直接跳过
  if (dladdr(header, &info) == 0) {
    return;
  }

  segment_command_t *cur_seg_cmd;
  segment_command_t *linkedit_segment = NULL;  // __LINKEDIT 段，包含符号表等元数据
  struct symtab_command* symtab_cmd = NULL;     // LC_SYMTAB：描述符号表和字符串表的位置
  struct dysymtab_command* dysymtab_cmd = NULL; // LC_DYSYMTAB：描述间接符号表的位置

  // 第一轮：从 Mach-O 头部之后开始遍历所有 Load Commands
  uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
  for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_t *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
      if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
        linkedit_segment = cur_seg_cmd;
      }
    } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
      symtab_cmd = (struct symtab_command*)cur_seg_cmd;
    } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
      dysymtab_cmd = (struct dysymtab_command*)cur_seg_cmd;
    }
  }

  // 缺少任意必要结构，或间接符号表为空，则无法完成重绑定
  if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment ||
      !dysymtab_cmd->nindirectsyms) {
    return;
  }

  // 计算 __LINKEDIT 段在内存中的基地址。
  // __LINKEDIT 的 fileoff 是文件偏移，vmaddr 是链接时虚拟地址，
  // 两者之差加上 slide 即可得到运行时的段基地址。
  uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
  // 符号表：nlist_t 数组，每项对应一个符号
  nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
  // 字符串表：存放所有符号名的连续字节区域
  char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
  // 间接符号表：uint32_t 数组，每项是符号表中的索引，与 section 中的指针槽位一一对应
  uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

  // 第二轮：再次遍历 Load Commands，处理 __DATA 和 __DATA_CONST 段中的符号指针节区
  cur = (uintptr_t)header + sizeof(mach_header_t);
  for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_t *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
      // 只处理 __DATA 和 __DATA_CONST 段，其他段不含需要 hook 的函数指针
      if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
          strcmp(cur_seg_cmd->segname, SEG_DATA_CONST) != 0) {
        continue;
      }
      for (uint j = 0; j < cur_seg_cmd->nsects; j++) {
        section_t *sect =
          (section_t *)(cur + sizeof(segment_command_t)) + j;
        // __la_symbol_ptr：懒加载符号指针节区，首次调用时由 dyld_stub_binder 填充
        if ((sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS) {
          perform_rebinding_with_section(rebindings, sect, slide, symtab, strtab, indirect_symtab);
        }
        // __nl_symbol_ptr：非懒加载符号指针节区，库加载时即完成绑定
        if ((sect->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) {
          perform_rebinding_with_section(rebindings, sect, slide, symtab, strtab, indirect_symtab);
        }
      }
    }
  }
}

/**
 * dyld 镜像加载回调的适配器函数。
 *
 * dyld 通过 `_dyld_register_func_for_add_image` 注册的回调签名固定为
 * `void callback(const struct mach_header *header, intptr_t slide)`，
 * 此函数将全局链表头 `_rebindings_head` 作为第一个参数桥接给 rebind_symbols_for_image，
 * 使其与 dyld 回调约定解耦。
 */
static void _rebind_symbols_for_image(const struct mach_header *header,
                                      intptr_t slide) {
    rebind_symbols_for_image(_rebindings_head, header, slide);
}

/**
 * 公开 API：仅对单个镜像执行符号重绑定（一次性，不注册全局回调）。
 *
 * 内部创建一个临时的重绑定链表（不挂载到全局 _rebindings_head），
 * 执行完毕后立即释放，不保留任何全局状态，因此不会影响后续动态加载的库。
 *
 * @param header         目标镜像的 Mach-O 头部指针。
 * @param slide          目标镜像的 ASLR 偏移量。
 * @param rebindings     rebinding 结构体数组。
 * @param rebindings_nel 数组元素个数。
 * @return 成功返回 0，内存分配失败返回 -1。
 */
int rebind_symbols_image(void *header,
                         intptr_t slide,
                         struct rebinding rebindings[],
                         size_t rebindings_nel) {
    struct rebindings_entry *rebindings_head = NULL;
    int retval = prepend_rebindings(&rebindings_head, rebindings, rebindings_nel);
    rebind_symbols_for_image(rebindings_head, (const struct mach_header *) header, slide);
    // 释放临时链表（只有一个节点）
    if (rebindings_head) {
      free(rebindings_head->rebindings);
    }
    free(rebindings_head);
    return retval;
}

/**
 * 公开 API：对当前进程中所有镜像执行符号重绑定，并自动 hook 后续动态加载的镜像。
 *
 * 首次调用时通过 `_dyld_register_func_for_add_image` 注册全局回调：
 * - dyld 会立即对已加载的所有镜像触发一次回调，完成存量 hook。
 * - 后续每次 dlopen 加载新镜像时，dyld 也会自动触发回调，完成增量 hook。
 *
 * 非首次调用时不重复注册回调（避免重复 hook），而是手动遍历当前已加载镜像
 * 并立即执行绑定（新注册的规则对已加载镜像生效）。
 *
 * @param rebindings     rebinding 结构体数组。
 * @param rebindings_nel 数组元素个数。
 * @return 成功返回 0，内存分配失败返回 -1。
 */
int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
  int retval = prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
  if (retval < 0) {
    return retval;
  }
  // _rebindings_head->next 为 NULL 说明这是首次调用，注册 dyld 回调
  // dyld 注册时会立即对所有已加载镜像触发一次回调，存量和增量均被覆盖
  if (!_rebindings_head->next) {
    _dyld_register_func_for_add_image(_rebind_symbols_for_image);
  } else {
    // 非首次调用：仅对当前已加载的镜像执行重绑定，不重复注册 dyld 回调
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
      _rebind_symbols_for_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    }
  }
  return retval;
}
