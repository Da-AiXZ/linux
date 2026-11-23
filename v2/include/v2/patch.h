/*
 * v2/patch.h -- rewrite the three instructions that cannot run as-is.
 *
 *   svc #0                 would enter the Darwin syscall table
 *   mrs Xt, tpidr_el0      reads a register the host runtime owns
 *   msr tpidr_el0, Xt      writes it
 *
 * Each site becomes `b stub`, and the stub carries its own entry point and
 * site address in a literal pool.  `b` is essential: `bl` would set x30 to
 * site+4 and destroy the guest's return address, which is exactly how v1
 * broke musl's leaf `__set_thread_area`.
 *
 * The site address is passed explicitly because `b` preserves no link -- the
 * dispatcher has no other way to know where to return.  That also means the
 * stub has to live within +/-128 MiB of the site, hence one island per
 * 16 MiB zone inside the single reservation.
 */
#ifndef V2_PATCH_H
#define V2_PATCH_H

#include <stddef.h>
#include <stdint.h>

#include "v2/elf.h"
#include "v2/vspace.h"

#define V2_PATCH_STUB_SIZE   32
#define V2_PATCH_MAX_SITES   4096
#define V2_PATCH_MAX_ISLANDS 64

#define V2_PATCH_SVC 1
#define V2_PATCH_MRS 2
#define V2_PATCH_MSR 3

#define V2_ARM64_SVC0       0xD4000001u
#define V2_ARM64_MRS_TPIDR  0xD53BD040u   /* | Rt */
#define V2_ARM64_MSR_TPIDR  0xD51BD040u   /* | Rt */

struct v2_patch_site {
    uint64_t address;
    uint64_t stub;
    uint32_t original;
    uint8_t kind;
    uint8_t reg;
};

struct v2_patcher {
    v2_space *space;
    uint64_t space_base;
    size_t stride;
    size_t island_size;
    int island_count;

    /* Where the three rewritten forms jump to; filled in by the runner. */
    uint64_t entry_svc;
    uint64_t entry_mrs;
    uint64_t entry_msr;

    struct {
        uint64_t address;
        uint32_t used;
        int claimed;
    } islands[V2_PATCH_MAX_ISLANDS];

    int site_count;
    int overflow;
    int sealed;
    unsigned counts[4];
    struct v2_patch_site sites[V2_PATCH_MAX_SITES];
};

void v2_patch_init(struct v2_patcher *patcher, v2_space *space);

/*
 * Rewrite one executable segment.  `code` is the segment's bytes as read from
 * the file and `site_base` is the address they will occupy, so the branch
 * displacement can be computed before the bytes are even in guest memory.
 */
int v2_patch_buffer(struct v2_patcher *patcher, uint64_t site_base,
                    uint8_t *code, size_t length, char *error,
                    size_t error_size);

/* Islands go back to read-execute once every image is loaded. */
int v2_patch_seal(struct v2_patcher *patcher, char *error, size_t error_size);

/*
 * Patch a range that appeared *after* startup.
 *
 * A static program carries its own syscalls, so v2_elf_load sees every site.
 * A dynamically linked one does not: ld.so maps libc itself, through our
 * mmap, and libc's text arrives with raw `svc #0` in it.  This is the hook
 * that rewrites those pages while they are briefly writable.
 */
int v2_patch_runtime(struct v2_patcher *patcher, uint64_t address,
                     size_t length, char *error, size_t error_size);

const struct v2_patch_site *v2_patch_find(const struct v2_patcher *patcher,
                                          uint64_t site);

/* Exposed for tests: encode a `b` and emit a stub. */
uint32_t v2_patch_encode_b(uint64_t from, uint64_t to, int *ok);
void v2_patch_emit_stub(uint8_t *out, uint64_t entry, uint64_t site);

#endif /* V2_PATCH_H */
