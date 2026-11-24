/*
 * v2/diag.c -- a fingerprint of the guest at a syscall boundary.
 *
 * Two runs with the same image, the same frozen clock and the same pinned arena
 * reach syscall N in the same state or they do not, and until this existed that
 * was an assumption rather than a measurement: the entry hash covered the state
 * before the guest started, the trace covered the calls it made, and nothing
 * covered the space between two calls.
 *
 * The first version printed one hash for all the registers and one for all the
 * writable memory, which was enough to prove that something leaks and useless
 * for saying what.  It now prints, for the first few boundaries, every register
 * and one hash per writable region, so a difference arrives with a name.
 *
 * Read-only image pages are left out on purpose: V2_VERIFY already compares
 * those against their files at the moment of failure.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "v2/diag.h"
#include "v2/proc.h"
#include "v2/systrace.h"
#include "v2/vspace.h"

/* A page is 4 KiB on x86 and 16 KiB on Apple silicon; one buffer covers both. */
#define V2_DIAG_PAGE 16384

static long boundary_limit = -1;
static long detail_limit = -1;

static long from_env(const char *name, long fallback)
{
    const char *value = getenv(name);

    if (value == NULL || value[0] == '\0') {
        return fallback;
    }
    return atol(value);
}

static long limit(void)
{
    if (boundary_limit < 0) {
        boundary_limit = from_env("V2_HASH_EACH", 0);
    }
    return boundary_limit;
}

static long detail(void)
{
    if (detail_limit < 0) {
        detail_limit = from_env("V2_HASH_DEEP", 3);
    }
    return detail_limit;
}

static uint64_t mix(uint64_t hash, uint64_t value)
{
    hash ^= value;
    return hash * 1099511628211ULL;
}

static void emit_registers(unsigned long index, const struct v2_cpu *cpu)
{
    char line[512];

    for (int group = 0; group < 4; group++) {
        int first = group * 8;
        int last = first + 8;

        if (last > 31) {
            last = 31;
        }
        snprintf(line, sizeof(line), "boundary %lu regs%d", index, group);
        for (int reg = first; reg < last; reg++) {
            size_t used = strlen(line);

            snprintf(line + used, sizeof(line) - used, " x%d=0x%llx", reg,
                     (unsigned long long)cpu->x[reg]);
        }
        v2_trace_put(line);
    }
    snprintf(line, sizeof(line),
             "boundary %lu regs4 sp=0x%llx pc=0x%llx nzcv=0x%llx", index,
             (unsigned long long)cpu->sp, (unsigned long long)cpu->pc,
             (unsigned long long)cpu->nzcv);
    v2_trace_put(line);
}

static void emit_regions(unsigned long index, v2_space *space, size_t page_size)
{
    static uint8_t page[V2_DIAG_PAGE];
    uint8_t *base = (uint8_t *)v2_space_base(space);
    size_t total = v2_space_page_count(space);
    size_t which = 0;

    while (which < total) {
        uint64_t hash = 1469598103934665603ULL;
        size_t run_start;
        size_t pages = 0;

        if ((v2_space_state_at(space, base + which * page_size) &
             (V2_PAGE_MAPPED | V2_PROT_WRITE)) !=
            (V2_PAGE_MAPPED | V2_PROT_WRITE)) {
            which++;
            continue;
        }
        run_start = which;
        while (which < total &&
               (v2_space_state_at(space, base + which * page_size) &
                (V2_PAGE_MAPPED | V2_PROT_WRITE)) ==
                   (V2_PAGE_MAPPED | V2_PROT_WRITE)) {
            if (v2_space_read(space, page, base + which * page_size,
                              page_size) == 0) {
                for (size_t at = 0; at + 8 <= page_size; at += 8) {
                    uint64_t word;

                    memcpy(&word, page + at, 8);
                    hash = mix(hash, word);
                }
            }
            pages++;
            which++;
        }
        {
            char line[192];

            snprintf(line, sizeof(line),
                     "boundary %lu region 0x%llx 0x%llx hash=0x%016llx pages=%zu",
                     index,
                     (unsigned long long)(uintptr_t)(base +
                                                     run_start * page_size),
                     (unsigned long long)(uintptr_t)(base + which * page_size),
                     (unsigned long long)hash, pages);
            v2_trace_put(line);
        }
    }
}

void v2_diag_boundary(const struct v2_cpu *cpu, unsigned long index)
{
    struct v2_proc *proc = v2_current_process;
    v2_space *space;
    size_t page_size;

    if (limit() <= 0 || (long)index >= limit() || proc == NULL) {
        return;
    }
    space = proc->space;
    if (space == NULL) {
        return;
    }
    page_size = v2_space_page_size(space);
    if (page_size == 0 || page_size > V2_DIAG_PAGE) {
        return;
    }

    if ((long)index < detail()) {
        emit_registers(index, cpu);
        emit_regions(index, space, page_size);
        return;
    }

    {
        uint64_t hash = 1469598103934665603ULL;
        char line[128];

        for (int reg = 0; reg < 31; reg++) {
            hash = mix(hash, cpu->x[reg]);
        }
        hash = mix(hash, cpu->sp);
        hash = mix(hash, cpu->pc);
        hash = mix(hash, cpu->nzcv);
        snprintf(line, sizeof(line), "boundary %lu summary regs=0x%016llx",
                 index, (unsigned long long)hash);
        v2_trace_put(line);
    }
}
