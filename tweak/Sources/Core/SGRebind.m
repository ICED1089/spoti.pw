#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <string.h>
#import <dlfcn.h>
#import "SGRebind.h"
#import "SGLog.h"

static intptr_t slideForHeader(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return 0;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++,
         command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        if (strcmp(segment->segname, SEG_TEXT) == 0)
            return (intptr_t)header - (intptr_t)segment->vmaddr;
    }
    return 0;
}

static const struct mach_header_64 *mainExecutable(intptr_t *slide) {
    // Normal sideloads expose Spotify as the process' MH_EXECUTE image. LiveContainer instead
    // converts the guest executable to MH_DYLIB and dlopens it inside the LiveContainer host.
    // LiveContainer deliberately redirects dlsym(RTLD_MAIN_ONLY, "__mh_execute_header") to the
    // guest app's real Mach-O header, so ask for that first. This also works on a normal install.
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)dlsym(RTLD_MAIN_ONLY, "__mh_execute_header");
    if (header && header->magic == MH_MAGIC_64) {
        *slide = slideForHeader(header);
        Dl_info info = {0};
        dladdr(header, &info);
        SGLog(@"rebind: selected main image via RTLD_MAIN_ONLY (%s), filetype %u",
              info.dli_fname ?: "unknown", header->filetype);
        return header;
    }

    // Fallback for environments where RTLD_MAIN_ONLY does not expose __mh_execute_header.
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *candidate = _dyld_get_image_header(i);
        if (!candidate || candidate->magic != MH_MAGIC_64 || candidate->filetype != MH_EXECUTE) continue;
        *slide = _dyld_get_image_vmaddr_slide(i);
        Dl_info info = {0};
        dladdr(candidate, &info);
        SGLog(@"rebind: selected MH_EXECUTE fallback image (%s)", info.dli_fname ?: "unknown");
        return (const struct mach_header_64 *)candidate;
    }
    SGLog(@"rebind: no usable main executable image found");
    return NULL;
}

// Writes one pointer, making its page writable first; a page dyld made read only after binding
// (__DATA_CONST, __AUTH_CONST) is copied and made read only again.
static BOOL writeSlot(void **slot, void *value, BOOL readOnly) {
    vm_size_t page = vm_page_size;
    vm_address_t start = (vm_address_t)slot & ~(page - 1);
    kern_return_t result = vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (result != KERN_SUCCESS) {
        SGLog(@"rebind: vm_protect failed (%d)", result);
        return NO;
    }
    *slot = value;
    if (readOnly) vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ);
    return YES;
}

BOOL SGRebindImport(const char *symbol, void *replacement, void **original) {
    intptr_t slide = 0;
    const struct mach_header_64 *header = mainExecutable(&slide);
    if (!header) {
        SGLog(@"rebind: %s failed because the main image was unavailable", symbol);
        return NO;
    }

    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT) == 0) {
            linkedit = (const struct segment_command_64 *)command;
        } else if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)command;
        }
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) {
        SGLog(@"rebind: %s failed because classic symbol metadata was unavailable", symbol);
        return NO;
    }

    uintptr_t base = (uintptr_t)slide + (uintptr_t)(linkedit->vmaddr - linkedit->fileoff);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    // The symbol's index once, among the undefined ones, rather than a name compared per slot.
    uint32_t wanted = UINT32_MAX;
    for (uint32_t i = dysymtab->iundefsym; i < dysymtab->iundefsym + dysymtab->nundefsym && i < symtab->nsyms; i++) {
        uint32_t offset = symbols[i].n_un.n_strx;
        if (offset >= symtab->strsize) continue;
        const char *name = strings + offset;
        if (name[0] == '_' && strcmp(name + 1, symbol) == 0) {
            wanted = i;
            break;
        }
    }
    if (wanted == UINT32_MAX) {
        SGLog(@"rebind: %s is not an undefined import of the selected image", symbol);
        return NO;
    }

    BOOL rebound = NO;
    command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        BOOL readOnly = strcmp(segment->segname, "__DATA_CONST") == 0 || strcmp(segment->segname, "__AUTH_CONST") == 0;
        const struct section_64 *section = (const struct section_64 *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
            void **slots = (void **)((uintptr_t)slide + section->addr);
            uint64_t count = section->size / sizeof(void *);
            for (uint64_t k = 0; k < count; k++) {
                uint64_t entry = (uint64_t)section->reserved1 + k;
                if (entry >= dysymtab->nindirectsyms || indirect[entry] != wanted) continue;
                if (slots[k] == replacement) continue;
                void *held = slots[k];
                if (!writeSlot(&slots[k], replacement, readOnly)) continue;
                if (original && !*original) *original = held;
                rebound = YES;
            }
        }
    }
    SGLog(@"rebind: %s %@", symbol, rebound ? @"rebound" : @"import found but no patchable slot found");
    return rebound;
}
