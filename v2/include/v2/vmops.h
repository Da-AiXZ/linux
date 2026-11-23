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

long long v2_vm_brk(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_vm_mmap(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_vm_munmap(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_vm_mremap(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_vm_mprotect(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_vm_madvise(struct v2_cpu *cpu, struct v2_proc *proc);

#endif /* V2_VMOPS_H */
