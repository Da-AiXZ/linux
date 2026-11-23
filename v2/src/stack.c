/*
 * v2/stack.c -- the initial stack: argv, envp, auxv.
 *
 * musl reads AT_PAGESZ, AT_RANDOM and AT_PHDR before it runs a single line
 * of the program, so getting this wrong looks like "my binary crashes before
 * main" with no other symptom.  The block is built downward from the stack
 * top and then shifted once so sp lands 16-byte aligned.
 */
#include "v2/stack.h"

#include <stdio.h>
#include <string.h>

#include "v2/vspace.h"

static int stack_fail(const char *what, uint64_t where, size_t length,
                      int status)
{
    fprintf(stderr, "[v2] stack: %s at 0x%llx len=0x%zx status=%d\n", what,
            (unsigned long long)where, length, status);
    return -1;
}

static int push_bytes(v2_space *space, uint64_t *cursor, const void *source,
                      size_t length)
{
    *cursor -= length;
    *cursor &= ~7ULL;
    {
        int status = v2_space_write(space, (void *)(uintptr_t)*cursor, source,
                                    length);

        if (status != 0) {
            return stack_fail("write", *cursor, length, status);
        }
    }
    return 0;
}

static int push_u64(v2_space *space, uint64_t *cursor, uint64_t value)
{
    return push_bytes(space, cursor, &value, sizeof(value));
}

uint64_t v2_stack_build(v2_space *space, uint64_t top, int argc,
                        char *const argv[], int envc, char *const envp[],
                        const struct v2_auxv *aux)
{
    uint64_t cursor = top;
    uint64_t argv_address[V2_STACK_MAX_ARGS];
    uint64_t envp_address[V2_STACK_MAX_ARGS];
    uint64_t block_start;
    uint64_t block_length;
    uint64_t array_top;
    uint64_t random[2] = {0x9E3779B97F4A7C15ULL, 0xC2B2AE3D27D4EB4FULL};
    uint64_t execfn_address;
    uint8_t backup[2048];
    uint64_t aligned;
    int pairs = 0;

    if (argc < 0 || argc > V2_STACK_MAX_ARGS ||
        envc < 0 || envc > V2_STACK_MAX_ARGS) {
        stack_fail("argc/envc", (uint64_t)argc, (size_t)envc, 0);
        return 0;
    }

    /* execfn goes highest: AT_EXECFN points at it and nothing moves it. */
    if (push_bytes(space, &cursor, aux->execfn, strlen(aux->execfn) + 1) != 0) {
        return 0;
    }
    execfn_address = cursor;
    for (int index = envc - 1; index >= 0; index--) {
        if (push_bytes(space, &cursor, envp[index], strlen(envp[index]) + 1) != 0) {
            return 0;
        }
        envp_address[index] = cursor;
    }
    for (int index = argc - 1; index >= 0; index--) {
        if (push_bytes(space, &cursor, argv[index], strlen(argv[index]) + 1) != 0) {
            return 0;
        }
        argv_address[index] = cursor;
    }

    /* 16 bytes of randomness for AT_RANDOM (musl derives the canary). */
    if (push_bytes(space, &cursor, random, sizeof(random)) != 0) {
        return 0;
    }
    random[0] = cursor;

    cursor &= ~15ULL;
    array_top = cursor;

    if (push_u64(space, &cursor, 0) != 0) {              /* AT_NULL */
        return 0;
    }
    if (push_u64(space, &cursor, 0) != 0) {
        return 0;
    }
    if (push_u64(space, &cursor, execfn_address) != 0 ||
        push_u64(space, &cursor, 31 /* AT_EXECFN */) != 0) {
        return 0;
    }
    pairs++;
    if (push_u64(space, &cursor, random[0]) != 0 ||
        push_u64(space, &cursor, 25 /* AT_RANDOM */) != 0) {
        return 0;
    }
    pairs++;
    if (push_u64(space, &cursor, aux->hwcap) != 0 ||
        push_u64(space, &cursor, 16 /* AT_HWCAP */) != 0) {
        return 0;
    }
    pairs++;
    if (push_u64(space, &cursor, aux->base) != 0 ||
        push_u64(space, &cursor, 7 /* AT_BASE */) != 0) {
        return 0;
    }
    pairs++;
    if (push_u64(space, &cursor, aux->entry) != 0 ||
        push_u64(space, &cursor, 9 /* AT_ENTRY */) != 0) {
        return 0;
    }
    pairs++;
    if (push_u64(space, &cursor, aux->phent) != 0 ||
        push_u64(space, &cursor, 11 /* AT_PHENT */) != 0) {
        return 0;
    }
    pairs++;
    if (push_u64(space, &cursor, aux->phnum) != 0 ||
        push_u64(space, &cursor, 10 /* AT_PHNUM */) != 0) {
        return 0;
    }
    pairs++;
    if (push_u64(space, &cursor, aux->phdr) != 0 ||
        push_u64(space, &cursor, 3 /* AT_PHDR */) != 0) {
        return 0;
    }
    pairs++;
    if (push_u64(space, &cursor, aux->pagesz) != 0 ||
        push_u64(space, &cursor, 6 /* AT_PAGESZ */) != 0) {
        return 0;
    }
    pairs++;
    (void)pairs;

    if (push_u64(space, &cursor, 0) != 0) {              /* envp terminator */
        return 0;
    }
    for (int index = envc - 1; index >= 0; index--) {
        if (push_u64(space, &cursor, envp_address[index]) != 0) {
            return 0;
        }
    }
    if (push_u64(space, &cursor, 0) != 0) {              /* argv terminator */
        return 0;
    }
    for (int index = argc - 1; index >= 0; index--) {
        if (push_u64(space, &cursor, argv_address[index]) != 0) {
            return 0;
        }
    }
    if (push_u64(space, &cursor, (uint64_t)argc) != 0) {
        return 0;
    }

    /*
     * argc is 8 bytes, so the array is 16-aligned only for some argc/envc
     * combinations.  Shift *the pointer array* down by 16 when needed, never
     * the strings: the pointers inside the array point up into the strings,
     * and moving those would invalidate every one of them (the first run of
     * this test caught exactly that).
     */
    block_start = cursor;
    block_length = array_top - cursor;
    if ((cursor & 15ULL) == 0) {
        return cursor;
    }
    if (block_length > sizeof(backup)) {
        stack_fail("block too large", block_start, (size_t)block_length, 0);
        return 0;
    }
    {
        int status = v2_space_read(space, backup,
                                   (const void *)(uintptr_t)block_start,
                                   (size_t)block_length);

        if (status != 0) {
            stack_fail("read", block_start, (size_t)block_length, status);
            return 0;
        }
    }
    aligned = (cursor & ~15ULL) - 16;
    {
        int status = v2_space_write(space, (void *)(uintptr_t)aligned, backup,
                                    (size_t)block_length);

        if (status != 0) {
            stack_fail("shift", aligned, (size_t)block_length, status);
            return 0;
        }
    }
    return aligned;
}
