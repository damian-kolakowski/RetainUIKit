// Copyright (c) 2013, Facebook, Inc.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//   * Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//   * Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//   * Neither the name Facebook nor the names of its contributors may be used
//     to endorse or promote products derived from this software without
//     specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#include "fishhook.h"

#include <dlfcn.h>
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

#ifdef __LP64__
typedef struct mach_header_64     mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64         section_t;
typedef struct nlist_64           nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header        mach_header_t;
typedef struct segment_command    segment_command_t;
typedef struct section            section_t;
typedef struct nlist              nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif

struct rebindings_entry {
    struct rebinding        *rebindings;
    size_t                   rebindings_nel;
    struct rebindings_entry *next;
};

static struct rebindings_entry *_rebindings_head = NULL;

static int prepend_rebindings(struct rebindings_entry **head,
                               struct rebinding rebindings[],
                               size_t nel) {
    struct rebindings_entry *entry = malloc(sizeof(*entry));
    if (!entry) return -1;
    entry->rebindings = malloc(sizeof(struct rebinding) * nel);
    if (!entry->rebindings) { free(entry); return -1; }
    memcpy(entry->rebindings, rebindings, sizeof(struct rebinding) * nel);
    entry->rebindings_nel = nel;
    entry->next = *head;
    *head = entry;
    return 0;
}

static vm_prot_t get_protection(void *addr) {
    mach_port_t task = mach_task_self();
    vm_address_t address = (vm_address_t)addr;
    vm_size_t size = 0;
    memory_object_name_t object;
#if __LP64__
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    vm_region_basic_info_data_64_t info;
    kern_return_t kr = vm_region_64(task, &address, &size,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_64_t)&info, &count, &object);
#else
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT;
    vm_region_basic_info_data_t info;
    kern_return_t kr = vm_region(task, &address, &size,
                                 VM_REGION_BASIC_INFO,
                                 (vm_region_info_t)&info, &count, &object);
#endif
    if (kr != KERN_SUCCESS) return VM_PROT_READ;
    return info.protection;
}

static void perform_rebinding_with_section(struct rebindings_entry *rebindings,
                                           section_t *section,
                                           intptr_t slide,
                                           nlist_t *symtab,
                                           char *strtab,
                                           uint32_t *indirect_symtab) {
    uint32_t *indirect_symbol_indices  = indirect_symtab + section->reserved1;
    void    **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);

    // Query the current protection of this page.  On modern iOS, __DATA_CONST
    // is read-only and mprotect() cannot override kernel-enforced protection.
    // vm_protect() with VM_PROT_COPY triggers a copy-on-write fault first,
    // making the page privately writable.  We apply this to every section so
    // a crash can't happen even if a regular __DATA page is unexpectedly RO.
    vm_prot_t old_prot = get_protection(indirect_symbol_bindings);
    bool made_writable = false;
    if (!(old_prot & VM_PROT_WRITE)) {
        kern_return_t kr = vm_protect(mach_task_self(),
                                      (vm_address_t)indirect_symbol_bindings,
                                      section->size,
                                      false,
                                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) return;   // can't make writable — skip section
        made_writable = true;
    }

    for (uint32_t i = 0; i < section->size / sizeof(void *); i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS ||
            symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }
        char *symbol_name = strtab + symtab[symtab_index].n_un.n_strx;
        if (!symbol_name[0] || !symbol_name[1]) continue;

        for (struct rebindings_entry *cur = rebindings; cur; cur = cur->next) {
            for (size_t j = 0; j < cur->rebindings_nel; j++) {
                if (strcmp(&symbol_name[1], cur->rebindings[j].name) == 0) {
                    if (cur->rebindings[j].replaced &&
                        indirect_symbol_bindings[i] != cur->rebindings[j].replacement) {
                        *(cur->rebindings[j].replaced) = indirect_symbol_bindings[i];
                    }
                    indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
                    goto next_symbol;
                }
            }
        }
    next_symbol:;
    }

    // Restore original protection.
    if (made_writable) {
        vm_protect(mach_task_self(),
                   (vm_address_t)indirect_symbol_bindings,
                   section->size,
                   false,
                   old_prot);
    }
}

static void rebind_symbols_for_image(struct rebindings_entry *rebindings,
                                     const struct mach_header *header,
                                     intptr_t slide) {
    Dl_info info;
    if (dladdr(header, &info) == 0) return;

    segment_command_t *seg = NULL;
    segment_command_t *linkedit_segment = NULL;
    struct symtab_command    *symtab_cmd   = NULL;
    struct dysymtab_command  *dysymtab_cmd = NULL;

    uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++, cur += seg->cmdsize) {
        seg = (segment_command_t *)cur;
        if (seg->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strncmp(seg->segname, SEG_LINKEDIT, sizeof(seg->segname)) == 0)
                linkedit_segment = seg;
        } else if (seg->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)seg;
        } else if (seg->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command *)seg;
        }
    }

    if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment ||
        !dysymtab_cmd->nindirectsyms) return;

    uintptr_t linkedit_base = (uintptr_t)slide +
        linkedit_segment->vmaddr - linkedit_segment->fileoff;
    nlist_t  *symtab          = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
    char     *strtab          = (char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++, cur += seg->cmdsize) {
        seg = (segment_command_t *)cur;
        if (seg->cmd != LC_SEGMENT_ARCH_DEPENDENT) continue;
        if (strncmp(seg->segname, SEG_DATA,       sizeof(seg->segname)) != 0 &&
            strncmp(seg->segname, SEG_DATA_CONST,  sizeof(seg->segname)) != 0) continue;
        for (uint32_t j = 0; j < seg->nsects; j++) {
            section_t *sect =
                (section_t *)((uintptr_t)seg + sizeof(segment_command_t)) + j;
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS ||
                type == S_NON_LAZY_SYMBOL_POINTERS) {
                perform_rebinding_with_section(rebindings, sect, slide,
                                               symtab, strtab, indirect_symtab);
            }
        }
    }
}

static void _rebind_symbols_for_image(const struct mach_header *header,
                                      intptr_t slide) {
    rebind_symbols_for_image(_rebindings_head, header, slide);
}

int rebind_symbols_image(void *header, intptr_t slide,
                         struct rebinding rebindings[], size_t nel) {
    struct rebindings_entry *head = NULL;
    int ret = prepend_rebindings(&head, rebindings, nel);
    if (ret < 0) return ret;
    rebind_symbols_for_image(head, (const struct mach_header *)header, slide);
    free(head->rebindings);
    free(head);
    return ret;
}

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
    int ret = prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
    if (ret < 0) return ret;
    if (!_rebindings_head->next) {
        _dyld_register_func_for_add_image(_rebind_symbols_for_image);
    } else {
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            _rebind_symbols_for_image(_dyld_get_image_header(i),
                                      _dyld_get_image_vmaddr_slide(i));
        }
    }
    return ret;
}
