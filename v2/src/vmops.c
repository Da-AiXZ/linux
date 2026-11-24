/*
 * v2/vmops.c -- memory syscalls.
 *
 * Every one of these is a thin translation onto v2_space_*, which owns the
 * only truth about the guest's address space.  The one piece of real work
 * here is the runtime patching in mmap: a library mapped by ld.so arrives
 * with raw `svc #0` in it.
 */
#include "v2/cpu.h"

#include <fcntl.h>
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
    uint64_t address;      /* where it was mapped in the guest            */
    uint64_t offset;       /* where it starts in the file                 */
    size_t length;         /* how much of the mapping came from the file  */
    uint64_t hash;
    int host_path;         /* 1 when `path` is already a host path       */
    char path[128];        /* the guest path, for reopening at dump time  */
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

/*
 * At exit, compare each executable image against the file it came from.
 *
 * This is the only comparison that means anything: the mapping is built in
 * pieces (a whole-library reservation, then a MAP_FIXED per segment), so a
 * hash taken mid-build always differs.  The file is the ground truth, and if
 * a failing run shows an image that no longer matches it, the corruption is
 * ours and the offset says where.
 */
void v2_verify_dump(void)
{
    char host_path[V2_PATH_MAX * 2];

    if (!v2_verify_mappings || v2_current_process == NULL) {
        return;
    }
    for (int index = 0; index < verify_count; index++) {
        uint8_t *file = verify_file;
        size_t want = verify_snapshot[index].length;
        size_t done = 0;
        size_t differences = 0;
        uint64_t first_difference = 0;
        int fd;

        if (verify_snapshot[index].host_path) {
            snprintf(host_path, sizeof(host_path), "%s",
                     verify_snapshot[index].path);
        } else if (v2_proc_translate(v2_current_process, -100,
                                     verify_snapshot[index].path, host_path,
                                     sizeof(host_path)) != 0) {
            continue;
        }
        fd = open(host_path, O_RDONLY);
        if (fd < 0) {
            continue;
        }
        while (done < want) {
            ssize_t got = pread(fd, file + done, want - done,
                                (off_t)(verify_snapshot[index].offset + done));

            if (got <= 0) {
                break;
            }
            done += (size_t)got;
        }
        close(fd);
        if (done != want ||
            v2_space_read(v2_current_process->space, verify_guest,
                          (const void *)(uintptr_t)verify_snapshot[index].address,
                          want) != 0) {
            continue;
        }
        /*
         * Only executable pages.  musl's first mapping of a library covers the
         * whole span with the lowest segment's protection, which for a shared
         * object is the executable one -- so the range we snapshot always
         * contains the data segments too, and relocation legitimately rewrites
         * those.  The page table knows which pages are actually code.
         */
        {
            size_t page = v2_space_page_size(v2_current_process->space);

            for (size_t base = 0; base < want; base += page) {
                int state = v2_space_state_at(
                    v2_current_process->space,
                    (const void *)(uintptr_t)(verify_snapshot[index].address +
                                              base));
                size_t limit = base + page < want ? base + page : want;

                if ((state & V2_PROT_EXEC) == 0) {
                    continue;
                }
                for (size_t at = base; at < limit; at++) {
                    if (file[at] != verify_guest[at]) {
                        if (differences == 0) {
                            first_difference = at;
                        }
                        differences++;
                    }
                }
            }
        }
        fprintf(stderr, "[v2] image %s at 0x%llx: %s",
                verify_snapshot[index].path,
                (unsigned long long)verify_snapshot[index].address,
                differences == 0 ? "matches the file\n" : "differs at 0x");
        if (differences != 0) {
            fprintf(stderr, "%llx (%zu of %zu bytes)\n",
                    (unsigned long long)first_difference, differences, want);
        }
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

void v2_verify_note_host(const char *host_path, uint64_t address,
                         size_t length, uint64_t file_offset)
{
    if (!v2_verify_mappings || verify_count >= V2_VERIFY_SLOTS) {
        return;
    }
    verify_snapshot[verify_count].address = address;
    verify_snapshot[verify_count].offset = file_offset;
    verify_snapshot[verify_count].length = length;
    verify_snapshot[verify_count].hash = 0;
    verify_snapshot[verify_count].host_path = 1;
    snprintf(verify_snapshot[verify_count].path,
             sizeof(verify_snapshot[verify_count].path), "%s", host_path);
    verify_count++;
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
            struct stat info;

            verify_snapshot[verify_count].address = (uint64_t)result;
            verify_snapshot[verify_count].offset = offset;
            verify_snapshot[verify_count].length = (size_t)length;
            verify_snapshot[verify_count].hash =
                hash_range(proc, (uint64_t)result, (size_t)length);
            if (fstat(fd, &info) == 0 && info.st_size > 0 &&
                offset < (uint64_t)info.st_size) {
                size_t available = (size_t)((uint64_t)info.st_size - offset);

                if (available < (size_t)length) {
                    verify_snapshot[verify_count].length = available;
                }
            }
            verify_snapshot[verify_count].host_path = 0;
            snprintf(verify_snapshot[verify_count].path,
                     sizeof(verify_snapshot[verify_count].path), "%s",
                     proc->fd_path[(int)cpu->x[4]]);
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

