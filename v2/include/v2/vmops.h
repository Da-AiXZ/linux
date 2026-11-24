/*
 * v2/vmops.h -- the syscalls that move memory around.
 *
 * Split from syscall.c for the same reason fsops.c is: brk, mmap, munmap,
 * mprotect, madvise and mremap all speak to the address space and to nothing
 * else, and syscall.c has a line budget that keeps it readable.
 */
#ifndef V2_VMOPS_H
#define V2_VMOPS_H

#include "v2/fsops.h"

/*
 * Set by the runner from V2_VERIFY=1.  When set, every file mapping is
 * compared against the file after it is made, and the first differing byte is
 * reported.  A library whose contents are wrong fails twenty steps later in
 * ld.so's symbol lookup with a message about whichever symbol the damage hit,
 * which is impossible to work backwards from; this says it at the source.
 */
extern int v2_verify_mappings;

/*
 * Recomputed at every guest exit when verification is on: if a library's
 * bytes changed since it was mapped, something wrote into it, and the name of
 * the symbol that ld.so could not find is a symptom rather than the cause.
 */
void v2_verify_dump(void);

long long v2_vm_brk(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_vm_mmap(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_vm_munmap(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_vm_mremap(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_vm_mprotect(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_vm_madvise(struct v2_cpu *cpu, struct v2_proc *proc);

#endif /* V2_VMOPS_H */
