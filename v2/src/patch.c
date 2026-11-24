/*
 * v2/patch.c -- site scanning and per-site stubs.
 *
 * A site becomes `b stub`.  The stub is 32 bytes:
 *
 *   +0   ldr x16, [pc, #16]     entry point (svc / mrs / msr dispatcher)
 *   +4   ldr x17, [pc, #12]     the site address, so the dispatcher knows
 *                               where to return and can name the caller
 *   +8   br  x16
 *   +12  brk #0                 never reached; a trap if it ever is
 *   +16  .quad entry
 *   +24  .quad site
 *
 * `b` and not `bl`: `bl` writes site+4 into x30 and the guest's return
 * address is gone (v1 broke musl's leaf __set_thread_area exactly this way).
 */
#include "v2/patch.h"

#include <stdlib.h>
#include <string.h>

static void v2_patch_error(char *buffer, size_t size, const char *text)
{
    if (buffer != NULL && size != 0) {
        size_t length = strlen(text);
        if (length >= size) {
            length = size - 1;
        }
        memcpy(buffer, text, length);
        buffer[length] = '\0';
    }
}

uint32_t v2_patch_encode_b(uint64_t from, uint64_t to, int *ok)
{
    int64_t delta = (int64_t)to - (int64_t)from;

    *ok = 0;
    if ((delta & 3) != 0) {
        return 0;
    }
    if (delta < -(1LL << 27) || delta >= (1LL << 27)) {
        return 0;
    }
    *ok = 1;
    return 0x14000000u | ((uint32_t)((delta >> 2) & 0x03FFFFFFu));
}

void v2_patch_emit_stub(uint8_t *out, uint64_t entry, uint64_t site)
{
    uint32_t words[4];

    /*
     * A literal load uses the address of *its own* instruction as the base,
     * not the start of the stub.  The second ldr sits at +4, so reaching the
     * site word at +24 needs #20, not #12.
     *
     * #12 was shipped once and cost a device round trip: x17 came out as the
     * entry point, so the dispatcher "returned" to entry+4 -- four bytes into
     * the middle of the frame-building sequence.  The guest printed its line
     * and died of SIGBUS, which reads exactly like a kernel rejection of
     * executable anonymous memory.  It was not; it was one wrong offset.
     */
    words[0] = 0x58000090u;    /* ldr x16, [pc, #16]  -> +16 (entry) */
    words[1] = 0x580000B1u;    /* ldr x17, [pc, #20]  -> +24 (site)  */
    words[2] = 0xD61F0200u;    /* br  x16             */
    words[3] = 0xD4200000u;    /* brk #0              */
    memcpy(out, words, sizeof(words));
    memcpy(out + 16, &entry, sizeof(entry));
    memcpy(out + 24, &site, sizeof(site));
}

void v2_patch_init(struct v2_patcher *patcher, v2_space *space)
{
    memset(patcher, 0, sizeof(*patcher));
    patcher->space = space;
    patcher->space_base = (uint64_t)(uintptr_t)v2_space_base(space);
    patcher->stride = v2_space_island_stride(space);
    patcher->island_size = v2_space_island_size(space);
    if (patcher->stride != 0) {
        /* Island 0 always exists, even when the space is smaller than one
         * stride; the reservation marks islands while offset < length. */
        size_t count = (v2_space_length(space) + patcher->stride - 1) /
                       patcher->stride;
        if (count == 0) {
            count = 1;
        }
        patcher->island_count =
            count > V2_PATCH_MAX_ISLANDS ? V2_PATCH_MAX_ISLANDS : (int)count;
    }
}

static int v2_island_for(const struct v2_patcher *patcher, uint64_t site)
{
    uint64_t index;

    if (patcher->stride == 0 || site < patcher->space_base) {
        return -1;
    }
    index = (site - patcher->space_base) / patcher->stride;
    if (index >= (uint64_t)patcher->island_count) {
        return -1;
    }
    return (int)index;
}

static int v2_island_open(struct v2_patcher *patcher, int index, char *error,
                          size_t error_size)
{
    uint64_t address = patcher->space_base + (uint64_t)index * patcher->stride;
    long long status;

    if (patcher->islands[index].claimed) {
        return 0;
    }
    status = v2_space_claim(patcher->space, (void *)(uintptr_t)address,
                            patcher->island_size,
                            V2_PROT_READ | V2_PROT_WRITE);
    if (status < 0) {
        /* Already claimed by an earlier image; make it writable again. */
        status = v2_space_protect(patcher->space, (void *)(uintptr_t)address,
                                  patcher->island_size,
                                  V2_PROT_READ | V2_PROT_WRITE);
        if (status < 0) {
            v2_patch_error(error, error_size, "no writable trampoline island");
            return -1;
        }
    }
    patcher->islands[index].address = address;
    patcher->islands[index].claimed = 1;
    return 0;
}

