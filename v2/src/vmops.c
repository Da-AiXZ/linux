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
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "v2/patch.h"
#include "v2/proc.h"
#include "v2/vmops.h"
#include "v2/vspace.h"

int v2_verify_mappings;

static uint8_t *verify_file;
static uint8_t *verify_guest;
static size_t verify_capacity;

#define V2_VERIFY_SLOTS 16
static struct {
    uint64_t address;
    size_t length;
    uint64_t hash;
} verify_snapshot[V2_VERIFY_SLOTS];
static int verify_count;

static uint64_t hash_range(struct v2_proc *proc, uint64_t address,
                           size_t length)
{
    uint64_t hash = 1469598103934665603ULL;   /* FNV-1a, 64 bit */
    uint8_t chunk[4096];
    size_t done = 0;

    while (done < length) {
        size_t want = length - done;

        if (want > sizeof(chunk)) {
            want = sizeof(chunk);
        }
        if (v2_space_read(proc->space, chunk,
                          (const void *)(uintptr_t)(address + done),
                          want) != 0) {
            return 0;
        }
        for (size_t index = 0; index < want; index++) {
            hash = (hash ^ chunk[index]) * 1099511628211ULL;
        }
        done += want;
    }
    return hash;
}

void v2_verify_dump(void)
{
    if (!v2_verify_mappings || v2_current_process == NULL) {
        return;
    }
    for (int index = 0; index < verify_count; index++) {
        uint64_t now = hash_range(v2_current_process,
                                  verify_snapshot[index].address,
                                  verify_snapshot[index].length);

        fprintf(stderr, "[v2] image 0x%llx len=0x%zx %s\n",
                (unsigned long long)verify_snapshot[index].address,
                verify_snapshot[index].length,
                now == verify_snapshot[index].hash ? "unchanged"
                                                   : "CHANGED");
    }
}

/*
 * Compare a freshly mapped file range against the file itself.  This is the
 * instrument for "some library looks wrong only sometimes": relocation
 * failures inside ld.so name a different symbol each time, which is what a
 * hole in a symbol table looks like, and a hole can only come from the bytes
 * we put in memory.
 */
static void verify_mapping(struct v2_proc *proc, int host_fd, uint64_t offset,
                           uint64_t address, size_t length)
{
    struct stat info;
    uint8_t *file;
    uint8_t *guest;
    size_t want;
    size_t done = 0;

    if (!v2_verify_mappings || fstat(host_fd, &info) != 0 ||
        info.st_size <= 0) {
        return;
    }
    if (offset >= (uint64_t)info.st_size) {
        return;
    }
    want = (size_t)((uint64_t)info.st_size - offset);
    if (want > length) {
        want = length;
    }
    /*
     * One pair of buffers for the life of the process.  Allocating 4 MB twice
     * per mapping was itself an experiment: with it, the relocation flake ran
     * at 7.4%; the point of reusing the buffers is to find out whether the
     * allocator was the perturbation or the comparison was.
     */
    if (want > verify_capacity) {
        free(verify_file);
        free(verify_guest);
        verify_file = (uint8_t *)malloc(want);
        verify_guest = (uint8_t *)malloc(want);
        verify_capacity = (verify_file != NULL && verify_guest != NULL) ? want : 0;
        if (verify_capacity == 0) {
            free(verify_file);
            free(verify_guest);
            verify_file = NULL;
            verify_guest = NULL;
            return;
        }
    }
    file = verify_file;
    guest = verify_guest;
    while (done < want) {
        ssize_t got = pread(host_fd, file + done, want - done,
                            (off_t)(offset + done));

        if (got <= 0) {
            break;
        }
        done += (size_t)got;
    }
    if (done == want &&
        v2_space_read(proc->space, guest, (const void *)(uintptr_t)address,
                      want) == 0) {
        for (size_t index = 0; index < want; index++) {
            if (file[index] != guest[index]) {
                fprintf(stderr,
                        "[v2] MISMATCH at 0x%llx (+0x%zx): file=%02x guest=%02x"
                        " of 0x%zx bytes\n",
                        (unsigned long long)address, index, file[index],
                        guest[index], want);
                break;
            }
        }
    }
}

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
    if (result > 0 && fd >= 0) {
        /* Before patching, so the comparison is against the file as it is. */
        verify_mapping(proc, fd, offset, (uint64_t)result, (size_t)length);
    }
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
        /*
         * Snapshot after patching, so the legitimate `svc` rewrites are part
         * of the baseline.  Only executable mappings: relocation writes into
         * .data/.got by design, but the symbol tables, the strings and the
         * code all live here, and nothing should write here afterwards.
         */
        if (v2_verify_mappings && verify_count < V2_VERIFY_SLOTS) {
            verify_snapshot[verify_count].address = (uint64_t)result;
            verify_snapshot[verify_count].length = (size_t)length;
            verify_snapshot[verify_count].hash =
                hash_range(proc, (uint64_t)result, (size_t)length);
            verify_count++;
        }
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

