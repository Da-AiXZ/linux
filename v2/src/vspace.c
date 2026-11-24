/*
 * v2/vspace.c -- page table implementation of the guest address space.
 *
 * Normative reference: v2/tools/vspace_model.py.  CI replays traces
 * generated from that model and compares both the return value and a hash of
 * the page array after every operation, so the two cannot drift.
 *
 * Invariants, all checked by v2_space_verify() and by the test harness:
 *   1. a page is exactly one of FREE, RESERVED, MAPPED|prot
 *   2. every mapping returned to the guest is page-aligned and wholly inside
 *      the reservation
 *   3. a page is committed on the host if and only if it is MAPPED here
 *   4. no operation ever commits a page that is already committed
 *   5. islands stay RESERVED for the life of the space
 */
#include "v2/vspace.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * V2_CHECK_SPACE=1 turns the page table into a thing that accuses itself.
 *
 * Every invariant in this file is a claim about one array; if anything writes
 * past the end of that array -- ours, or a guest write that our own mapping
 * logic mis-placed -- the table becomes the lie that produces aliasing.  v1
 * died of exactly that and could not see it, because its records were spread
 * over four structures and none of them asserted anything.
 *
 * A canary after the array catches an overwrite; verify() catches a state the
 * state machine cannot produce.  Both are cheap enough to run after every
 * operation in a diagnostic build, which is where the flake has to be caught:
 * at the operation that did it, not three thousand syscalls later.
 */
int v2_check_space;

#define V2_CANARY_BYTES 64
static const uint8_t v2_canary[V2_CANARY_BYTES] = {
    0xA5, 0x5A, 0xC3, 0x3C, 0x96, 0x69, 0x0F, 0xF0,
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
    0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
    0x7E, 0x81, 0x2D, 0xD2, 0x4B, 0xB4, 0xE7, 0x18,
    0x3A, 0xC5, 0x6F, 0x90, 0x0C, 0xF3, 0x5D, 0xA2,
    0xB8, 0x47, 0x1E, 0xE1, 0x94, 0x6B, 0xD0, 0x2F,
    0xF1, 0x0E, 0x8C, 0x73, 0x25, 0xDA, 0x61, 0x9E,
    0x4A, 0xB5, 0xC7, 0x38, 0xE3, 0x1C, 0x52, 0xAD
};

struct v2_space {
    struct v2_host host;
    uint8_t *base;
    size_t length;
    size_t page_size;
    size_t page_count;
    size_t island_size;    /* bytes, at offset 0 of every stride */
    size_t island_stride;
    size_t alloc_start;    /* first page that may be handed out */
    size_t cursor;         /* next-fit hint, in pages */
    size_t guard_pages;    /* diagnostic pages kept empty after each map */
    uint8_t *pages;
    size_t pages_bytes;    /* what was allocated: pages + the canary */
    /*
     * Guard marks live beside the page array instead of inside it: a guard
     * page is FREE -- it is not committed and it is not an island -- so
     * putting a fourth state in `pages` would break the model replay for
     * every run, including the ones that do not use guards.
     */
    uint8_t *guards;
};

static int v2_page_is_guard(const v2_space *space, size_t page)
{
    return space->guards != NULL && space->guards[page] != 0;
}

static void v2_clear_guards(v2_space *space, size_t first, size_t count)
{
    if (space->guards == NULL) {
        return;
    }
    for (size_t page = first; page < first + count && page < space->page_count;
         page++) {
        space->guards[page] = 0;
    }
}

static void v2_arm_guards(v2_space *space, size_t first, size_t count)
{
    if (space->guards == NULL) {
        return;
    }
    for (size_t page = first; page < first + count && page < space->page_count;
         page++) {
        space->guards[page] = 1;
    }
}

static size_t v2_pages_for(size_t length, size_t page_size)
{
    size_t count = length / page_size;
    if ((length % page_size) != 0) {
        count++;
    }
    return count;
}

static int v2_is_aligned(const v2_space *space, const void *address)
{
    return ((uintptr_t)address % space->page_size) == 0;
}