static int v2_stub_alloc(struct v2_patcher *patcher, uint64_t site,
                         uint64_t *out, char *error, size_t error_size)
{
    int index = v2_island_for(patcher, site);
    size_t offset;

    if (index < 0) {
        v2_patch_error(error, error_size, "site is outside every island zone");
        return -1;
    }
    if (v2_island_open(patcher, index, error, error_size) != 0) {
        return -1;
    }
    offset = (size_t)patcher->islands[index].used * V2_PATCH_STUB_SIZE;
    if (offset + V2_PATCH_STUB_SIZE > patcher->island_size) {
        v2_patch_error(error, error_size, "trampoline island is full");
        return -1;
    }
    patcher->islands[index].used++;
    *out = patcher->islands[index].address + offset;
    return 0;
}

int v2_patch_buffer(struct v2_patcher *patcher, uint64_t site_base,
                    uint8_t *code, size_t length, char *error,
                    size_t error_size)
{
    const struct v2_host *host = v2_space_host(patcher->space);

    for (size_t offset = 0; offset + 4 <= length; offset += 4) {
        uint32_t word;
        uint32_t branch;
        uint64_t site;
        uint64_t stub;
        uint64_t entry;
        uint8_t bytes[V2_PATCH_STUB_SIZE];
        int kind = 0;
        int reg = 0;
        int ok = 0;

        memcpy(&word, code + offset, sizeof(word));
        if (word == V2_ARM64_SVC0) {
            kind = V2_PATCH_SVC;
        } else if ((word & 0xFFFFFFE0u) == V2_ARM64_MRS_TPIDR) {
            kind = V2_PATCH_MRS;
            reg = (int)(word & 0x1Fu);
        } else if ((word & 0xFFFFFFE0u) == V2_ARM64_MSR_TPIDR) {
            kind = V2_PATCH_MSR;
            reg = (int)(word & 0x1Fu);
        }
        if (kind == 0) {
            continue;
        }
        if (patcher->site_count >= V2_PATCH_MAX_SITES) {
            patcher->overflow = 1;
            v2_patch_error(error, error_size,
                           "too many patch sites; refusing to leave one raw");
            return -V2_ENOMEM;
        }

        site = site_base + offset;
        if (v2_stub_alloc(patcher, site, &stub, error, error_size) != 0) {
            return -V2_ENOMEM;
        }
        entry = kind == V2_PATCH_SVC ? patcher->entry_svc
              : kind == V2_PATCH_MRS ? patcher->entry_mrs
                                     : patcher->entry_msr;
        v2_patch_emit_stub(bytes, entry, site);
        if (host->write(host->ctx, (void *)(uintptr_t)stub, bytes,
                        sizeof(bytes)) != 0) {
            v2_patch_error(error, error_size, "cannot write a trampoline stub");
            return -V2_EFAULT;
        }

        branch = v2_patch_encode_b(site, stub, &ok);
        if (!ok) {
            v2_patch_error(error, error_size, "stub is out of branch range");
            return -V2_EINVAL;
        }
        memcpy(code + offset, &branch, sizeof(branch));

        patcher->sites[patcher->site_count].address = site;
        patcher->sites[patcher->site_count].stub = stub;
        patcher->sites[patcher->site_count].original = word;
        patcher->sites[patcher->site_count].kind = (uint8_t)kind;
        patcher->sites[patcher->site_count].reg = (uint8_t)reg;
        patcher->site_count++;
        patcher->counts[kind]++;
    }
    return 0;
}

static int set_islands(struct v2_patcher *patcher, int prot, char *error,
                       size_t error_size)
{
    for (int index = 0; index < patcher->island_count; index++) {
        if (!patcher->islands[index].claimed ||
            patcher->islands[index].used == 0) {
            continue;
        }
        if (v2_space_protect(patcher->space,
                             (void *)(uintptr_t)patcher->islands[index].address,
                             patcher->island_size, prot) != 0) {
            v2_patch_error(error, error_size,
                           prot == V2_PROT_READ
                               ? "cannot reopen a trampoline island"
                               : "cannot seal a trampoline island");
            return -V2_ENOMEM;
        }
    }
    return 0;
}

