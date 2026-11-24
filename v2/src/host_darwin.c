/*
 * v2/host_darwin.c -- the only file that knows this is macOS.
 *
 * Pages are reserved PROT_NONE once and committed with mprotect, so a guest
 * mapping never shares a host page with a neighbour (the two are the same
 * size by construction).  No page is ever writable and executable at the same
 * time: code is written while the page is RW, then sealed RX.
 */
#if defined(__APPLE__)

#include "v2/host_darwin.h"

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int d_reserve(void *context, size_t length, void **base)
{
    const char *pin = getenv("V2_SPACE_BASE");
    void *map;

    (void)context;
    /*
     * Two ways to reserve, and the difference between them turned out to
     * matter: unpinned, the flake fires about once in forty runs; pinned at two
     * hundred different addresses, four hundred runs in a row passed.  So the
     * question "does the address matter, or the way it is taken?" is worth one
     * experiment.
     *
     * V2_PIN_KERNEL=1 takes the kernel's address and then asks for that same
     * address with MAP_FIXED: same address as the failing configuration, same
     * mechanism as the passing one.  Whatever still differs afterwards is not
     * either of those two things.
     */
    if (getenv("V2_PIN_KERNEL") != NULL) {
        void *chosen = mmap(NULL, length, PROT_NONE,
                            MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);

        if (chosen != MAP_FAILED) {
            munmap(chosen, length);
            map = mmap(chosen, length, PROT_NONE,
                       MAP_ANON | MAP_PRIVATE | MAP_NORESERVE | MAP_FIXED, -1,
                       0);
            if (map != MAP_FAILED) {
                *base = map;
                return 0;
            }
        }
        fprintf(stderr, "[v2] V2_PIN_KERNEL could not re-take the address it "
                        "was given; falling back\n");
    }
    /*
     * V2_SPACE_BASE pins the arena so a failure seen on the device can be
     * reproduced on a desktop with the same absolute addresses.  The flake is
     * layout sensitive -- V2_VERIFY moves one library and the rate drops by an
     * order of magnitude -- so "the same layout, on demand" is the difference
     * between a bug that is hunted and one that is waited for.
     *
     * The region is ours to take: nothing else in this process maps there, and
     * a pinned base that is already occupied is not fatal, it just falls back
     * to the anonymous reservation.
     */
    if (pin != NULL) {
        unsigned long long wanted = strtoull(pin, NULL, 0);

        if (wanted != 0) {
            map = mmap((void *)(uintptr_t)wanted, length, PROT_NONE,
                       MAP_ANON | MAP_PRIVATE | MAP_NORESERVE | MAP_FIXED, -1,
                       0);
            if (map != MAP_FAILED) {
                *base = map;
                return 0;
            }
            fprintf(stderr, "[v2] V2_SPACE_BASE=0x%llx unavailable; falling "
                            "back to an anonymous reservation\n", wanted);
        }
    }
    map = mmap(NULL, length, PROT_NONE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE,
               -1, 0);
    if (map == MAP_FAILED) {
        return -1;
    }
    *base = map;
    return 0;
}

static void d_release(void *context, void *base, size_t length)
{
    (void)context;
    munmap(base, length);
}

static int d_commit(void *context, void *address, size_t length, int prot)
{
    (void)context;
    return mprotect(address, length, prot == 0 ? PROT_NONE : prot);
}

static int d_decommit(void *context, void *address, size_t length)
{
    void *map;

    (void)context;
    /*
     * mprotect(PROT_NONE) + madvise(MADV_DONTNEED) does NOT discard anything
     * on Darwin.  V2_PAGETEST measured it: a page written, unmapped and asked
     * for again comes back with 16384 of 16384 bytes intact, and the same is
     * true of MADV_DONTNEED on a live page.  madvise is documented as a hint
     * ("the system may reclaim these pages"), and it does not have to act.
     *
     * Linux promises the opposite -- a page handed out again reads as zeros --
     * and every .bss in every library is built on that promise: the tail of a
     * segment is mapped MAP_FIXED over pages that held another library a
     * moment ago.  musl keeps its globals, its dso chain and its exit list in
     * exactly those bytes, which is why the symptom was "a random symbol is
     * not found" and "a NULL walk while printing the error".
     *
     * Replacing the range with fresh anonymous pages keeps the promise on both
     * platforms: MAP_FIXED destroys whatever was mapped there, and a brand new
     * anonymous page is zero by definition.
     */
    map = mmap(address, length, PROT_NONE,
               MAP_ANON | MAP_PRIVATE | MAP_FIXED | MAP_NORESERVE, -1, 0);
    if (map == MAP_FAILED) {
        return -1;
    }
    return 0;
}

static int d_protect(void *context, void *address, size_t length, int prot)
{
    (void)context;
    return mprotect(address, length, prot == 0 ? PROT_NONE : prot);
}

static int d_discard(void *context, void *address, size_t length)
{
    (void)context;
    return madvise(address, length, MADV_DONTNEED);
}

static long d_read_at(void *context, int fd, void *buffer, size_t length,
                      long long offset)
{
    (void)context;
    return (long)pread(fd, buffer, length, (off_t)offset);
}

static int d_copy(void *context, void *destination, const void *source,
                  size_t length)
{
    (void)context;
    memmove(destination, source, length);
    return 0;
}

static int d_write(void *context, void *destination, const void *source,
                   size_t length)
{
    (void)context;
    memcpy(destination, source, length);
    return 0;
}

static int d_read(void *context, void *destination, const void *source,
                  size_t length)
{
    (void)context;
    memcpy(destination, source, length);
    return 0;
}

static void d_flush(void *context, void *address, size_t length)
{
    (void)context;
    sys_icache_invalidate(address, length);
}

static void *d_alloc(void *context, size_t length)
{
    (void)context;
    return calloc(1, length);
}

static void d_dealloc(void *context, void *pointer, size_t length)
{
    (void)context;
    (void)length;
    free(pointer);
}

struct v2_host v2_host_darwin(void)
{
    struct v2_host host;

    memset(&host, 0, sizeof(host));
    host.reserve = d_reserve;
    host.release = d_release;
    host.commit = d_commit;
    host.decommit = d_decommit;
    host.protect = d_protect;
    host.discard = d_discard;
    host.read_at = d_read_at;
    host.copy = d_copy;
    host.write = d_write;
    host.read = d_read;
    host.flush_icache = d_flush;
    host.alloc = d_alloc;
    host.dealloc = d_dealloc;
    return host;
}

#endif /* __APPLE__ */
