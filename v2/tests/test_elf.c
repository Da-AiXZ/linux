/*
 * v2/tests/test_elf.c -- the loader and the patcher, without a device.
 *
 * Builds a synthetic aarch64 ELF on disk (two PT_LOAD segments, one svc, one
 * mrs, one msr), loads it into a fake address space and checks:
 *
 *   - parse: segments, entry, min/max
 *   - load:  every byte landed, entry = base + e_entry
 *   - patch: the three sites became `b`, the stubs carry entry and site,
 *            and the branch target really is the stub
 *   - protect: RX page, RW page, PROT_NONE gap, and the sealed island
 */
#define _POSIX_C_SOURCE 200809L
#include "v2/elf.h"
#include "v2/patch.h"
#include "v2/vspace.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#define V2_OPEN(path) _open(path, _O_RDONLY | _O_BINARY)
#define V2_CLOSE(fd)  _close(fd)
#else
#include <fcntl.h>
#include <unistd.h>
#define V2_OPEN(path) open(path, O_RDONLY)
#define V2_CLOSE(fd)  close(fd)
#endif

static unsigned g_checks = 0;

static void fail(const char *file, int line, const char *format, ...)
{
    va_list arguments;

    printf("%s:%d: ", file, line);
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

/* ------------------------------------------------------------------ host */

struct fake {
    uint8_t *memory;
    uint8_t *shadow;
    size_t pages;
    size_t page_size;
    uintptr_t base;
};

static size_t index_of(struct fake *fake, const void *address)
{
    uintptr_t offset = (uintptr_t)address - fake->base;
    CHECK(offset % fake->page_size == 0);
    CHECK(offset / fake->page_size < fake->pages);
    return (size_t)(offset / fake->page_size);
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
    struct fake *fake = (struct fake *)context;
    size_t first = index_of(fake, address);
    size_t count = length / fake->page_size;

    for (size_t page = first; page < first + count; page++) {
        CHECK(fake->shadow[page] == V2_PAGE_FREE);
        fake->shadow[page] =
            (uint8_t)(V2_PAGE_MAPPED | (prot & V2_PAGE_PROT_MASK));
    }
    return 0;
}

static int host_decommit(void *context, void *address, size_t length)
{
    struct fake *fake = (struct fake *)context;
    size_t first = index_of(fake, address);
    size_t count = length / fake->page_size;

    for (size_t page = first; page < first + count; page++) {
        CHECK((fake->shadow[page] & V2_PAGE_MAPPED) != 0);
        fake->shadow[page] = V2_PAGE_FREE;
    }
    return 0;
}

static int host_protect(void *context, void *address, size_t length, int prot)
{
    struct fake *fake = (struct fake *)context;
    size_t first = index_of(fake, address);
    size_t count = length / fake->page_size;

    for (size_t page = first; page < first + count; page++) {
        CHECK((fake->shadow[page] & V2_PAGE_MAPPED) != 0);
        fake->shadow[page] =
            (uint8_t)(V2_PAGE_MAPPED | (prot & V2_PAGE_PROT_MASK));
    }
    return 0;
}

static int host_discard(void *context, void *address, size_t length)
{
    struct fake *fake = (struct fake *)context;
    size_t first = index_of(fake, address);
    size_t count = length / fake->page_size;

    memset(fake->memory + first * fake->page_size, 0, count * fake->page_size);
    return 0;
}

static long host_read_at(void *context, int fd, void *buffer, size_t length,
                         long long offset)
{
    (void)context;
#if defined(_WIN32)
    if (_lseeki64(fd, offset, SEEK_SET) != offset) {
        return -1;
    }
    return (long)_read(fd, buffer, (unsigned int)length);
#else
    return (long)pread(fd, buffer, length, (off_t)offset);
#endif
}

static int offset_ok(struct fake *fake, const void *address, size_t length)
{
    uintptr_t offset = (uintptr_t)address - fake->base;

    CHECK(offset < fake->pages * fake->page_size);
    CHECK(offset + length <= fake->pages * fake->page_size);
    return 0;
}

static int host_copy(void *context, void *destination, const void *source,
                     size_t length)
{
    struct fake *fake = (struct fake *)context;

    offset_ok(fake, destination, length);
    offset_ok(fake, source, length);
    memmove(fake->memory + ((uintptr_t)destination - fake->base),
            fake->memory + ((uintptr_t)source - fake->base), length);
    return 0;
}

static int host_write(void *context, void *destination, const void *source,
                      size_t length)
{
    struct fake *fake = (struct fake *)context;

    offset_ok(fake, destination, length);
    memcpy(fake->memory + ((uintptr_t)destination - fake->base), source, length);
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
    return malloc(length);
}

static void host_dealloc(void *context, void *pointer, size_t length)
{
    (void)context;
    (void)length;
    free(pointer);
}

static struct v2_host make_host(struct fake *fake)
{
    struct v2_host host;

    memset(&host, 0, sizeof(host));
    host.ctx = fake;
    host.reserve = host_reserve;
    host.release = host_release;
    host.commit = host_commit;
    host.decommit = host_decommit;
    host.protect = host_protect;
    host.discard = host_discard;
    host.read_at = host_read_at;
    host.copy = host_copy;
    host.write = host_write;
    host.flush_icache = host_flush;
    host.alloc = host_alloc;
    host.dealloc = host_dealloc;
    return host;
}

/* ------------------------------------------------------------- synthetic */

static void put32(uint8_t *at, uint32_t value) { memcpy(at, &value, 4); }
static void put16(uint8_t *at, uint16_t value) { memcpy(at, &value, 2); }
static void put64(uint8_t *at, uint64_t value) { memcpy(at, &value, 8); }

static void build_elf(const char *path)
{
    uint8_t file[0x2040];
    uint8_t *phdr;

    memset(file, 0, sizeof(file));
    memcpy(file, "\x7f" "ELF", 4);
    file[4] = 2;          /* ELF64 */
    file[5] = 1;          /* little endian */
    file[6] = 1;          /* version */

    put16(file + 16, 3);          /* e_type = ET_DYN */
    put16(file + 18, V2_ELF_EM_AARCH64);
    put32(file + 20, 1);          /* e_version */
    put64(file + 24, 0x10);       /* e_entry */
    put64(file + 32, 64);         /* e_phoff */
    put16(file + 52, 64);         /* e_ehsize */
    put16(file + 54, 56);         /* e_phentsize */
    put16(file + 56, 2);          /* e_phnum */

    phdr = file + 64;
    put32(phdr + 0, 1);           /* PT_LOAD */
    put32(phdr + 4, 5);           /* R | X */
    put64(phdr + 8, 0x1000);      /* p_offset */
    put64(phdr + 16, 0);          /* p_vaddr */
    put64(phdr + 32, 0x100);      /* p_filesz */
    put64(phdr + 40, 0x100);      /* p_memsz */
    put64(phdr + 48, 0x1000);     /* p_align */

    phdr = file + 64 + 56;
    put32(phdr + 0, 1);           /* PT_LOAD */
    put32(phdr + 4, 6);           /* R | W */
    put64(phdr + 8, 0x2000);      /* p_offset */
    put64(phdr + 16, 0x8000);     /* p_vaddr */
    put64(phdr + 32, 0x40);       /* p_filesz */
    put64(phdr + 40, 0x400);      /* p_memsz */
    put64(phdr + 48, 0x1000);     /* p_align */

    for (size_t index = 0; index < 0x100; index += 4) {
        put32(file + 0x1000 + index, 0xD503201Fu);   /* nop */
    }
    put32(file + 0x1020, V2_ARM64_SVC0);
    put32(file + 0x1040, V2_ARM64_MRS_TPIDR | 3u);   /* mrs x3, tpidr_el0 */
    put32(file + 0x1044, V2_ARM64_MSR_TPIDR | 5u);   /* msr tpidr_el0, x5 */
    for (size_t index = 0; index < 0x40; index += 4) {
        put32(file + 0x2000 + index, 0xAAAA0000u + (uint32_t)index);
    }

    FILE *handle = fopen(path, "wb");
    CHECK(handle != NULL);
    CHECK(fwrite(file, 1, sizeof(file), handle) == sizeof(file));
    CHECK(fclose(handle) == 0);
}


static uint64_t branch_target(uint32_t word, uint64_t site)
{
    int64_t delta = (int64_t)(word & 0x03FFFFFFu);

    if ((delta & 0x02000000) != 0) {
        delta -= 0x04000000;
    }
    return site + (uint64_t)(delta * 4);
}

static uint32_t word_at(struct fake *fake, uint64_t address)
{
    uint32_t value;

    memcpy(&value, fake->memory + (address - fake->base), sizeof(value));
    return value;
}

int main(void)
{
    struct fake fake;
    struct v2_host host;
    struct v2_space *space = NULL;
    struct v2_elf_image image;
    struct v2_elf_load load;
    struct v2_patcher patcher;
    char error[160] = "";
    const char *path = "build/test-elf.bin";
    uint8_t *file;
    long file_size;
    int fd;
    FILE *handle;
    uint64_t svc_site;
    uint32_t word;
    int status;

    fake.page_size = 0x4000;
    fake.pages = 64;
    fake.base = 0x140000000ULL;
    host = make_host(&fake);
    fake.memory = (uint8_t *)calloc(fake.pages, fake.page_size);
    fake.shadow = (uint8_t *)calloc(fake.pages, 1);
    CHECK(fake.memory != NULL && fake.shadow != NULL);

    build_elf(path);

    handle = fopen(path, "rb");
    CHECK(handle != NULL);
    CHECK(fseek(handle, 0, SEEK_END) == 0);
    file_size = ftell(handle);
    CHECK(file_size > 0);
    CHECK(fseek(handle, 0, SEEK_SET) == 0);
    file = (uint8_t *)malloc((size_t)file_size);
    CHECK(file != NULL);
    CHECK(fread(file, 1, (size_t)file_size, handle) == (size_t)file_size);
    CHECK(fclose(handle) == 0);

    status = v2_elf_parse(file, (size_t)file_size, &image, error, sizeof(error));
    if (status != 0) {
        fail(__FILE__, __LINE__, "parse: %s", error);
    }
    CHECK(image.type == V2_ELF_ET_DYN);
    CHECK(image.machine == V2_ELF_EM_AARCH64);
    CHECK(image.segment_count == 2);
    CHECK(image.min_vaddr == 0);
    CHECK(image.max_vaddr == 0x8400);
    CHECK(image.entry == 0x10);
    CHECK(image.segments[0].flags == (V2_PROT_READ | V2_PROT_EXEC));
    CHECK(image.segments[1].flags == (V2_PROT_READ | V2_PROT_WRITE));
    CHECK(image.has_interp == 0);
    printf("parse   ok  segments=%d span=0x%llx\n", image.segment_count,
           (unsigned long long)(image.max_vaddr - image.min_vaddr));

    CHECK(v2_space_create(&space, &host, fake.pages * fake.page_size,
                          fake.page_size, 0x4000000, 0x10000) == 0);
    v2_patch_init(&patcher, space);
    CHECK(patcher.island_count >= 1);
    patcher.entry_svc = 0x1000;
    patcher.entry_mrs = 0x2000;
    patcher.entry_msr = 0x3000;

    fd = V2_OPEN(path);
    CHECK(fd >= 0);
    status = v2_elf_load(space, fd, &image, 0, &patcher, &load, error,
                         sizeof(error));
    if (status != 0) {
        fail(__FILE__, __LINE__, "load: %s", error);
    }
    V2_CLOSE(fd);
    CHECK(load.start % fake.page_size == 0);
    CHECK(load.base == load.start);
    CHECK(load.entry == load.start + 0x10);
    CHECK(load.span == 0xC000);
    printf("load    ok  start=0x%llx entry=0x%llx span=0x%llx\n",
           (unsigned long long)load.start, (unsigned long long)load.entry,
           (unsigned long long)load.span);

    CHECK(patcher.counts[V2_PATCH_SVC] == 1);
    CHECK(patcher.counts[V2_PATCH_MRS] == 1);
    CHECK(patcher.counts[V2_PATCH_MSR] == 1);
    CHECK(patcher.site_count == 3);

    svc_site = load.start + 0x20;
    word = word_at(&fake, svc_site);
    CHECK((word & 0xFC000000u) == 0x14000000u);      /* b */
    {
        uint64_t stub = branch_target(word, svc_site);
        const struct v2_patch_site *site = v2_patch_find(&patcher, svc_site);
        uint64_t entry_literal = 0;
        uint64_t site_literal = 0;

        CHECK(site != NULL);
        CHECK(site->kind == V2_PATCH_SVC);
        CHECK(site->stub == stub);
        CHECK(site->original == V2_ARM64_SVC0);
        CHECK(word_at(&fake, stub + 0) == 0x58000090u);
        CHECK(word_at(&fake, stub + 4) == 0x58000071u);
        CHECK(word_at(&fake, stub + 8) == 0xD61F0200u);
        CHECK(word_at(&fake, stub + 12) == 0xD4200000u);
        memcpy(&entry_literal, fake.memory + (stub + 16 - fake.base), 8);
        memcpy(&site_literal, fake.memory + (stub + 24 - fake.base), 8);
        CHECK(entry_literal == 0x1000);
        CHECK(site_literal == svc_site);
    }
    {
        const struct v2_patch_site *mrs = v2_patch_find(&patcher,
                                                        load.start + 0x40);
        const struct v2_patch_site *msr = v2_patch_find(&patcher,
                                                        load.start + 0x44);
        CHECK(mrs != NULL && mrs->kind == V2_PATCH_MRS && mrs->reg == 3);
        CHECK(msr != NULL && msr->kind == V2_PATCH_MSR && msr->reg == 5);
    }
    printf("patch   ok  svc=%u mrs=%u msr=%u sites=%d\n",
           patcher.counts[V2_PATCH_SVC], patcher.counts[V2_PATCH_MRS],
           patcher.counts[V2_PATCH_MSR], patcher.site_count);

    status = v2_elf_protect(space, &image, &load, error, sizeof(error));
    if (status != 0) {
        fail(__FILE__, __LINE__, "protect: %s", error);
    }
    CHECK(v2_space_state_at(space, (void *)(uintptr_t)(load.start)) ==
          (V2_PAGE_MAPPED | V2_PROT_READ | V2_PROT_EXEC));
    CHECK(v2_space_state_at(space, (void *)(uintptr_t)(load.start + 0x4000)) ==
          (V2_PAGE_MAPPED | V2_PROT_NONE));
    CHECK(v2_space_state_at(space, (void *)(uintptr_t)(load.start + 0x8000)) ==
          (V2_PAGE_MAPPED | V2_PROT_READ | V2_PROT_WRITE));
    printf("protect ok  rx / none / rw as declared\n");

    status = v2_patch_seal(&patcher, error, sizeof(error));
    if (status != 0) {
        fail(__FILE__, __LINE__, "seal: %s", error);
    }
    CHECK(v2_space_state_at(space, (void *)(uintptr_t)fake.base) ==
          (V2_PAGE_MAPPED | V2_PROT_READ | V2_PROT_EXEC));
    CHECK(v2_space_check(space, (void *)(uintptr_t)fake.base, 0x10000,
                         V2_PROT_EXEC) == 0);
    CHECK(v2_space_check(space, (void *)(uintptr_t)(load.start + 0x4000), 1,
                         V2_PROT_READ) == -V2_EFAULT);
    printf("seal    ok  island is read-execute, gap page is not readable\n");

    free(file);
    v2_space_destroy(space);
    free(fake.memory);
    free(fake.shadow);
    printf("all checks passed (%u assertions)\n", g_checks);
    return 0;
}
