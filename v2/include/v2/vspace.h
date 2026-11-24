/*
 * v2/vspace.h -- the guest address space.
 *
 * One reservation, one page array, one truth.  Everything the guest can
 * name lives inside `base .. base+length`, at page granularity equal to the
 * host page size, so a guest page is never shared with a neighbour and no
 * operation ever needs to reason about "part of a host page".
 *
 * The v1 runtime kept a linear record array beside the host's own mapping
 * table and had to reconcile the two on every call; that is the bug this
 * file exists to make impossible.
 */
#ifndef V2_VSPACE_H
#define V2_VSPACE_H

#include <stddef.h>
#include <stdint.h>

/* Linux protection bits, deliberately identical to the guest ABI. */
#define V2_PROT_NONE  0
#define V2_PROT_READ  1
#define V2_PROT_WRITE 2
#define V2_PROT_EXEC  4

/* Linux arm64 mmap flags that matter here. */
#define V2_MAP_FIXED           0x10
#define V2_MAP_ANON            0x20
#define V2_MAP_FIXED_NOREPLACE 0x100000

#define V2_MREMAP_MAYMOVE 0x1
#define V2_MREMAP_FIXED   0x2

/* Per-page state.  A page is either free, reserved for the trampoline
 * islands, or mapped with a protection.  There is no fourth state. */
#define V2_PAGE_FREE      0x00
#define V2_PAGE_RESERVED  0x80
#define V2_PAGE_MAPPED    0x10
#define V2_PAGE_PROT_MASK 0x07

/* Linux errno values used by this layer. */
#define V2_ENOENT  2
#define V2_EIO     5
#define V2_EBADF   9
#define V2_EACCES 13
#define V2_ENOMEM 12
#define V2_EFAULT 14
#define V2_EEXIST 17
#define V2_ENOTDIR 20
#define V2_EISDIR  21
#define V2_EINVAL 22
#define V2_EMFILE  24
#define V2_ENOTTY  25
#define V2_ENAMETOOLONG 36
#define V2_ENOSYS 38
#define V2_ERANGE 34

/*
 * Host operations.  The address space owns no platform header; the Darwin
 * glue implements these with mmap/mprotect/madvise/pread, the test harness
 * implements them with a shadow array and asserts that the two never
 * disagree.
 */
struct v2_host {
    void *ctx;

    /* Reserve `length` bytes of PROT_NONE address space.  Must return a
     * page-aligned base inside the process address space. */
    int (*reserve)(void *ctx, size_t length, void **base);
    void (*release)(void *ctx, void *base, size_t length);

    /* Make pages usable with `prot`.  Only ever called on pages that are
     * currently free from the space's point of view; the harness asserts
     * this, because "commit over a live page" is exactly the v1 failure. */
    int (*commit)(void *ctx, void *addr, size_t length, int prot);

    /* Return pages to the reserved-but-uncommitted state.  Contents are
     * discarded. */
    int (*decommit)(void *ctx, void *addr, size_t length);

    /* Change the protection of pages that are already committed. */
    int (*protect)(void *ctx, void *addr, size_t length, int prot);

    /* Discard contents but keep the pages committed (MADV_DONTNEED). */
    int (*discard)(void *ctx, void *addr, size_t length);

    /* Read exactly `length` bytes or return a short count. */
    long (*read_at)(void *ctx, int fd, void *buffer, size_t length,
                    long long offset);

    /*
     * Move `length` bytes between two guest addresses.  The address space
     * never dereferences a guest pointer itself: on the device the pages are
     * identity-mapped so this is memmove, but the contract has to be explicit
     * or the whole layer silently assumes a host layout it cannot guarantee.
     */
    int (*copy)(void *ctx, void *destination, const void *source,
                size_t length);

    /* Copy host memory into a guest range (ELF segments, stack, argv). */
    int (*write)(void *ctx, void *destination, const void *source,
                 size_t length);
    /* Copy a guest range out to host memory (syscall arguments). */
    int (*read)(void *ctx, void *destination, const void *source,
                size_t length);