static void v2_release_pages(v2_space *space, size_t first, size_t count)
{
    for (size_t page = first; page < first + count; page++) {
        if ((space->pages[page] & V2_PAGE_RESERVED) != 0) {
            continue;
        }
        space->pages[page] = V2_PAGE_FREE;
    }
}

static size_t v2_scan(const v2_space *space, size_t from, size_t to,
                      size_t count, int *found)
{
    size_t run = 0;
    size_t start = from;

    *found = 0;
    for (size_t page = from; page < to; page++) {
        if (space->pages[page] == V2_PAGE_FREE &&
            !v2_page_is_guard(space, page)) {
            if (run == 0) {
                start = page;
            }
            run++;
            if (run == count) {
                *found = 1;
                return start;
            }
        } else {
            run = 0;
        }
    }
    return 0;
}

/*
 * First fit from the cursor, then one wrap.  The cursor makes a sequence of
 * map/unmap deterministic, which is what lets the model and the
 * implementation be compared at all.
 */
static int v2_find_run(const v2_space *space, size_t count, size_t *out)
{
    int found = 0;
    size_t page;

    if (count == 0 || count > space->page_count) {
        return 0;
    }
    page = v2_scan(space, space->cursor, space->page_count, count, &found);
    if (found) {
        *out = page;
        return 1;
    }
    page = v2_scan(space, space->alloc_start, space->cursor, count, &found);
    if (found) {
        *out = page;
        return 1;
    }
    return 0;
}

/*
 * First fit with room for the guard pages after the run.  When only a tight
 * run exists the mapping still succeeds without a guard: the guard is a
 * diagnostic, and letting it refuse a legal mapping would turn it into a
 * constraint that changes behaviour.
 */
static int v2_find_run_guarded(const v2_space *space, size_t count,
                               size_t *out, size_t *guard)
{
    size_t pages = space->guard_pages;

    *guard = 0;
    if (pages != 0 && count + pages <= space->page_count &&
        v2_find_run(space, count + pages, out)) {
        *guard = pages;
        return 1;
    }
    return v2_find_run(space, count, out);
}

/*
 * V2_HANDOUT_CHECK=1: every page that leaves the free list must read as zero.
 *
 * This is the invariant the whole address space exists to provide, and until
 * now it was asserted only by a separate page-reuse test.  Here it is checked
 * at the one place a page is handed out, which makes it a detector instead of a
 * statistic: a page that comes back dirty comes back dirty on *every* run, so
 * one run answers the question that two hundred runs of `apk --version` were
 * being asked to answer.
 *
 * On Darwin this is the interesting check.  `madvise(MADV_DONTNEED)` there is a
 * hint and discards nothing (measured: 16384 of 16384 bytes intact), so every
 * reuse path has to destroy the range with MAP_FIXED|MAP_ANON instead.  If one
 * path forgot, this line names the page and the byte.
 */
static int handout_check(void)
{
    static int enabled = -1;

    if (enabled < 0) {
        const char *value = getenv("V2_HANDOUT_CHECK");

        enabled = value != NULL && value[0] != '\0' && value[0] != '0';
    }
    return enabled;
}

static void v2_check_handout(v2_space *space, size_t page, int prot)
{
    static uint8_t buffer[65536];
    static unsigned long reported;
    uint8_t *at = space->base + page * space->page_size;
    size_t offset;

    /* A page the caller cannot read now is a page the guest cannot read now. */
    if (!handout_check() || (prot & V2_PROT_READ) == 0 ||
        space->page_size > sizeof(buffer)) {
        return;
    }
    if (space->host.read(space->host.ctx, buffer, at, space->page_size) != 0) {
        return;
    }
    for (offset = 0; offset < space->page_size; offset++) {
        if (buffer[offset] != 0) {
            reported++;
            if (reported <= 8) {
                fprintf(stderr,
                        "[v2] HANDOUT DIRTY page=0x%llx offset=%zu "
                        "value=0x%02x state_before=0x%02x prot=0x%x\n",
                        (unsigned long long)(uintptr_t)at, offset,
                        (unsigned)buffer[offset], (unsigned)space->pages[page],
                        (unsigned)prot);
            } else if (reported == 9) {
                fprintf(stderr, "[v2] HANDOUT DIRTY: further pages suppressed\n");
            }
            return;
        }
    }
}

