/*
 * v2/elf.h -- ELF64 little-endian aarch64: parse, map, protect.
 *
 * Three phases, deliberately separate because the middle one has to write to
 * pages that are still writable:
 *
 *   1. v2_elf_load    map the span RW, copy every PT_LOAD in
 *   2. v2_patch_*     rewrite svc / mrs / msr (see patch.h)
 *   3. v2_elf_protect compute the per-page union of segment flags, apply once
 *
 * v1 interleaved the three and ended up mprotecting pages it had already
 * patched, or patching pages it had already sealed.
 */
#ifndef V2_ELF_H
#define V2_ELF_H

#include <stddef.h>
#include <stdint.h>

#include "v2/vspace.h"

struct v2_patcher;

#define V2_ELF_MAX_SEGMENTS 12
#define V2_ELF_INTERP_MAX   192

#define V2_ELF_ET_EXEC 2
#define V2_ELF_ET_DYN  3
#define V2_ELF_EM_AARCH64 183

struct v2_elf_segment {
    uint64_t vaddr;
    uint64_t offset;
    uint64_t filesz;
    uint64_t memsz;
    uint32_t flags;    /* V2_PROT_* numbering, straight from p_flags */
};

struct v2_elf_image {
    uint16_t type;
    uint16_t machine;
    uint64_t entry;
    uint64_t min_vaddr;
    uint64_t max_vaddr;
    uint64_t phoff;
    uint16_t phnum;
    uint16_t phentsize;
    int segment_count;
    struct v2_elf_segment segments[V2_ELF_MAX_SEGMENTS];

    int has_interp;
    char interp[V2_ELF_INTERP_MAX];

    int has_tls;
    uint64_t tls_vaddr;
    uint64_t tls_filesz;
    uint64_t tls_memsz;
    uint64_t tls_align;
};

struct v2_elf_load {
    uint64_t base;     /* mapped_start - min_vaddr; add to any vaddr */
    uint64_t start;    /* first mapped address */
    uint64_t span;     /* mapped length, page aligned */
    uint64_t entry;    /* base + image->entry */
};

/* Returns 0 or -errno; `error` always gets a human readable reason. */
int v2_elf_parse(const void *file, size_t length, struct v2_elf_image *image,
                 char *error, size_t error_size);

int v2_elf_load(v2_space *space, int fd, const struct v2_elf_image *image,
                uint64_t base_hint, struct v2_patcher *patcher,
                struct v2_elf_load *out, char *error, size_t error_size);

/* Apply the final per-page protections and flush the instruction cache. */
int v2_elf_protect(v2_space *space, const struct v2_elf_image *image,
                   const struct v2_elf_load *load, char *error,
                   size_t error_size);

#endif /* V2_ELF_H */
