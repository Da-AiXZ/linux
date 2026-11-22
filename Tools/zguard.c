/*
 * Guarded allocator for the zlib isolation experiment.
 *
 * apk fails while inflating a package stream and the working theory is that
 * zlib's own heap state (inflate_state ~7.2KB, the 32KB window) is being
 * overwritten by a neighbour inside the same musl mallocng group.  zlib lets
 * the build replace its allocator entirely with -DMY_ZCALLOC, so this file
 * gives every zlib allocation its own mapping with the object placed flush
 * against a trailing PROT_NONE page:
 *
 *     [ header page ][ ...... object ...... ][ guard page ]
 *
 * Any write past the end of inflate_state or the window now faults at the
 * writer's pc instead of silently damaging a neighbour.  If the experiment
 * also stops the EIO, the corruption was layout-dependent and this is a
 * usable mitigation.
 */

#include "zconf.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>

#define ZG_PAGE 16384UL
#define ZG_SLOTS 64

typedef struct {
    void *object;
    void *base;
    size_t total;
} ZGEntry;

static ZGEntry zg_entries[ZG_SLOTS];

voidpf ZLIB_INTERNAL zcalloc(voidpf opaque, unsigned items, unsigned size);
void ZLIB_INTERNAL zcfree(voidpf opaque, voidpf address);

static void *zg_map(size_t items, size_t size)
{
    size_t need = items * size;
    if (need == 0) {
        need = 1;
    }
    size_t payload = (need + ZG_PAGE - 1) / ZG_PAGE;
    size_t total = (payload + 2) * ZG_PAGE;

    unsigned char *base = (unsigned char *)mmap(NULL,
                                                total,
                                                PROT_READ | PROT_WRITE,
                                                MAP_PRIVATE | MAP_ANON,
                                                -1,
                                                0);
    if (base == MAP_FAILED) {
        return NULL;
    }

    /* The object ends exactly where the guard page starts. */
    unsigned char *object = base + ZG_PAGE + payload * ZG_PAGE - need;
    if (mprotect(base + ZG_PAGE + payload * ZG_PAGE,
                 ZG_PAGE,
                 PROT_NONE) != 0) {
        munmap(base, total);
        return NULL;
    }

    for (int index = 0; index < ZG_SLOTS; index++) {
        if (zg_entries[index].object == NULL) {
            zg_entries[index].object = object;
            zg_entries[index].base = base;
            zg_entries[index].total = total;
            return object;
        }
    }

    /*
     * Table full: keep working without the guard.  Such a block cannot be
     * tracked by zcfree, so it is intentionally leaked rather than unmapped
     * at the wrong address; the experiment only needs a handful of slots.
     */
    munmap(base, total);
    void *plain = mmap(NULL, need, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON, -1, 0);
    return plain == MAP_FAILED ? NULL : plain;
}

voidpf ZLIB_INTERNAL zcalloc(voidpf opaque, unsigned items, unsigned size)
{
    (void)opaque;
    return zg_map(items, size);
}

void ZLIB_INTERNAL zcfree(voidpf opaque, voidpf address)
{
    (void)opaque;
    if (address == NULL) {
        return;
    }
    for (int index = 0; index < ZG_SLOTS; index++) {
        if (zg_entries[index].object == address) {
            munmap(zg_entries[index].base, zg_entries[index].total);
            zg_entries[index].object = NULL;
            zg_entries[index].base = NULL;
            zg_entries[index].total = 0;
            return;
        }
    }
}