static int v2_commit(v2_space *space, size_t first, size_t count, int prot)
{
    int status = space->host.commit(space->host.ctx,
                                    space->base + first * space->page_size,
                                    count * space->page_size,
                                    prot);
    if (status != 0) {
        return status;
    }
    for (size_t page = first; page < first + count; page++) {
        /*
         * Only pages leaving the free list are checkable: a page that is
         * already MAPPED is here for a protection change and holds the guest's
         * own data.
         */
        if ((space->pages[page] & V2_PAGE_MAPPED) == 0) {
            v2_check_handout(space, page, prot);
        }
        space->pages[page] =
            (uint8_t)(V2_PAGE_MAPPED | (prot & V2_PAGE_PROT_MASK));
    }
    return 0;
}

int v2_space_create(v2_space **out, const struct v2_host *host,
                    size_t length, size_t page_size,
                    size_t island_stride, size_t island_size)
{
    v2_space *space;
    void *base = NULL;
    size_t pages;

    if (out == NULL || host == NULL || page_size == 0 || length == 0) {
        return -V2_EINVAL;
    }
    pages = v2_pages_for(length, page_size);
    if (pages == 0) {
        return -V2_EINVAL;
    }

    space = (v2_space *)host->alloc(host->ctx, sizeof(*space));
    if (space == NULL) {
        return -V2_ENOMEM;
    }
    memset(space, 0, sizeof(*space));
    space->host = *host;
    space->length = pages * page_size;
    space->page_size = page_size;
    space->page_count = pages;
    space->island_size = island_size;
    space->island_stride = island_stride;

    if (host->reserve(host->ctx, space->length, &base) != 0 ||
        base == NULL) {
        host->dealloc(host->ctx, space, sizeof(*space));
        return -V2_ENOMEM;
    }
    space->base = (uint8_t *)base;

    space->pages = (uint8_t *)host->alloc(host->ctx,
                                          pages + V2_CANARY_BYTES);
    if (space->pages == NULL) {
        host->release(host->ctx, base, space->length);
        host->dealloc(host->ctx, space, sizeof(*space));
        return -V2_ENOMEM;
    }
    space->pages_bytes = pages + V2_CANARY_BYTES;
    memset(space->pages, V2_PAGE_FREE, pages);
    memcpy(space->pages + pages, v2_canary, V2_CANARY_BYTES);

    if (island_stride != 0 && island_size != 0) {
        for (size_t offset = 0; offset < space->length;
             offset += island_stride) {
            size_t first = offset / page_size;
            size_t last = (offset + island_size) / page_size;
            if (last > pages) {
                last = pages;
            }
            for (size_t page = first; page < last; page++) {
                space->pages[page] = V2_PAGE_RESERVED;
            }
            if (island_stride > space->length) {
                break;    /* guard against a pathological stride */
            }
        }
        space->alloc_start = v2_pages_for(island_size, page_size);
    } else {
        space->alloc_start = 0;
    }
    if (space->alloc_start > pages) {
        space->alloc_start = pages;
    }
    space->cursor = space->alloc_start;

    *out = space;
    return 0;
}

void v2_space_destroy(v2_space *space)
{
    if (space == NULL) {
        return;
    }
    if (space->guards != NULL) {
        space->host.dealloc(space->host.ctx, space->guards,
                            space->page_count);
    }
    space->host.release(space->host.ctx, space->base, space->length);
    space->host.dealloc(space->host.ctx, space->pages, space->pages_bytes);
    space->host.dealloc(space->host.ctx, space, sizeof(*space));
}

int v2_space_set_guard(v2_space *space, size_t pages)
{
    if (space == NULL) {
        return -V2_EINVAL;
    }
    if (pages == 0) {
        if (space->guards != NULL) {
            space->host.dealloc(space->host.ctx, space->guards,
                                space->page_count);
            space->guards = NULL;
        }
        space->guard_pages = 0;
        return 0;
    }
    if (space->guards == NULL) {
        space->guards = (uint8_t *)space->host.alloc(space->host.ctx,
                                                    space->page_count);
        if (space->guards == NULL) {
            return -V2_ENOMEM;
        }
    }
    memset(space->guards, 0, space->page_count);
    space->guard_pages = pages;
    /*
     * Keep the allocation cursor off a guard that would otherwise be the very
     * next page handed out, so the first mapping after this call also gets
     * its guard instead of spending the existing one.
     */
    space->cursor = space->alloc_start;
    return 0;
}

