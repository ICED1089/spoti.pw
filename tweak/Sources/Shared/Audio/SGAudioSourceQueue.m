#import "SGAudioSourceQueue.h"
#import "Core/SGLog.h"
#import <mach/mach.h>
#import <mach-o/dyld.h>
#include <string.h>
#include <stdbool.h>

typedef struct {
    const char *version;
    unsigned char uuid[16];
    uintptr_t callback;
    uintptr_t sinkFunction;
    uintptr_t delegateFunction;
    uint64_t delegateSignature;
    uintptr_t readerFunction;
    uintptr_t nullPath;
    uint64_t nullPathSignature;
    uintptr_t pendingOffset;
} SGAudioSourceLayout;

// These are exact arm64 layouts verified against the Spotify executable UUID, not loose
// version checks. Keep the old 9.1.78 layout as a rollback path and add 9.1.88 explicitly.
static const SGAudioSourceLayout layouts[] = {
    {
        "9.1.78",
        {0xc7,0x12,0x37,0x0b,0x44,0xcd,0x35,0xc8,0xa0,0x58,0x4f,0xbe,0xd1,0xad,0x07,0x58},
        0x24dd98, 0x180f3c, 0x10908b4, UINT64_C(0x17c2d2c2d1002000),
        0x1453c0, 0x1454b4, UINT64_C(0x95ece96591006296), 0xb8
    },
    {
        "9.1.88",
        {0xf5,0x1d,0xbd,0x93,0x3b,0x8f,0x3a,0x12,0x94,0x31,0x96,0xc6,0x06,0xe3,0xaf,0xc2},
        0x76b9e2c, 0x469d678, 0x8bc3370, UINT64_C(0x16efa6b5d1002000),
        0x47ace48, 0x47acf18, UINT64_C(0x955da976b5000169), 0xa8
    },
};
static uintptr_t sg_sourceImage;
static const SGAudioSourceLayout *sg_sourceLayout;
static bool readMetadata(uintptr_t address, void *value, size_t size) {
    vm_size_t count = 0;
    return address && address <= UINTPTR_MAX - size &&
        vm_read_overwrite(mach_task_self(), address, size, (vm_address_t)value, &count) == KERN_SUCCESS && count == size;
}
static bool readWord(uintptr_t address, uint64_t *value) {
    *value = 0;
    return readMetadata(address, value, sizeof *value);
}
void SGAudioSourceQueueInitialize(void) {
    if (sg_sourceLayout) return;
    // LiveContainer's process image can be the host rather than Spotify. Find the loaded image
    // by the exact UUID we verified instead of assuming dyld image zero is the guest executable.
    for (uint32_t image = 0; image < _dyld_image_count(); image++) {
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(image);
        if (!header || header->magic != MH_MAGIC_64) continue;
        const struct load_command *command = (const void *)(header + 1);
        for (uint32_t i = 0; i < header->ncmds; i++,
             command = (const void *)((const char *)command + command->cmdsize)) {
            if (command->cmd != LC_UUID || command->cmdsize != sizeof(struct uuid_command)) continue;
            const unsigned char *uuid = ((const struct uuid_command *)command)->uuid;
            for (unsigned layout = 0; layout < sizeof layouts / sizeof layouts[0]; layout++) {
                if (memcmp(uuid, layouts[layout].uuid, sizeof layouts[layout].uuid)) continue;
                sg_sourceImage = (uintptr_t)header;
                sg_sourceLayout = &layouts[layout];
                SGLog(@"audio source queue: Spotify %s verified layout selected", sg_sourceLayout->version);
                return;
            }
        }
    }
}
bool SGAudioSourceQueueSupported(AURenderCallbackStruct callback) {
    if (!sg_sourceLayout) SGAudioSourceQueueInitialize();
    const SGAudioSourceLayout *layout = sg_sourceLayout;
    uint64_t instruction;
    return layout && (uintptr_t)callback.inputProc == sg_sourceImage + layout->callback &&
        readWord((uintptr_t)callback.inputProc, &instruction) && instruction == UINT64_C(0xa9bc5ff8350005a3);
}
SGAudioSourcePrefix SGAudioSourceQueuePrefix(AURenderCallbackStruct callback, UInt32 maximumFrames, bool continuous) {
    const SGAudioSourcePrefix empty = {0, UINT32_MAX};
    if (!maximumFrames || !SGAudioSourceQueueSupported(callback)) return empty;
    const SGAudioSourceLayout *layout = sg_sourceLayout;
    uintptr_t context = (uintptr_t)callback.inputProcRefCon;
    uint64_t instruction, sink, table, function, delegate;
    uint64_t contextWords[5], sinkWords[5];
    // Adjacent metadata fields share one checked copy. Do not repeat kernel reads for
    // each word of the same source context, sink or queue node on every audio callback.
    if (!context || context > UINTPTR_MAX - 0x90 ||
        !readWord((uintptr_t)callback.inputProc, &instruction) || instruction != UINT64_C(0xa9bc5ff8350005a3) ||
        !readMetadata(context + 0x68, contextWords, sizeof contextWords)) return empty;
    sink = contextWords[2];
    if ((uint32_t)(contextWords[0] >> 32) != 2 || contextWords[4] <= contextWords[3] ||
        !readMetadata(sink, sinkWords, sizeof sinkWords)) return empty;
    table = sinkWords[0]; delegate = sinkWords[4];
    if (table > UINTPTR_MAX - 0x18 ||
        !readWord(table + 0x10, &function) || function != sg_sourceImage + layout->sinkFunction ||
        !readWord(function, &instruction) || instruction != UINT64_C(0xa9025ff8d10183ff) ||
        delegate < 8 || delegate > UINTPTR_MAX - 0xb8 ||
        !readWord(delegate, &table) || table > UINTPTR_MAX - 0x18 ||
        !readWord(table + 0x10, &function) || function != sg_sourceImage + layout->delegateFunction ||
        !readWord(function, &instruction) || instruction != layout->delegateSignature ||
        !readWord(sg_sourceImage + layout->readerFunction, &instruction) || instruction != UINT64_C(0xa9016ffcd101c3ff)) return empty;
    uintptr_t owner = delegate - 8;
    uint64_t head, tail, pending;
    // The verified reader processes pending commands before consuming its queue.
    // 9.1.88 moved this field from +0xb8 to +0xa8; head/tail and the PCM node shape stayed the same.
    if (!readWord(owner + layout->pendingOffset, &pending) || pending ||
        !readWord(owner + 0x18, &head) || !readWord(owner + 0x20, &tail)) return empty;
    uint64_t cursor = head, samples = 0;
    uint64_t boundary = UINT64_MAX, flags = 0;
    uintptr_t visited[128];
    unsigned count = 0;
    while (cursor != tail) {
        if (count == 128 || !cursor || cursor > UINTPTR_MAX - 0x28) return empty;
        for (unsigned i = 0; i < count; i++) if (visited[i] == cursor) return empty;
        visited[count++] = cursor;
        uint64_t node[5], remaining;
        if (!readMetadata(cursor, node, sizeof node)) return empty;
        uint64_t block = node[0], next = node[4];
        if (next != tail) for (unsigned i = 0; i < count; i++) if (visited[i] == next) return empty;
        if (!block) {
            // The verified null-block path pops one event node and continues unless byte a1 is 1
            // and byte a2 is 0 (Spotify's stop/wait state). Never read PCM directly or invoke
            // the private reader: the original AudioUnit remains the sole source consumer.
            if (!continuous || boundary != UINT64_MAX) break;
            if (!readWord(sg_sourceImage + layout->nullPath, &instruction) || instruction != layout->nullPathSignature ||
                !readWord(owner + 0xa0, &flags)) return empty;
            if (((flags >> 8) & 255) == 1 && !(flags & (UINT64_C(1) << 16))) break;
            boundary = samples / 2;
            cursor = next;
            continue;
        }
        if (block > UINTPTR_MAX - 0x28 || !readWord(block + 0x20, &remaining) ||
            remaining > 882000 || (remaining & 1)) return empty;
        // An exact-sized pull leaves the exhausted block at the head. The verified
        // reader (0x145550–0x1455c8) pops it on the next pull and continues with the
        // following block. Only a null block is an event fence; zero samples are not.
        samples += remaining;
        if (samples / 2 >= maximumFrames) break;
        cursor = next;
    }
    uint64_t headAfter, tailAfter;
    if (!readWord(owner + layout->pendingOffset, &pending) || pending ||
        !readWord(owner + 0x18, &headAfter) || !readWord(owner + 0x20, &tailAfter) ||
        head != headAfter || tail != tailAfter) return empty;
    if (boundary != UINT64_MAX) {
        uint64_t after;
        if (!readWord(owner + 0xa0, &after) || after != flags) return empty;
    }
    // Unvisited nodes cannot affect this prefix. Pending commands and an unstable queue
    // still invalidate the snapshot even when enough frames were found in its first node.
    UInt32 frames = (UInt32)MIN(samples / 2, maximumFrames);
    return (SGAudioSourcePrefix){frames, boundary < frames ? (UInt32)boundary : UINT32_MAX};
}
UInt32 SGAudioSourceQueueFrames(AURenderCallbackStruct callback, UInt32 maximumFrames) {
    return SGAudioSourceQueuePrefix(callback, maximumFrames, false).frames;
}
