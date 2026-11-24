/*
 * v2/diag.h -- fingerprints taken at a syscall boundary.
 *
 * The question this answers is narrow: two runs that were given the same image,
 * the same frozen clock and the same pinned address space reach syscall N with
 * identical state, so the first boundary where their fingerprints differ is the
 * boundary where something entered the guest that we did not account for.
 */
#ifndef V2_DIAG_H
#define V2_DIAG_H

#include <stddef.h>
#include <stdint.h>

#include "v2/cpu.h"

/*
 * Prints one line per syscall for the first V2_HASH_EACH syscalls: a hash of the
 * guest's registers and a hash of every writable page.  Where the line goes is
 * the syscall log's business; this only computes it.
 *
 * `into` receives the two numbers when the environment asks for them.
 */
int v2_diag_boundary(const struct v2_cpu *cpu, unsigned long index,
                     uint64_t *registers, uint64_t *memory, size_t *pages);

#endif