int v2_space_guard_at(const v2_space *space, const void *addr)
{
    size_t page;

    if (space == NULL || space->guards == NULL ||
        (uintptr_t)addr < (uintptr_t)space->base) {
        return 0;
    }
    page = (size_t)(((uintptr_t)addr - (uintptr_t)space->base) /
                    space->page_size);
    if (page >= space->page_count) {
        return 0;
    }
    return space->guards[page] != 0;
}

void *v2_space_base(const v2_space *space) { return space->base; }
size_t v2_space_length(const v2_space *space) { return space->length; }
size_t v2_space_page_size(const v2_space *space) { return space->page_size; }
size_t v2_space_page_count(const v2_space *space) { return space->page_count; }
size_t v2_space_island_stride(const v2_space *space)
{
    return space->island_stride;
}
size_t v2_space_island_size(const v2_space *space) { return space->island_size; }

const struct v2_host *v2_space_host(const v2_space *space)
{
    return &space->host;
}

long long v2_space_claim(v2_space *space, void *addr, size_t length, int prot)
{
    size_t first;
    size_t count;

    if (space == NULL || length == 0 || !v2_is_aligned(space, addr)) {
        return -V2_EINVAL;
    }
    if ((uintptr_t)addr < (uintptr_t)space->base) {
        return -V2_EINVAL;
    }
    first = (size_t)(((uintptr_t)addr - (uintptr_t)space->base) /
                     space->page_size);
    count = v2_pages_for(length, space->page_size);
    if (first >= space->page_count || count > space->page_count - first) {
        return -V2_EINVAL;
    }
    for (size_t page = first; page < first + count; page++) {
        if (space->pages[page] != V2_PAGE_RESERVED) {
            return -V2_EINVAL;
        }
    }
    v2_clear_guards(space, first, count);
    if (v2_commit(space, first, count, prot) != 0) {
        return -V2_ENOMEM;
    }
    return (long long)(uintptr_t)(space->base + first * space->page_size);
}

