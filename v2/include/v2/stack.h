/*
 * v2/stack.h -- initial process stack.
 */
#ifndef V2_STACK_H
#define V2_STACK_H

#include <stdint.h>

#include "v2/vspace.h"

#define V2_STACK_MAX_ARGS 64

struct v2_auxv {
    uint64_t phdr;
    uint64_t phnum;
    uint64_t phent;
    uint64_t entry;
    uint64_t base;
    uint64_t pagesz;
    uint64_t hwcap;
    const char *execfn;
};

/* Returns the guest sp, or 0 on failure. */
uint64_t v2_stack_build(v2_space *space, uint64_t top, int argc,
                        char *const argv[], int envc, char *const envp[],
                        const struct v2_auxv *aux);

#endif /* V2_STACK_H */
