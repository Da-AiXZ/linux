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

            /*
             * x16 is the host's syscall entry and is the one register that is
             * supposed to carry a host address into the guest -- it is what the
             * stub branches back to.  Printing it would put a different number
             * on every line of the log and hide the differences that matter.
             */
            if (reg == 16) {
                snprintf(line + used, sizeof(line) - used, " x16=(host)");
            } else {
                snprintf(line + used, sizeof(line) - used, " x%d=0x%llx", reg,
                         (unsigned long long)cpu->x[reg]);
            }
        }
        v2_trace_put(line);
    }
    snprintf(line, sizeof(line),
             "boundary %lu regs4 sp=0x%llx pc=0x%llx nzcv=0x%llx", index,
             (unsigned long long)cpu->sp, (unsigned long long)cpu->pc,
             (unsigned long long)cpu->nzcv);
    v2_trace_put(line);
}

static uint64_t entry_x18;
static uint64_t entry_pc;

void v2_diag_entry(const struct v2_cpu *cpu)
{
    entry_x18 = cpu->x[18];
    entry_pc = cpu->pc;
}

static int wants_words(unsigned long index)
{
    static long wanted[32];
    static int count;
    static int loaded;

    if (!loaded) {
        const char *list = getenv("V2_DIAG_WORDS");
        char *end = (char *)list;

        loaded = 1;
        while (list != NULL && *end != '\0' && count < 31) {
            long value = strtol(end, &end, 0);

            if (value < 0) {
                break;
            }
            wanted[count++] = value;
            if (*end != ',') {
                break;
            }
            end++;
        }
    }
    for (int slot = 0; slot < count; slot++) {
        if ((unsigned long)wanted[slot] == index) {
            return 1;
        }
    }
    return 0;
}

#define V2_DIAG_PAGE_LIST 8192

static size_t page_list[V2_DIAG_PAGE_LIST];

/*
 * One hash per writable page, plus the words of the last few pages.
 *
 * The word dump alone was a trap: it stopped at eight thousand words, which is
 * the *lowest* eight thousand non-zero words, and the stack -- where every
 * interesting value in this bug lives -- is the highest memory in the arena.  It
 * had never been compared.  A hash per page cannot be truncated into silence and
 * costs a line per page; the words of the top eight pages come with it because
 * that is where the suspect is, and a page number would otherwise be one more
 * round trip.
 */
static void emit_page_words(unsigned long index, const uint8_t *at,
                            const uint8_t *page, size_t page_size,
                            uint64_t from)
{
    char line[96];

    for (size_t offset = 0; offset + 8 <= page_size; offset += 8) {
        uint64_t word;
        uint64_t where = (uint64_t)(uintptr_t)(at + offset);

        if (where < from) {
            continue;
        }
        memcpy(&word, page + offset, 8);
        if (word == 0) {
            continue;
        }
        snprintf(line, sizeof(line), "boundary %lu word 0x%llx 0x%llx", index,
                 (unsigned long long)where, (unsigned long long)word);
        v2_trace_put(line);
    }
}