long long v2_space_map(v2_space *space, void *hint, size_t length, int prot,
                       int flags, int fd, long long offset)
{
    size_t count;
    size_t first = 0;
    size_t guard = 0;
    int fixed = 0;

    if (space == NULL || length == 0) {
        return -V2_EINVAL;
    }
    count = v2_pages_for(length, space->page_size);
    if (count == 0) {
        return -V2_EINVAL;
    }
    if (count > space->page_count) {
        return -V2_ENOMEM;
    }
    fixed = (flags & (V2_MAP_FIXED | V2_MAP_FIXED_NOREPLACE)) != 0;

    if (fixed) {
        uintptr_t address = (uintptr_t)hint;
        uintptr_t base = (uintptr_t)space->base;

        if (address == 0 || (address % space->page_size) != 0) {
            return -V2_EINVAL;
        }
        if (address < base) {
            return -V2_EINVAL;
        }
        first = (size_t)((address - base) / space->page_size);
        if (first + count > space->page_count) {
            return -V2_EINVAL;
        }
        for (size_t page = first; page < first + count; page++) {
            if ((space->pages[page] & V2_PAGE_RESERVED) != 0) {
                return -V2_EINVAL;
            }
        }
        /*
         * NOREPLACE wins over FIXED when both are set: it is the stronger
         * constraint, and silently replacing a live range because the caller
         * also passed FIXED would be the more dangerous reading.
         */
        if ((flags & V2_MAP_FIXED_NOREPLACE) != 0) {
            for (size_t page = first; page < first + count; page++) {
                if ((space->pages[page] & V2_PAGE_MAPPED) != 0) {
                    return -V2_EEXIST;
                }
            }
        } else {
            size_t page = first;

            /* Same reason as in unmap: decommit is a syscall, so batch it. */
            while (page < first + count) {
                size_t start;

                if ((space->pages[page] & V2_PAGE_MAPPED) == 0) {
                    page++;
                    continue;
                }
                start = page;
                while (page < first + count &&
                       (space->pages[page] & V2_PAGE_MAPPED) != 0) {
                    page++;
                }
                space->host.decommit(space->host.ctx,
                                     space->base + start * space->page_size,
                                     (page - start) * space->page_size);
            }
            v2_release_pages(space, first, count);
        }
        /* The guest named this address, so it may take a guard page back. */
        v2_clear_guards(space, first, count);
    } else {
        if (!v2_find_run_guarded(space, count, &first, &guard)) {
            return -V2_ENOMEM;
        }
        space->cursor = first + count + guard;
        if (space->cursor >= space->page_count) {
            space->cursor = space->alloc_start;
        }
    }

    if (fd >= 0) {
        uint8_t *destination = space->base + first * space->page_size;
        size_t total = count * space->page_size;
        size_t done = 0;
        int failed = 0;

        if (v2_commit(space, first, count, V2_PROT_READ | V2_PROT_WRITE) != 0) {
            v2_release_pages(space, first, count);
            return -V2_ENOMEM;
        }
        /*
         * A file mapping is routinely longer than the file: the last page of
         * the last PT_LOAD carries .bss, and ld.so maps whole libraries with
         * one call.  Linux zero-fills past EOF, so running out of file is not
         * an error -- an actual read error is.  (v1 treated short reads as
         * fatal and could never map libc.)
         */
        {
            int stalls = 0;

            while (done < total) {
                long got = space->host.read_at(space->host.ctx, fd,
                                               destination + done,
                                               total - done,
                                               offset + (long long)done);
                if (got < 0) {
                    failed = 1;
                    break;
                }
                if (got == 0) {
                    /*
                     * Zero means EOF -- but a library whose tail is silently
                     * zero instead of file data does not fail here, it fails
                     * twenty steps later inside ld.so's symbol lookup, with a
                     * message naming whichever symbol the damage happened to
                     * hit.  Three attempts cost nothing; a wrong zero costs a
                     * day.
                     */
                    if (++stalls > 3) {
                        break;
                    }
                    continue;
                }
                stalls = 0;
                done += (size_t)got;
            }
        }
        if (failed) {
            space->host.decommit(space->host.ctx, destination, total);
            v2_release_pages(space, first, count);
            return -V2_EIO;
        }
        /* Past EOF the pages stay zero: commit just handed us fresh
         * anonymous pages and only the first `done` bytes were written. */
        if (prot != (V2_PROT_READ | V2_PROT_WRITE)) {
            if (space->host.protect(space->host.ctx, destination, total,
                                    prot) != 0) {
                space->host.decommit(space->host.ctx, destination, total);
                v2_release_pages(space, first, count);
                return -V2_ENOMEM;
            }
            for (size_t page = first; page < first + count; page++) {
                space->pages[page] =
                    (uint8_t)(V2_PAGE_MAPPED | (prot & V2_PAGE_PROT_MASK));
            }
        }
    } else {
        if (v2_commit(space, first, count, prot) != 0) {
            v2_release_pages(space, first, count);
            return -V2_ENOMEM;
        }
    }
    v2_arm_guards(space, first + count, guard);
    v2_space_check_now(space, "mmap");
    return (long long)(uintptr_t)(space->base + first * space->page_size);
}

