/*
 * v2/cpu.h -- the guest register file, exactly as the entry stub lays it out.
 *
 * The stub fills this struct and calls the dispatcher with a pointer to it.
 * It lives in the *host's* .bss (see v2_syscall_entry), never on the guest's
 * stack: the guest's stack is the guest's, and a host frame written below its
 * sp is memory the guest is free to read.
 *
 * Adding a field here without touching the stub (or the other way round) is
 * the fastest way to corrupt a guest, so the size is asserted at compile time.
 *
 * The vector registers and the floating point control words are part of the
 * state a Linux syscall preserves, so they are part of the frame.  They were
 * the last guest-visible state with no owner: the guest began with whatever
 * the host's SIMD code had left behind, spilled it to its own stack, and every
 * comparison then found a random doubleword that was neither a bug nor ours.
 */
#ifndef V2_CPU_H
#define V2_CPU_H

#include <stddef.h>
#include <stdint.h>

#include "v2/systrace.h"

struct v2_cpu {
    uint64_t x[31];      /* x0 .. x30, offset 0 .. 240 */
    uint64_t sp;         /* 248: the guest's stack pointer at the site */
    uint64_t pc;         /* 256: the site address when the stub runs */
    uint64_t nzcv;       /* 264 */
    uint64_t q[32][2];   /* 272: qN at 272 + 16*N, two 64-bit halves */
    uint64_t fpcr;       /* 784 */
    uint64_t fpsr;       /* 792 */
};

_Static_assert(sizeof(struct v2_cpu) == 800, "the entry frame is 800 bytes");

/* The stub hard-codes these; a field that moves is an overnight device trip. */
_Static_assert(offsetof(struct v2_cpu, sp) == 248, "sp is [x9, #248]");
_Static_assert(offsetof(struct v2_cpu, pc) == 256, "pc is [x9, #256]");
_Static_assert(offsetof(struct v2_cpu, nzcv) == 264, "nzcv is [x9, #264]");
_Static_assert(offsetof(struct v2_cpu, q) == 272, "q0 is [x9, #272]");
_Static_assert(offsetof(struct v2_cpu, fpcr) == 784, "fpcr is [x9, #784]");
_Static_assert(offsetof(struct v2_cpu, fpsr) == 792, "fpsr is [x9, #792]");

struct v2_proc;
struct v2_patcher;

/* Installed once by the runner; the dispatcher is called from the stub. */
extern struct v2_proc *v2_current_process;
extern struct v2_patcher *v2_current_patcher;

/* Shadow of TPIDR_EL0.  Per-thread once threads exist; a single global today
 * because a guest thread cannot run yet anyway. */
extern _Thread_local uint64_t v2_tls_shadow;

void v2_syscall_dispatch(struct v2_cpu *cpu);

/* Never returns: loads the whole register file and jumps to pc. */
void v2_guest_enter(const struct v2_cpu *cpu);

/* The entry every patched site branches to (see entry_aarch64.c). */
void v2_syscall_entry(void);

#endif /* V2_CPU_H */
