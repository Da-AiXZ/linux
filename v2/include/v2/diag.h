/*
 * v2/diag.h -- fingerprints taken at a syscall boundary.
 *
 * The question this answers is narrow: two runs given the same image, the same
 * frozen clock and the same pinned arena reach syscall N in the same state, or
 * they do not.  The first boundary whose fingerprint differs is where something
 * entered the guest that we did not account for -- and until this existed, the
 * space between two syscalls was an assumption rather than a measurement.
 */
#ifndef V2_DIAG_H
#define V2_DIAG_H

#include <stdint.h>

#include "v2/cpu.h"

/*
 * Writes the fingerprint of this boundary into the syscall log: one hash line
 * per call, and for the first few calls the raw registers and one hash per
 * writable region -- because "the registers differ" is not an answer and
 * "x16 differs" is.
 *
 * Silent unless V2_HASH_EACH is set to the number of boundaries to record.
 */
void v2_diag_boundary(const struct v2_cpu *cpu, unsigned long index);

#endif