long long v2_space_unmap(v2_space *space, void *addr, size_t length)
{
    size_t first;
    size_t count;

    if (space == NULL || length == 0 || !v2_is_aligned(space, addr)) {
        return -V2_EINVAL;
    }
    if ((uintptr_t)addr < (uintptr_t)space->base) {
        return -V2_EINVAL;
    }
    first = (size_t)(((uintptr_t)addr - (uintptr_t)space->base) /
                     space->page_size);
    if (first >= space->page_count) {
        return 0;
    }
    count = v2_pages_for(length, space->page_size);
    if (count > space->page_count - first) {
        count = space->page_count - first;
    }
    /*
     * Release in runs, not page by page: decommit is a real syscall that
     * destroys the mapping (see host_darwin.c), and apk unmaps megabytes at a
     * time.  Nothing here changes the page table, so the model still matches.
     */
    {
        size_t page = first;

        while (page < first + count) {
            size_t start;

            if ((space->pages[page] & V2_PAGE_MAPPED) == 0) {
                page++;
                continue;
            }
            start = page;
            while (page < first + count &&
                   (space->pages[page] & V2_PAGE_MAPPED) != 0) {
                page++;
            }
            space->host.decommit(space->host.ctx,
                                 space->base + start * space->page_size,
                                 (page - start) * space->page_size);
        }
    }
    v2_release_pages(space, first, count);
    v2_clear_guards(space, first, count);
    /*
     * The page just past the range belongs to this mapping's guard when the
     * unmap ends exactly at a mapping end.  Reclaim it, or a program that maps
     * and unmaps in a loop loses one page per iteration to orphan guards.
     */
    if (first + count < space->page_count &&
        v2_page_is_guard(space, first + count)) {
        space->guards[first + count] = 0;
    }
    if (first < space->cursor) {
        space->cursor = first > space->alloc_start ? first : space->alloc_start;
    }
    v2_space_check_now(space, "munmap");
    return 0;
}

long long v2_space_protect(v2_space *space, void *addr, size_t length,
                           int prot)
{
    size_t first;
    size_t count;

    if (space == NULL || length == 0 || !v2_is_aligned(space, addr)) {
        return -V2_EINVAL;
    }
    if ((uintptr_t)addr < (uintptr_t)space->base) {
        return -V2_EINVAL;
    }
    first = (size_t)(((uintptr_t)addr - (uintptr_t)space->base) /
                     space->page_size);
    if (first >= space->page_count) {
        return -V2_ENOMEM;
    }
    count = v2_pages_for(length, space->page_size);
    if (count > space->page_count - first) {
        count = space->page_count - first;
    }
    for (size_t page = first; page < first + count; page++) {
        if ((space->pages[page] & V2_PAGE_RESERVED) != 0) {
            continue;
        }
        if ((space->pages[page] & V2_PAGE_MAPPED) == 0) {
            return -V2_ENOMEM;
        }
    }
    /*
     * Apply page by page.  A contiguous protect() would be one syscall, but
     * it would also touch reserved pages in the middle of a range; the
     * islands must stay executable regardless of what the guest asks for.
     */
    for (size_t page = first; page < first + count; page++) {
        if ((space->pages[page] & V2_PAGE_RESERVED) != 0) {
            continue;
        }
        if (space->host.protect(space->host.ctx,
                                space->base + page * space->page_size,
                                space->page_size, prot) != 0) {
            return -V2_ENOMEM;
        }
        space->pages[page] =
            (uint8_t)(V2_PAGE_MAPPED | (prot & V2_PAGE_PROT_MASK));
    }
    v2_space_check_now(space, "mprotect");
    return 0;
}

