/*
 * v2/vmops.c -- memory syscalls.
 *
 * Every one of these is a thin translation onto v2_space_*, which owns the
 * only truth about the guest's address space.  The one piece of real work
 * here is the runtime patching in mmap: a library mapped by ld.so arrives
 * with raw `svc #0` in it.
 */
#include "v2/cpu.h"

#include <stdio.h>
#include <string.h>

#include "v2/patch.h"
#include "v2/proc.h"
#include "v2/vmops.h"
#include "v2/vspace.h"

long long v2_vm_brk(struct v2_cpu *cpu, struct v2_proc *proc)
{
    uint64_t requested = cpu->x[0];

    if (requested == 0 || requested < proc->brk_base ||
        requested > proc->brk_limit) {
        return (long long)proc->brk_current;
    }
    proc->brk_current = requested;
    return (long long)requested;
}

long long v2_vm_mmap(struct v2_cpu *cpu, struct v2_proc *proc)
{
    uint64_t address = cpu->x[0];
    uint64_t length = cpu->x[1];
    uint64_t prot = cpu->x[2];
    uint64_t flags = cpu->x[3];
    int fd = (int)(int64_t)cpu->x[4];
    uint64_t offset = cpu->x[5];
    long long result;

    if ((flags & V2_MAP_ANON) == 0 && fd >= 0) {
        fd = v2_proc_fd_get(proc, fd);
        if (fd < 0) {
            return -V2_EBADF;
        }
    } else {
        fd = -1;
    }
    result = v2_space_map(proc->space, (void *)(uintptr_t)address,
                          (size_t)length, (int)prot, (int)flags, fd,
                          (long long)offset);
    /*
     * A library mapped by ld.so arrives with its syscalls still raw.  ld.so
     * maps the whole library once with the first segment's protection, which
     * for a shared object is the executable one, so "file-backed and
     * executable" is exactly the set of pages that may contain `svc #0`.
     * They are writable for the few microseconds it takes to rewrite them.
     */
    if (result > 0 && fd >= 0 && (prot & V2_PROT_EXEC) != 0 &&
        proc->patcher != NULL) {
        char patch_error[96] = "";
        int before = proc->patcher->site_count;

        if (v2_space_protect(proc->space, (void *)(uintptr_t)result,
                             (size_t)length,
                             V2_PROT_READ | V2_PROT_WRITE) != 0 ||
            v2_patch_runtime(proc->patcher, (uint64_t)result, (size_t)length,
                             patch_error, sizeof(patch_error)) != 0) {
            fprintf(stderr, "[v2] runtime patch failed: %s\n", patch_error);
        }
        v2_space_protect(proc->space, (void *)(uintptr_t)result,
                         (size_t)length, (int)prot);
        fprintf(stderr,
                "[v2] exec map %s at 0x%llx len=0x%llx prot=%llu sites=+%d\n",
                proc->fd_path[(int)cpu->x[4]], (unsigned long long)result,
                (unsigned long long)length, (unsigned long long)prot,
                proc->patcher->site_count - before);
    }
    return result;
}

long long v2_vm_munmap(struct v2_cpu *cpu, struct v2_proc *proc)
{
    long long status = v2_space_unmap(proc->space,
                                      (void *)(uintptr_t)cpu->x[0],
                                      (size_t)cpu->x[1]);
    return status < 0 ? (int)status : 0;
}

/*
 * mremap.  v2_space_remap already has exactly this contract (grow in place,
 * or move and copy), because the address-space model needed it; this is the
 * syscall wrapper.  musl's realloc uses it for mmap'd chunks, and while
 * ENOSYS makes it fall back to malloc+copy, having the real thing removes a
 * difference between us and a kernel.
 */
long long v2_vm_mremap(struct v2_cpu *cpu, struct v2_proc *proc)
{
    return v2_space_remap(proc->space, (void *)(uintptr_t)cpu->x[0],
                          (size_t)cpu->x[1], (size_t)cpu->x[2], (int)cpu->x[3]);
}

long long v2_vm_mprotect(struct v2_cpu *cpu, struct v2_proc *proc)
{
    long long status = v2_space_protect(proc->space,
                                        (void *)(uintptr_t)cpu->x[0],
                                        (size_t)cpu->x[1], (int)cpu->x[2]);
    return status < 0 ? (int)status : 0;
}

long long v2_vm_madvise(struct v2_cpu *cpu, struct v2_proc *proc)
{
    long long status = v2_space_advise(proc->space,
                                       (void *)(uintptr_t)cpu->x[0],
                                       (size_t)cpu->x[1], (int)cpu->x[2]);
    return status < 0 ? (int)status : 0;
}

