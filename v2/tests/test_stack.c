/*
 * v2/tests/test_stack.c -- argv/envp/auxv layout, without an aarch64 host.
 *
 * Builds the initial stack in a fake space and reads it back exactly the way
 * the kernel would hand it to a program: argc, argv[], NULL, envp[], NULL,
 * auxv pairs, NULL.  A mistake here looks like "the binary crashes before
 * main", so it is worth checking the bytes and not just the pointer.
 */
#define _POSIX_C_SOURCE 200809L
#include "v2/stack.h"
#include "v2/vspace.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned g_checks = 0;

static void fail(const char *file, int line, const char *format, ...)
{
    va_list arguments;

    fprintf(stderr, "%s:%d: ", file, line);
    va_start(arguments, format);
    vfprintf(stderr, format, arguments);
    va_end(arguments);
    fputc('\n', stderr);
    exit(1);
}

#define CHECK(condition) \
    do { \
        g_checks++; \
        if (!(condition)) { \
            fail(__FILE__, __LINE__, "check failed: %s", #condition); \
        } \
    } while (0)

struct fake {
    uint8_t *memory;
    size_t pages;
    size_t page_size;
    uintptr_t base;
};

static size_t offset_of(struct fake *fake, uint64_t address)
{
    CHECK(address >= fake->base);
    CHECK(address - fake->base < fake->pages * fake->page_size);
    return (size_t)(address - fake->base);
}

static int host_reserve(void *context, size_t length, void **base)
{
    struct fake *fake = (struct fake *)context;
    CHECK(length <= fake->pages * fake->page_size);
    *base = (void *)fake->base;
    return 0;
}

static void host_release(void *context, void *base, size_t length)
{
    (void)context;
    (void)base;
    (void)length;
}

static int host_commit(void *context, void *address, size_t length, int prot)
{
    (void)context;
    (void)address;
    (void)length;
    (void)prot;
    return 0;
}

static int host_decommit(void *context, void *address, size_t length)
{
    (void)context;
    (void)address;
    (void)length;
    return 0;
}

static int host_protect(void *context, void *address, size_t length, int prot)
{
    (void)context;
    (void)address;
    (void)length;
    (void)prot;
    return 0;
}

static int host_discard(void *context, void *address, size_t length)
{
    (void)context;
    (void)address;
    (void)length;
    return 0;
}

static long host_read_at(void *context, int fd, void *buffer, size_t length,
                         long long offset)
{
    (void)context;
    (void)fd;
    (void)buffer;
    (void)length;
    (void)offset;
    return -1;
}

static int host_copy(void *context, void *destination, const void *source,
                     size_t length)
{
    struct fake *fake = (struct fake *)context;

    memmove(fake->memory + offset_of(fake, (uint64_t)(uintptr_t)destination),
            fake->memory + offset_of(fake, (uint64_t)(uintptr_t)source), length);
    return 0;
}

static int host_write(void *context, void *destination, const void *source,
                      size_t length)
{
    struct fake *fake = (struct fake *)context;

    memcpy(fake->memory + offset_of(fake, (uint64_t)(uintptr_t)destination),
           source, length);
    return 0;
}

static int host_read(void *context, void *destination, const void *source,
                     size_t length)
{
    struct fake *fake = (struct fake *)context;

    memcpy(destination,
           fake->memory + offset_of(fake, (uint64_t)(uintptr_t)source),
           length);
    return 0;
}

static void host_flush(void *context, void *address, size_t length)
{
    (void)context;
    (void)address;
    (void)length;
}

static void *host_alloc(void *context, size_t length)
{
    (void)context;
    return calloc(1, length);
}

static void host_dealloc(void *context, void *pointer, size_t length)
{
    (void)context;
    (void)length;
    free(pointer);
}

static uint64_t peek64(struct fake *fake, uint64_t address)
{
    uint64_t value;

    memcpy(&value, fake->memory + offset_of(fake, address), sizeof(value));
    return value;
}

static const char *peek_string(struct fake *fake, uint64_t address)
{
    return (const char *)fake->memory + offset_of(fake, address);
}

int main(void)
{
    struct fake fake;
    struct v2_host host;
    struct v2_space *space = NULL;
    struct v2_auxv aux;
    char *argv[3] = {(char *)"/bin/hello", (char *)"-v", NULL};
    char *envp[3] = {(char *)"PATH=/", (char *)"HOME=/", NULL};
    uint64_t stack;
    uint64_t top;
    uint64_t sp;
    uint64_t argc;
    int status;

    fake.page_size = 0x4000;
    fake.pages = 64;
    fake.base = 0x140000000ULL;
    fake.memory = (uint8_t *)calloc(fake.pages, fake.page_size);
    CHECK(fake.memory != NULL);

    memset(&host, 0, sizeof(host));
    host.ctx = &fake;
    host.reserve = host_reserve;
    host.release = host_release;
    host.commit = host_commit;
    host.decommit = host_decommit;
    host.protect = host_protect;
    host.discard = host_discard;
    host.read_at = host_read_at;
    host.copy = host_copy;
    host.write = host_write;
    host.read = host_read;
    host.flush_icache = host_flush;
    host.alloc = host_alloc;
    host.dealloc = host_dealloc;

    CHECK(v2_space_create(&space, &host, fake.pages * fake.page_size,
                          fake.page_size, 0x4000000, 0x10000) == 0);
    stack = (uint64_t)v2_space_map(space, NULL, 8 * fake.page_size,
                                   V2_PROT_READ | V2_PROT_WRITE, V2_MAP_ANON,
                                   -1, 0);
    CHECK((int64_t)stack > 0);
    top = stack + 8 * fake.page_size;

    memset(&aux, 0, sizeof(aux));
    aux.phdr = 0x140010000ULL;
    aux.phnum = 7;
    aux.phent = 56;
    aux.entry = 0x140010210ULL;
    aux.base = 0;
    aux.pagesz = fake.page_size;
    aux.hwcap = 0;
    aux.execfn = "/bin/hello";

    sp = v2_stack_build(space, top, 2, argv, 2, envp, &aux);
    CHECK(sp != 0);
    CHECK(sp % 16 == 0);
    CHECK(sp > stack && sp < top);

    argc = peek64(&fake, sp);
    CHECK(argc == 2);
    CHECK(strcmp(peek_string(&fake, peek64(&fake, sp + 8)), "/bin/hello") == 0);
    CHECK(strcmp(peek_string(&fake, peek64(&fake, sp + 16)), "-v") == 0);
    CHECK(peek64(&fake, sp + 24) == 0);

    {
        uint64_t envp0 = peek64(&fake, sp + 32);
        uint64_t envp1 = peek64(&fake, sp + 40);
        uint64_t end = peek64(&fake, sp + 48);

        CHECK(strcmp(peek_string(&fake, envp0), "PATH=/") == 0);
        CHECK(strcmp(peek_string(&fake, envp1), "HOME=/") == 0);
        CHECK(end == 0);
    }

    {
        uint64_t cursor = sp + 56;
        int seen_pagesz = 0;
        int seen_phdr = 0;
        int seen_entry = 0;
        int seen_execfn = 0;
        int seen_random = 0;
        int seen_phent = 0;
        int seen_phnum = 0;
        int seen_null = 0;

        for (int index = 0; index < 16; index++) {
            uint64_t key = peek64(&fake, cursor);
            uint64_t value = peek64(&fake, cursor + 8);

            if (key == 0) {
                seen_null = 1;
                break;
            }
            if (key == 6) {
                CHECK(value == fake.page_size);
                seen_pagesz = 1;
            } else if (key == 3) {
                CHECK(value == 0x140010000ULL);
                seen_phdr = 1;
            } else if (key == 9) {
                CHECK(value == 0x140010210ULL);
                seen_entry = 1;
            } else if (key == 31) {
                CHECK(strcmp(peek_string(&fake, value), "/bin/hello") == 0);
                seen_execfn = 1;
            } else if (key == 25) {
                CHECK(value != 0);
                seen_random = 1;
            } else if (key == 4) {
                /* AT_PHENT.  Its tag is 4, not 11: 10 and 11 are not even
                 * phdr-related, and getting this wrong makes musl compute a
                 * load address of zero and die before main. */
                CHECK(value == aux.phent);
                seen_phent = 1;
            } else if (key == 5) {
                CHECK(value == aux.phnum);   /* AT_PHNUM */
                seen_phnum = 1;
            }
            cursor += 16;
        }
        CHECK(seen_pagesz && seen_phdr && seen_entry && seen_execfn &&
              seen_random && seen_phent && seen_phnum && seen_null);
    }

    /* The whole block must live inside the stack mapping. */
    CHECK(sp >= stack && sp < top);

    status = v2_space_verify(space);
    CHECK(status == 0);

    printf("stack   ok  sp=0x%llx argc=%llu (16-byte aligned, auxv complete)\n",
           (unsigned long long)sp, (unsigned long long)argc);
    printf("all checks passed (%u assertions)\n", g_checks);

    v2_space_destroy(space);
    free(fake.memory);
    return 0;
}