long long v2_space_remap(v2_space *space, void *addr, size_t old_length,
                         size_t new_length, int flags)
{
    size_t count_old;
    size_t count_new;
    size_t first;
    size_t old_first;
    size_t guard = 0;
    int prot;

    if (space == NULL || old_length == 0 || new_length == 0 ||
        !v2_is_aligned(space, addr)) {
        return -V2_EINVAL;
    }
    if ((flags & V2_MREMAP_FIXED) != 0) {
        return -V2_EINVAL;
    }
    if ((uintptr_t)addr < (uintptr_t)space->base) {
        return -V2_EINVAL;
    }
    if (new_length <= old_length && (flags & V2_MREMAP_MAYMOVE) == 0) {
        return (long long)(uintptr_t)addr;
    }
    count_old = v2_pages_for(old_length, space->page_size);
    count_new = v2_pages_for(new_length, space->page_size);
    if (!v2_find_run_guarded(space, count_new, &first, &guard)) {
        return -V2_ENOMEM;
    }
    space->cursor = first + count_new + guard;
    if (space->cursor >= space->page_count) {
        space->cursor = space->alloc_start;
    }
    old_first = (size_t)(((uintptr_t)addr - (uintptr_t)space->base) /
                         space->page_size);
    prot = (space->pages[old_first] & V2_PAGE_MAPPED) != 0
        ? (int)(space->pages[old_first] & V2_PAGE_PROT_MASK)
        : V2_PROT_NONE;

    {
        uint8_t *destination = space->base + first * space->page_size;
        size_t total = count_new * space->page_size;
        size_t copy = old_length < new_length ? old_length : new_length;

        if (v2_commit(space, first, count_new,
                      V2_PROT_READ | V2_PROT_WRITE) != 0) {
            v2_release_pages(space, first, count_new);
            return -V2_ENOMEM;
        }
        if (space->host.copy(space->host.ctx, destination, addr, copy) != 0) {
            space->host.decommit(space->host.ctx, destination, total);
            v2_release_pages(space, first, count_new);
            return -V2_ENOMEM;
        }
        if (prot != (V2_PROT_READ | V2_PROT_WRITE)) {
            if (space->host.protect(space->host.ctx, destination, total,
                                    prot) != 0) {
                space->host.decommit(space->host.ctx, destination, total);
                v2_release_pages(space, first, count_new);
                return -V2_ENOMEM;
            }
            for (size_t page = first; page < first + count_new; page++) {
                space->pages[page] =
                    (uint8_t)(V2_PAGE_MAPPED | (prot & V2_PAGE_PROT_MASK));
            }
        }
    }

    v2_space_unmap(space, addr, count_old * space->page_size);
    v2_arm_guards(space, first + count_new, guard);
    if (old_first < space->cursor) {
        space->cursor =
            old_first > space->alloc_start ? old_first : space->alloc_start;
    }
    v2_space_check_now(space, "mremap");
    return (long long)(uintptr_t)(space->base + first * space->page_size);
}

long long v2_space_advise(v2_space *space, void *addr, size_t length,
                          int advice)
{
    size_t first;
    size_t count;

    if (space == NULL || length == 0 || !v2_is_aligned(space, addr)) {
        return -V2_EINVAL;
    }
    if ((uintptr_t)addr < (uintptr_t)space->base) {
        return -V2_EINVAL;
    }
    first = (size_t)(((uintptr_t)addr - (uintptr_t)space->base) /
                     space->page_size);
    if (first >= space->page_count) {
        return 0;
    }
    count = v2_pages_for(length, space->page_size);
    if (count > space->page_count - first) {
        count = space->page_count - first;
    }
    if (advice == V2_MADV_DONTNEED || advice == V2_MADV_FREE) {
        size_t start = first;
        size_t run = 0;
        int run_prot = 0;

        /*
         * Linux: after MADV_DONTNEED the pages are still mapped, and reading
         * one returns zeros.  The host cannot deliver that with a discard hint
         * (see host_darwin.c), so the run is genuinely released and then
         * committed again with the protection it had.  The page table does not
         * change, which is why no model op exists for this.
         */
        for (size_t page = first; page < first + count + 1; page++) {
            int mapped = page < first + count &&
                (space->pages[page] & V2_PAGE_MAPPED) != 0;
            int prot = mapped ? (space->pages[page] & V2_PAGE_PROT_MASK) : 0;

            if (run != 0 && (!mapped || prot != run_prot)) {
                uint8_t *at = space->base + start * space->page_size;
                size_t bytes = run * space->page_size;

                space->host.decommit(space->host.ctx, at, bytes);
                space->host.commit(space->host.ctx, at, bytes, run_prot);
                run = 0;
            }
            if (mapped) {
                if (run == 0) {
                    start = page;
                    run_prot = prot;
                }
                run++;
            }
        }
    }
    v2_space_check_now(space, "madvise");
    return 0;
}

int v2_space_check(const v2_space *space, const void *addr, size_t length,
                   int need_prot)
{
    size_t offset;
    size_t first;
    size_t count;

    if (space == NULL) {
        return -V2_EFAULT;
    }
    if (length == 0) {
        return 0;          /* no page is touched; matches Linux */
    }
    if ((uintptr_t)addr < (uintptr_t)space->base) {
        return -V2_EFAULT;
    }
    /*
     * A range check is not an mmap: the address does not have to be page
     * aligned, only the range has to be inside the mapping.  Requiring
     * alignment here rejected every write into the middle of the initial
     * stack (v2_stack_build found it in one run).
     */
    offset = (size_t)((uintptr_t)addr - (uintptr_t)space->base);
    first = offset / space->page_size;
    count = v2_pages_for(offset % space->page_size + length, space->page_size);
    if (first >= space->page_count || count > space->page_count - first) {
        return -V2_EFAULT;
    }
    for (size_t page = first; page < first + count; page++) {
        int state = space->pages[page];
        if ((state & V2_PAGE_MAPPED) == 0) {
            return -V2_EFAULT;
        }
        if ((state & need_prot & V2_PAGE_PROT_MASK) !=
            (need_prot & V2_PAGE_PROT_MASK)) {
            return -V2_EFAULT;
        }
    }
    return 0;
}

