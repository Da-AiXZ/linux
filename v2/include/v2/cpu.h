/*
 * v2/cpu.h -- the guest register file, exactly as the entry stub lays it out.
 *
 * The stub pushes 34 slots and calls the dispatcher with sp as the argument,
 * so this struct *is* the stack frame.  Adding a field here without touching
 * the stub (or the other way round) is the fastest way to corrupt a guest, so
 * the size is asserted at compile time.
 */
#ifndef V2_CPU_H
#define V2_CPU_H

#include <stdint.h>

#include "v2/systrace.h"

struct v2_cpu {
    uint64_t x[31];    /* x0 .. x30, offset 0 .. 240 */
    uint64_t sp;       /* 248: the guest's stack pointer at the site */
    uint64_t pc;       /* 256: the site address when the stub runs */
    uint64_t nzcv;     /* 264 */
};

_Static_assert(sizeof(struct v2_cpu) == 272, "the entry stub pushes 272 bytes");

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
