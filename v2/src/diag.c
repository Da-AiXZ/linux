/*
 * v2/diag.c -- a fingerprint of the guest at a syscall boundary.
 *
 * Two runs with the same image, the same frozen clock and the same pinned arena
 * reach syscall N in the same state or they do not, and until now that was an
 * assumption rather than a measurement: the entry hash covered the state before
 * the guest started, the trace covered the calls it made, and nothing covered
 * the space between two calls.
 *
 * That gap is exactly where this bug lives.  The trace shows the first
 * divergence at syscall 47 -- the run that fails reports a symbol missing while
 * the run that works goes on to protect the main program's RELRO -- and calls 0
 * through 46 are identical.  Between 46 and 47 the guest executes instructions
 * and reads its own memory, so either the memory already differed or a register
 * came back different from a syscall.  This computes both, per boundary, so the
 * answer is a line number instead of a hypothesis.
 *
 * Only writable pages are hashed: read-only image pages are compared against
 * their files by V2_VERIFY at the moment of failure, so a difference there is
 * already somebody else's alarm.
 */
#include <stdlib.h>
#include <string.h>

#include "v2/diag.h"
#include "v2/proc.h"
#include "v2/vspace.h"

/* A page is 4 KiB on x86 and 16 KiB on Apple silicon; one buffer covers both. */
#define V2_DIAG_PAGE 16384

static long boundary_limit = -1;

static long limit(void)
{
    if (boundary_limit < 0) {
        const char *wanted = getenv("V2_HASH_EACH");

        boundary_limit = wanted != NULL ? atol(wanted) : 0;
    }
    return boundary_limit;
}

static uint64_t mix(uint64_t hash, uint64_t value)
{
    hash ^= value;
    return hash * 1099511628211ULL;
}

int v2_diag_boundary(const struct v2_cpu *cpu, unsigned long index,
                     uint64_t *registers, uint64_t *memory, size_t *pages)
{
    static uint8_t page[V2_DIAG_PAGE];
    struct v2_proc *proc = v2_current_process;
    v2_space *space;
    uint64_t regs = 1469598103934665603ULL;
    uint64_t mem = 1469598103934665603ULL;
    size_t page_size;
    size_t count = 0;

    if (limit() <= 0 || (long)index >= limit() || proc == NULL) {
        return 0;
    }
    space = proc->space;
    if (space == NULL) {
        return 0;
    }
    page_size = v2_space_page_size(space);
    if (page_size == 0 || page_size > sizeof(page)) {
        return 0;
    }

    for (int reg = 0; reg < 31; reg++) {
        regs = mix(regs, cpu->x[reg]);
    }
    regs = mix(regs, cpu->sp);
    regs = mix(regs, cpu->pc);
    regs = mix(regs, cpu->nzcv);

    {
        uint8_t *base = (uint8_t *)v2_space_base(space);
        size_t total = v2_space_page_count(space);

        for (size_t which = 0; which < total; which++) {
            uint8_t *at = base + which * page_size;
            int state = v2_space_state_at(space, at);

            if ((state & V2_PAGE_MAPPED) == 0 ||
                (state & V2_PROT_WRITE) == 0) {
                continue;
            }
            if (v2_space_read(space, page, at, page_size) != 0) {
                continue;
            }
            for (size_t at_byte = 0; at_byte + 8 <= page_size; at_byte += 8) {
                uint64_t word;

                memcpy(&word, page + at_byte, 8);
                mem = mix(mem, word);
            }
            count++;
        }
    }

    *registers = regs;
    *memory = mem;
    *pages = count;
    return 1;
}