static void emit_pages(unsigned long index, const struct v2_cpu *cpu,
                       v2_space *space, size_t page_size, int with_words)
{
    static uint8_t page[V2_DIAG_PAGE];
    uint8_t *base = (uint8_t *)v2_space_base(space);
    size_t total = v2_space_page_count(space);
    size_t count = 0;
    size_t stride;
    size_t island;
    size_t emitted_islands = 0;
    uint64_t probe;

    stride = v2_space_island_stride(space);
    island = v2_space_island_size(space);

    /*
     * Every mapped page, not only the writable ones.
     *
     * The comparison has said "the state is identical" for a while, and every
     * time it said that it had only looked at pages a guest may write.  Code
     * pages were never compared, and neither were the trampoline islands -- the
     * one place in guest memory where a host address lives.  If a single byte
     * anywhere differs, it has to be one of those.
     */
    for (size_t which = 0; which < total; which++) {
        if ((v2_space_state_at(space, base + which * page_size) &
             V2_PAGE_MAPPED) == 0) {
            continue;
        }
        if (count < V2_DIAG_PAGE_LIST) {
            page_list[count] = which;
        }
        count++;
    }
    /*
     * The pages whose words are worth printing are the ones the stack is on:
     * an earlier version printed the eight highest pages and got libcrypto,
     * because first-fit had put a library right above the stack.
     */
    probe = cpu->sp & ~(uint64_t)(page_size - 1);

    for (size_t slot = 0; slot < count && slot < V2_DIAG_PAGE_LIST; slot++) {
        uint8_t *at = base + page_list[slot] * page_size;
        uint64_t hash = 1469598103934665603ULL;
        char line[96];

        /*
         * A page that is mapped but not readable is compared by its state byte
         * only: reading it would fault on the host, and its protection is itself
         * something that can differ between runs.
         */
        if ((v2_space_state_at(space, at) & V2_PROT_READ) == 0) {
            snprintf(line, sizeof(line), "boundary %lu page 0x%llx state=0x%02x",
                     index, (unsigned long long)(uintptr_t)at,
                     (unsigned)v2_space_state_at(space, at));
            v2_trace_put(line);
            continue;
        }
        if (v2_space_read(space, page, at, page_size) != 0) {
            continue;
        }
        for (size_t offset = 0; offset + 8 <= page_size; offset += 8) {
            uint64_t word;

            memcpy(&word, page + offset, 8);
            hash ^= word;
            hash *= 1099511628211ULL;
        }
        /*
         * No hash line for the stack's own pages: the words come out anyway, and
         * a hash that differs one line before them makes the diff stop there and
         * report "this page", which is what we already knew.
         */
        if (!with_words ||
            ((uint64_t)(uintptr_t)at != probe &&
             (uint64_t)(uintptr_t)at + page_size != probe)) {
            snprintf(line, sizeof(line), "boundary %lu page 0x%llx 0x%016llx",
                     index, (unsigned long long)(uintptr_t)at,
                     (unsigned long long)hash);
            v2_trace_put(line);
        }

        {
            size_t offset_into_arena = (size_t)(at - base);
            int is_island = stride != 0 && island != 0 &&
                (offset_into_arena % stride) < island;

            if (with_words && is_island && emitted_islands < 2) {
                emitted_islands++;
                emit_page_words(index, at, page, page_size, 0);
            }
        }
        if (with_words && (uint64_t)(uintptr_t)at == probe) {
            /*
             * Only the live part of the stack page: from our own frame upwards.
             * Below that the guest never reads again, and whatever a previous
             * call left there differs between runs for reasons that cannot
             * matter -- which is enough to make the page differ and hide the
             * word that does.
             */
            uint64_t frame = cpu->sp > 800 ? cpu->sp - 800 : 0;

            for (size_t offset = 0; offset + 8 <= page_size; offset += 8) {
                uint64_t word;
                uint64_t where = (uint64_t)(uintptr_t)(at + offset);

                if (where < frame) {
                    continue;
                }
                memcpy(&word, page + offset, 8);
                if (word == 0) {
                    continue;
                }
                snprintf(line, sizeof(line),
                         "boundary %lu word 0x%llx 0x%llx", index,
                         (unsigned long long)where,
                         (unsigned long long)word);
                v2_trace_put(line);
            }
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

    /*
     * Every boundary, because the one that matters is the one just before the
     * guest goes a different way, and that number is not known in advance -- it
     * was 47 when this was written.  Five lines per call, and the whole point is
     * that the first line that differs names a register.
     */
    {
        char line[128];

        snprintf(line, sizeof(line),
                 "boundary %lu x18 in=0x%llx out=0x%llx pc=0x%llx", index,
                 (unsigned long long)entry_x18,
                 (unsigned long long)cpu->x[18],
                 (unsigned long long)entry_pc);
        v2_trace_put(line);
    }
    emit_registers(index, cpu);
    /*
     * Pages only inside the window: a hash per page is four and a half thousand
     * lines, and doing that at all sixty-four boundaries would make the log
     * something nobody can diff.
     */
    if (wants_words(index)) {
        emit_pages(index, cpu, space, page_size, 1);
    }
}
