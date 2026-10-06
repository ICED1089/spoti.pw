#import <Foundation/Foundation.h>
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

static BOOL sameExecutablePath(const char *imageName, NSString *guestPath) {
    if (!imageName || !guestPath.length) return NO;
    NSString *image = [NSString stringWithUTF8String:imageName];
    if (!image.length) return NO;

    // LiveContainer may differ only by /private or another path-normalisation detail.
    NSString *a = image.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *b = guestPath.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if ([a isEqualToString:b]) return YES;

    // Keep a conservative fallback for LiveContainer's guest bundle path spelling.
    return [image.lastPathComponent isEqualToString:guestPath.lastPathComponent] &&
           [image.stringByDeletingLastPathComponent.lastPathComponent
               isEqualToString:guestPath.stringByDeletingLastPathComponent.lastPathComponent];
}

static const struct mach_header_64 *mainExecutable(intptr_t *slide) {
    // LiveContainer replaces NSBundle.mainBundle with the guest app's bundle. Unlike the process'
    // MH_EXECUTE image, this therefore names Spotify itself. Match that exact guest executable
    // against the loaded-image list instead of relying on LiveContainer's dyld/dlsym hooks: an
    // injected tweak can bypass those hooks and otherwise see the LiveContainer host.
    NSString *guestPath = NSBundle.mainBundle.executablePath;
    SGLog(@"rebind: guest executable path %@", guestPath ?: @"(unavailable)");

    if (guestPath.length) {
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const struct mach_header *candidate = _dyld_get_image_header(i);
            const char *name = _dyld_get_image_name(i);
            if (!candidate || candidate->magic != MH_MAGIC_64 || !sameExecutablePath(name, guestPath)) continue;
            *slide = _dyld_get_image_vmaddr_slide(i);
            SGLog(@"rebind: selected guest image %s, filetype %u", name ?: "unknown", candidate->filetype);
            return (const struct mach_header_64 *)candidate;
        }
        SGLog(@"rebind: guest executable was not found in the visible dyld image list");
    }

    // Normal installs and some loader configurations still make RTLD_MAIN_ONLY useful. Only trust
    // it when dladdr resolves to the guest executable; never silently accept the LiveContainer host.
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)dlsym(RTLD_MAIN_ONLY, "__mh_execute_header");
    if (header && header->magic == MH_MAGIC_64) {
        Dl_info info = {0};
        dladdr(header, &info);
        if (!guestPath.length || sameExecutablePath(info.dli_fname, guestPath)) {
            *slide = slideForHeader(header);
            SGLog(@"rebind: selected main image via RTLD_MAIN_ONLY (%s), filetype %u",
                  info.dli_fname ?: "unknown", header->filetype);
            return header;
        }
        SGLog(@"rebind: rejected RTLD_MAIN_ONLY image %s because it is not the guest executable",
              info.dli_fname ?: "unknown");
    }

    // Final fallback for a conventional process where there is one real executable.
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *candidate = _dyld_get_image_header(i);
        if (!candidate || candidate->magic != MH_MAGIC_64 || candidate->filetype != MH_EXECUTE) continue;
        const char *name = _dyld_get_image_name(i);
        if (guestPath.length && !sameExecutablePath(name, guestPath)) continue;
        *slide = _dyld_get_image_vmaddr_slide(i);
        SGLog(@"rebind: selected MH_EXECUTE fallback image (%s)", name ?: "unknown");
        return (const struct mach_header_64 *)candidate;
    }
    SGLog(@"rebind: no usable guest executable image found");
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