    /* Make freshly written code visible to the instruction fetch unit. */
    void (*flush_icache)(void *ctx, void *address, size_t length);

    /*
     * Metadata allocation.  Deliberately separate from the C heap: the page
     * array must never share an arena with anything the guest can reach.
     */
    void *(*alloc)(void *ctx, size_t length);
    void (*dealloc)(void *ctx, void *pointer, size_t length);
};

typedef struct v2_space v2_space;

/*
 * `length` is rounded up to a whole number of pages.  `island_stride` of 0
 * disables the trampoline islands.  Returns 0 or a negative errno.
 */
int v2_space_create(v2_space **out, const struct v2_host *host,
                    size_t length, size_t page_size,
                    size_t island_stride, size_t island_size);
void v2_space_destroy(v2_space *space);

void *v2_space_base(const v2_space *space);
size_t v2_space_length(const v2_space *space);
size_t v2_space_page_size(const v2_space *space);
size_t v2_space_page_count(const v2_space *space);
size_t v2_space_island_stride(const v2_space *space);
size_t v2_space_island_size(const v2_space *space);

/*
 * Checked copies across the guest boundary.  Both validate the range against
 * the page table first, so a wild pointer becomes -EFAULT instead of a host
 * fault that kills the runtime.
 */
int v2_space_read(const v2_space *space, void *destination,
                  const void *source, size_t length);
int v2_space_write(const v2_space *space, void *destination,
                   const void *source, size_t length);

/* The host operations this space was built with.  Loaders need read_at and
 * write; keeping the struct opaque and exposing one const pointer is less
 * error prone than handing out the whole space. */
const struct v2_host *v2_space_host(const v2_space *space);

/*
 * Take ownership of a range that was reserved at creation (a trampoline
 * island).  Refuses anything that is not entirely RESERVED, so a stale
 * address cannot silently become writable.
 */
long long v2_space_claim(v2_space *space, void *addr, size_t length, int prot);

/*
 * Diagnostic: keep `pages` unused pages immediately after every first-fit
 * allocation.  A guard page is never committed, stays PROT_NONE, and is never
 * handed out by the allocator, so a write past the end of a mapping faults
 * inside our own reservation instead of landing in the next mapping's first
 * page -- which is the failure mode V2_VERIFY cannot see, because the bytes
 * are written after the mapping was verified.
 *
 * The guard is a diagnostic, not a constraint: a mapping that only fits
 * without one is still allowed, and a MAP_FIXED that names a guard page wins
 * (the guest asked for that address explicitly).  Default off, so traces and
 * the model comparison are unaffected.
 */
int v2_space_set_guard(v2_space *space, size_t pages);
/* Non-zero when the page containing `addr` is currently a guard page. */
int v2_space_guard_at(const v2_space *space, const void *addr);

/* All return an address, 0, or a negative errno. */
long long v2_space_map(v2_space *space, void *hint, size_t length, int prot,
                       int flags, int fd, long long offset);
long long v2_space_unmap(v2_space *space, void *addr, size_t length);
long long v2_space_protect(v2_space *space, void *addr, size_t length,
                           int prot);
long long v2_space_remap(v2_space *space, void *addr, size_t old_length,
                         size_t new_length, int flags);
long long v2_space_advise(v2_space *space, void *addr, size_t length,
                          int advice);

#define V2_MADV_DONTNEED 4
#define V2_MADV_FREE     8

/*
 * Guest pointer validation.  Every copyin/copyout goes through this, so a
 * wild pointer becomes EFAULT instead of a host SIGSEGV that takes the
 * runtime with it.
 */
int v2_space_check(const v2_space *space, const void *addr, size_t length,
                   int need_prot);
int v2_space_state_at(const v2_space *space, const void *addr);

uint64_t v2_space_hash(const v2_space *space);
int v2_space_verify(const v2_space *space);

#endif /* V2_VSPACE_H */