/*
 * Is there a patch site in this range at all?
 *
 * Scanning without copying matters more than it sounds.  Every executable
 * mapping ld.so makes was read into a heap buffer and written straight back,
 * four megabytes at a time, five times per start-up -- and none of these
 * libraries contains a single `svc`, because musl keeps them all in libc.  So
 * the pass did nothing except dirty every page of every image in the middle of
 * the loader's own work.  A no-op that touches four megabytes is not a no-op;
 * it is a second variable.
 *
 * The chunk is a multiple of four and the range is page aligned, so a word
 * never straddles two reads.
 */
static int v2_has_site(const struct v2_space *space, uint64_t address,
                       size_t length)
{
    uint8_t chunk[16384];
    size_t done = 0;

    while (done < length) {
        size_t want = length - done;

        if (want > sizeof(chunk)) {
            want = sizeof(chunk);
        }
        if (v2_space_read(space, chunk,
                          (const void *)(uintptr_t)(address + done),
                          want) != 0) {
            return -1;
        }
        for (size_t at = 0; at + 4 <= want; at += 4) {
            uint32_t word;

            memcpy(&word, chunk + at, sizeof(word));
            if (word == V2_ARM64_SVC0 ||
                (word & 0xFFFFFFE0u) == V2_ARM64_MRS_TPIDR ||
                (word & 0xFFFFFFE0u) == V2_ARM64_MSR_TPIDR) {
                return 1;
            }
        }
        done += want;
    }
    return 0;
}

int v2_patch_runtime(struct v2_patcher *patcher, uint64_t address,
                     size_t length, char *error, size_t error_size)
{
    const struct v2_host *host = v2_space_host(patcher->space);
    uint8_t *buffer;
    int was_sealed;
    int present;
    int before;
    int status;

    if (length == 0) {
        return 0;
    }
    present = v2_has_site(patcher->space, address, length);
    if (present < 0) {
        v2_patch_error(error, error_size, "cannot read the new image");
        return -V2_EFAULT;
    }
    if (present == 0) {
        return 0;    /* nothing to patch, so nothing is touched */
    }
    was_sealed = patcher->sealed;
    if (was_sealed) {
        status = set_islands(patcher, V2_PROT_READ | V2_PROT_WRITE, error,
                             error_size);
        if (status != 0) {
            return status;
        }
        patcher->sealed = 0;
    }

    buffer = (uint8_t *)malloc(length);
    if (buffer == NULL) {
        v2_patch_error(error, error_size, "out of memory");
        status = -V2_ENOMEM;
        goto reseal;
    }
    before = patcher->site_count;
    if (v2_space_read(patcher->space, buffer,
                      (const void *)(uintptr_t)address, length) != 0) {
        v2_patch_error(error, error_size, "cannot read the new image");
        status = -V2_EFAULT;
        goto done;
    }
    status = v2_patch_buffer(patcher, address, buffer, length, error,
                             error_size);
    if (status == 0 && patcher->site_count != before &&
        v2_space_write(patcher->space, (void *)(uintptr_t)address, buffer,
                       length) != 0) {
        v2_patch_error(error, error_size, "cannot write the patched image");
        status = -V2_EFAULT;
    }
    if (patcher->site_count != before) {
        host->flush_icache(host->ctx, (void *)(uintptr_t)address, length);
    }
done:
    free(buffer);
reseal:
    if (was_sealed) {
        char ignored[8];

        if (v2_patch_seal(patcher, ignored, sizeof(ignored)) != 0) {
            v2_patch_error(error, error_size, "cannot re-seal the islands");
            return -V2_ENOMEM;
        }
    }
    return status;
}

int v2_patch_seal(struct v2_patcher *patcher, char *error, size_t error_size)
{
    const struct v2_host *host = v2_space_host(patcher->space);

    for (int index = 0; index < patcher->island_count; index++) {
        uint64_t address;

        if (!patcher->islands[index].claimed ||
            patcher->islands[index].used == 0) {
            continue;
        }
        address = patcher->islands[index].address;
        if (v2_space_protect(patcher->space, (void *)(uintptr_t)address,
                             patcher->island_size,
                             V2_PROT_READ | V2_PROT_EXEC) != 0) {
            v2_patch_error(error, error_size, "cannot seal a trampoline island");
            return -V2_ENOMEM;
        }
        host->flush_icache(host->ctx, (void *)(uintptr_t)address,
                           patcher->island_size);
    }
    patcher->sealed = 1;
    return 0;
}

const struct v2_patch_site *v2_patch_find(const struct v2_patcher *patcher,
                                          uint64_t site)
{
    for (int index = 0; index < patcher->site_count; index++) {
        if (patcher->sites[index].address == site) {
            return &patcher->sites[index];
        }
    }
    return NULL;
}