int v2_space_state_at(const v2_space *space, const void *addr)
{
    size_t page;

    if (space == NULL || (uintptr_t)addr < (uintptr_t)space->base) {
        return -1;
    }
    page = (size_t)(((uintptr_t)addr - (uintptr_t)space->base) /
                    space->page_size);
    if (page >= space->page_count) {
        return -1;
    }
    return space->pages[page];
}

uint64_t v2_space_hash(const v2_space *space)
{
    uint64_t hash = 0xCBF29CE484222325ULL;

    for (size_t page = 0; page < space->page_count; page++) {
        hash ^= space->pages[page];
        hash *= 0x100000001B3ULL;
    }
    return hash;
}

/*
 * -1 and the offending page, for the diagnostic path.  verify() answers "is
 * this table possible?"; this also answers "where did it stop being possible",
 * which is the only form of the answer that leads anywhere.
 */
static int v2_first_bad(const v2_space *space, size_t *where)
{
    if (space == NULL || space->pages == NULL) {
        *where = 0;
        return -3;
    }
    for (size_t page = 0; page < space->page_count; page++) {
        int state = space->pages[page];
        if (!(state == V2_PAGE_FREE || state == V2_PAGE_RESERVED ||
              (state >= V2_PAGE_MAPPED &&
               state <= (V2_PAGE_MAPPED | V2_PAGE_PROT_MASK)))) {
            *where = page;
            return -1;
        }
        if ((state & V2_PAGE_RESERVED) != 0 &&
            (state & V2_PAGE_MAPPED) != 0) {
            *where = page;
            return -1;
        }
        if (v2_page_is_guard(space, page) && state != V2_PAGE_FREE) {
            *where = page;
            return -2;
        }
    }
    if (space->alloc_start > space->cursor ||
        space->cursor > space->page_count) {
        *where = space->cursor;
        return -3;
    }
    return 0;
}

void v2_space_check_now(v2_space *space, const char *what)
{
    size_t where = 0;
    int why;

    if (!v2_check_space || space == NULL) {
        return;
    }
    why = v2_first_bad(space, &where);
    if (why != 0) {
        fprintf(stderr, "[v2] SPACE CORRUPT after %s: page %zu, reason %d, "
                        "state 0x%02x\n",
                what, where, why, (unsigned)space->pages[where]);
        abort();
    }
    if (memcmp(space->pages + space->page_count, v2_canary,
               V2_CANARY_BYTES) != 0) {
        fprintf(stderr, "[v2] SPACE CORRUPT after %s: canary past the page "
                        "array was overwritten\n", what);
        abort();
    }
}

int v2_space_verify(const v2_space *space)
{
    size_t where = 0;

    return v2_first_bad(space, &where) == 0 ? 0 : -1;
}

int v2_space_read(const v2_space *space, void *destination,
                  const void *source, size_t length)
{
    if (length == 0) {
        return 0;
    }
    if (v2_space_check(space, source, length, V2_PROT_READ) != 0) {
        return -V2_EFAULT;
    }
    if (space->host.read(space->host.ctx, destination, source, length) != 0) {
        return -V2_EFAULT;
    }
    return 0;
}

int v2_space_write(const v2_space *space, void *destination,
                   const void *source, size_t length)
{
    if (length == 0) {
        return 0;
    }
    if (v2_space_check(space, destination, length, V2_PROT_WRITE) != 0) {
        return -V2_EFAULT;
    }
    if (space->host.write(space->host.ctx, destination, source, length) != 0) {
        return -V2_EFAULT;
    }
    return 0;
}
