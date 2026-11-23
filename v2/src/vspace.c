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

#include <string.h>

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
    uint8_t *pages;
};

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
        if (space->pages[page] == V2_PAGE_FREE) {
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

    space->pages = (uint8_t *)host->alloc(host->ctx, pages);
    if (space->pages == NULL) {
        host->release(host->ctx, base, space->length);
        host->dealloc(host->ctx, space, sizeof(*space));
        return -V2_ENOMEM;
    }
    memset(space->pages, V2_PAGE_FREE, pages);

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
    space->host.release(space->host.ctx, space->base, space->length);
    space->host.dealloc(space->host.ctx, space->pages, space->page_count);
    space->host.dealloc(space->host.ctx, space, sizeof(*space));
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
            for (size_t page = first; page < first + count; page++) {
                if ((space->pages[page] & V2_PAGE_MAPPED) != 0) {
                    space->host.decommit(space->host.ctx,
                                         space->base + page * space->page_size,
                                         space->page_size);
                }
            }
            v2_release_pages(space, first, count);
        }
    } else {
        if (!v2_find_run(space, count, &first)) {
            return -V2_ENOMEM;
        }
        space->cursor = first + count;
        if (space->cursor >= space->page_count) {
            space->cursor = space->alloc_start;
        }
    }

    if (fd >= 0) {
        uint8_t *destination = space->base + first * space->page_size;
        size_t total = count * space->page_size;
        size_t done = 0;

        if (v2_commit(space, first, count, V2_PROT_READ | V2_PROT_WRITE) != 0) {
            v2_release_pages(space, first, count);
            return -V2_ENOMEM;
        }
        while (done < total) {
            long got = space->host.read_at(space->host.ctx, fd,
                                           destination + done, total - done,
                                           offset + (long long)done);
            if (got <= 0) {
                break;
            }
            done += (size_t)got;
        }
        if (done < total) {
            /* Linux would fault on first touch; we cannot, so report it. */
            space->host.decommit(space->host.ctx, destination, total);
            v2_release_pages(space, first, count);
            return -V2_EIO;
        }
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
    for (size_t page = first; page < first + count; page++) {
        if ((space->pages[page] & V2_PAGE_MAPPED) != 0) {
            space->host.decommit(space->host.ctx,
                                 space->base + page * space->page_size,
                                 space->page_size);
        }
    }
    v2_release_pages(space, first, count);
    if (first < space->cursor) {
        space->cursor = first > space->alloc_start ? first : space->alloc_start;
    }
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
    return 0;
}

long long v2_space_remap(v2_space *space, void *addr, size_t old_length,
                         size_t new_length, int flags)
{
    size_t count_old;
    size_t count_new;
    size_t first;
    size_t old_first;
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
    if (!v2_find_run(space, count_new, &first)) {
        return -V2_ENOMEM;
    }
    space->cursor = first + count_new;
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
    if (old_first < space->cursor) {
        space->cursor =
            old_first > space->alloc_start ? old_first : space->alloc_start;
    }
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

        for (size_t page = first; page < first + count + 1; page++) {
            int mapped = page < first + count &&
                (space->pages[page] & V2_PAGE_MAPPED) != 0;
            if (mapped) {
                if (run == 0) {
                    start = page;
                }
                run++;
            } else if (run != 0) {
                space->host.discard(space->host.ctx,
                                    space->base + start * space->page_size,
                                    run * space->page_size);
                run = 0;
            }
        }
    }
    return 0;
}

int v2_space_check(const v2_space *space, const void *addr, size_t length,
                   int need_prot)
{
    size_t first;
    size_t count;

    if (space == NULL) {
        return -V2_EFAULT;
    }
    if (length == 0) {
        return 0;          /* no page is touched; matches Linux */
    }
    if (!v2_is_aligned(space, addr)) {
        return -V2_EFAULT;
    }
    if ((uintptr_t)addr < (uintptr_t)space->base) {
        return -V2_EFAULT;
    }
    first = (size_t)(((uintptr_t)addr - (uintptr_t)space->base) /
                     space->page_size);
    count = v2_pages_for(length, space->page_size);
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

    if (space == NULL || !v2_is_aligned(space, addr) ||
        (uintptr_t)addr < (uintptr_t)space->base) {
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

int v2_space_verify(const v2_space *space)
{
    if (space == NULL || space->pages == NULL) {
        return -1;
    }
    for (size_t page = 0; page < space->page_count; page++) {
        int state = space->pages[page];
        if (!(state == V2_PAGE_FREE || state == V2_PAGE_RESERVED ||
              (state >= V2_PAGE_MAPPED &&
               state <= (V2_PAGE_MAPPED | V2_PAGE_PROT_MASK)))) {
            return -1;
        }
        if ((state & V2_PAGE_RESERVED) != 0 &&
            (state & V2_PAGE_MAPPED) != 0) {
            return -1;
        }
    }
    if (space->alloc_start > space->cursor ||
        space->cursor > space->page_count) {
        return -1;
    }
    return 0;
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
