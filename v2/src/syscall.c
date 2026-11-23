/*
 * v2/syscall.c -- the guest's view of the host, table driven.
 *
 * One entry point, one exit: a handler returns 0 or -errno, the dispatcher
 * writes x0 and advances pc.  No handler is allowed to return a raw Darwin
 * errno -- the numbers differ from Linux above 34, and a wrong errno made
 * musl's resolver give up in v1.
 */
#include "v2/cpu.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "v2/patch.h"
#include "v2/proc.h"
#include "v2/vspace.h"

struct v2_proc *v2_current_process;
struct v2_patcher *v2_current_patcher;
_Thread_local uint64_t v2_tls_shadow;

typedef long long (*v2_syscall_fn)(struct v2_cpu *cpu, struct v2_proc *proc);

static long long log_unsupported(uint64_t number)
{
    static uint8_t seen[320];

    if (number < sizeof(seen) && !seen[number]) {
        seen[number] = 1;
        fprintf(stderr, "[v2] unsupported syscall %llu\n",
                (unsigned long long)number);
    }
    return -V2_ENOSYS;
}

/* --------------------------------------------------------------- helpers */

static int copy_string(struct v2_proc *proc, char *out, size_t size,
                       uint64_t address)
{
    for (size_t index = 0; index < size; index++) {
        if (v2_space_read(proc->space, out + index,
                          (const void *)(uintptr_t)(address + index), 1) != 0) {
            return -V2_EFAULT;
        }
        if (out[index] == '\0') {
            return 0;
        }
    }
    return -V2_ENAMETOOLONG;
}

static int host_flags_from_linux(uint64_t flags)
{
    int host = 0;

    switch (flags & 3u) {
    case 0: host |= O_RDONLY; break;
    case 1: host |= O_WRONLY; break;
    default: host |= O_RDWR; break;
    }
    if ((flags & 0x40u) != 0) { host |= O_CREAT; }
    if ((flags & 0x80u) != 0) { host |= O_EXCL; }
    if ((flags & 0x200u) != 0) { host |= O_TRUNC; }
    if ((flags & 0x400u) != 0) { host |= O_APPEND; }
    if ((flags & 0x800u) != 0) { host |= O_NONBLOCK; }
    if ((flags & 0x4000u) != 0) { host |= O_DIRECTORY; }
    if ((flags & 0x8000u) != 0) { host |= O_NOFOLLOW; }
#ifdef O_CLOEXEC
    if ((flags & 0x80000u) != 0) { host |= O_CLOEXEC; }
#endif
    return host;
}

/* -------------------------------------------------------------- handlers */

static long long sys_write(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int fd = (int)cpu->x[0];
    uint64_t buffer = cpu->x[1];
    uint64_t count = cpu->x[2];
    int host = v2_proc_fd_get(proc, fd);
    uint8_t chunk[4096];
    uint64_t done = 0;

    if (host < 0) {
        return -V2_EBADF;
    }
    while (done < count) {
        size_t want = (size_t)(count - done);
        ssize_t written;

        if (want > sizeof(chunk)) {
            want = sizeof(chunk);
        }
        if (v2_space_read(proc->space, chunk,
                          (const void *)(uintptr_t)(buffer + done),
                          want) != 0) {
            return done > 0 ? (long long)done : -V2_EFAULT;
        }
        written = write(host, chunk, want);
        if (written < 0) {
            return done > 0 ? (long long)done : -V2_EIO;
        }
        done += (uint64_t)written;
        if ((size_t)written < want) {
            break;
        }
    }
    return (long long)done;
}

static long long sys_read(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int fd = (int)cpu->x[0];
    uint64_t buffer = cpu->x[1];
    uint64_t count = cpu->x[2];
    int host = v2_proc_fd_get(proc, fd);
    uint8_t chunk[4096];
    uint64_t done = 0;

    if (host < 0) {
        return -V2_EBADF;
    }
    while (done < count) {
        size_t want = (size_t)(count - done);
        ssize_t got;

        if (want > sizeof(chunk)) {
            want = sizeof(chunk);
        }
        got = read(host, chunk, want);
        if (got < 0) {
            return done > 0 ? (long long)done : -V2_EIO;
        }
        if (got == 0) {
            break;
        }
        if (v2_space_write(proc->space,
                           (void *)(uintptr_t)(buffer + done), chunk,
                           (size_t)got) != 0) {
            return done > 0 ? (long long)done : -V2_EFAULT;
        }
        done += (uint64_t)got;
        if ((size_t)got < want) {
            break;
        }
    }
    return (long long)done;
}

static long long sys_openat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int dirfd = (int)cpu->x[0];
    uint64_t path_address = cpu->x[1];
    uint64_t flags = cpu->x[2];
    char guest[V2_PATH_MAX];
    char host_path[V2_PATH_MAX * 2];
    int host_fd;
    int guest_fd;
    int status;

    status = copy_string(proc, guest, sizeof(guest), path_address);
    if (status != 0) {
        return status;
    }
    status = v2_proc_translate(proc, dirfd, guest, host_path, sizeof(host_path));
    if (status != 0) {
        return status;
    }
    host_fd = open(host_path, host_flags_from_linux(flags), 0644);
    if (host_fd < 0) {
        return errno == ENOENT ? -V2_ENOENT : -V2_EACCES;
    }
    guest_fd = v2_proc_fd_alloc(proc, host_fd, guest);
    if (guest_fd < 0) {
        close(host_fd);
        return -V2_EMFILE;
    }
    return guest_fd;
}

static long long sys_close(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int fd = (int)cpu->x[0];
    int host = v2_proc_fd_get(proc, fd);

    if (host < 0) {
        return -V2_EBADF;
    }
    if (fd > 2) {
        close(host);
        proc->fds[fd] = -1;
        proc->fd_path[fd][0] = '\0';
    }
    return 0;
}

static long long sys_brk(struct v2_cpu *cpu, struct v2_proc *proc)
{
    uint64_t requested = cpu->x[0];

    if (requested == 0 || requested < proc->brk_base ||
        requested > proc->brk_limit) {
        return (long long)proc->brk_current;
    }
    proc->brk_current = requested;
    return (long long)requested;
}

static long long sys_mmap(struct v2_cpu *cpu, struct v2_proc *proc)
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
    return result;
}

static long long sys_munmap(struct v2_cpu *cpu, struct v2_proc *proc)
{
    long long status = v2_space_unmap(proc->space,
                                      (void *)(uintptr_t)cpu->x[0],
                                      (size_t)cpu->x[1]);
    return status < 0 ? (int)status : 0;
}

static long long sys_mprotect(struct v2_cpu *cpu, struct v2_proc *proc)
{
    long long status = v2_space_protect(proc->space,
                                        (void *)(uintptr_t)cpu->x[0],
                                        (size_t)cpu->x[1], (int)cpu->x[2]);
    return status < 0 ? (int)status : 0;
}

static long long sys_madvise(struct v2_cpu *cpu, struct v2_proc *proc)
{
    long long status = v2_space_advise(proc->space,
                                       (void *)(uintptr_t)cpu->x[0],
                                       (size_t)cpu->x[1], (int)cpu->x[2]);
    return status < 0 ? (int)status : 0;
}

static long long sys_uname(struct v2_cpu *cpu, struct v2_proc *proc)
{
    char buffer[6 * 65];
    const char *fields[6] = {"Linux", "v2", "6.6.0-v2", "#1 SMP", "aarch64",
                             "(none)"};

    memset(buffer, 0, sizeof(buffer));
    for (int index = 0; index < 6; index++) {
        snprintf(buffer + index * 65, 65, "%s", fields[index]);
    }
    if (v2_space_write(proc->space, (void *)(uintptr_t)cpu->x[0], buffer,
                       sizeof(buffer)) != 0) {
        return -V2_EFAULT;
    }
    return 0;
}

static long long sys_ioctl(struct v2_cpu *cpu, struct v2_proc *proc)
{
    (void)cpu;
    (void)proc;
    return -V2_ENOTTY;
}

static long long sys_clock_gettime(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int id = (int)cpu->x[0];
    struct timespec value;

    if (id == 0) {
        clock_gettime(CLOCK_REALTIME, &value);
    } else {
        clock_gettime(CLOCK_MONOTONIC, &value);
    }
    {
        int64_t pair[2] = {(int64_t)value.tv_sec, (int64_t)value.tv_nsec};

        if (v2_space_write(proc->space, (void *)(uintptr_t)cpu->x[1], pair,
                           sizeof(pair)) != 0) {
            return -V2_EFAULT;
        }
    }
    return 0;
}

static long long sys_getrandom(struct v2_cpu *cpu, struct v2_proc *proc)
{
    uint64_t buffer = cpu->x[0];
    size_t length = (size_t)cpu->x[1];
    uint8_t chunk[64];
    uint64_t done = 0;
    uint64_t state = 0x9E3779B97F4A7C15ULL;

    while (done < length) {
        size_t want = length - done;

        if (want > sizeof(chunk)) {
            want = sizeof(chunk);
        }
        for (size_t index = 0; index < want; index++) {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            chunk[index] = (uint8_t)(state >> 24);
        }
        if (v2_space_write(proc->space,
                           (void *)(uintptr_t)(buffer + done), chunk,
                           want) != 0) {
            return -V2_EFAULT;
        }
        done += want;
    }
    return (long long)done;
}

static long long sys_getpid(struct v2_cpu *cpu, struct v2_proc *proc)
{
    (void)cpu;
    (void)proc;
    return 1;
}

static long long sys_getuid(struct v2_cpu *cpu, struct v2_proc *proc)
{
    (void)cpu;
    (void)proc;
    return 0;      /* the guest is root: apk refuses to install otherwise */
}

static long long sys_ok(struct v2_cpu *cpu, struct v2_proc *proc)
{
    (void)cpu;
    (void)proc;
    return 0;
}

static long long sys_exit(struct v2_cpu *cpu, struct v2_proc *proc)
{
    (void)proc;
    fflush(stdout);
    _exit((int)(cpu->x[0] & 0xFF));
}

/* ---------------------------------------------------------------- table */

struct v2_sysent {
    const char *name;
    v2_syscall_fn fn;
};

static const struct v2_sysent table[320] = {
    [29] = {"ioctl", sys_ioctl},
    [56] = {"openat", sys_openat},
    [57] = {"close", sys_close},
    [63] = {"read", sys_read},
    [64] = {"write", sys_write},
    [93] = {"exit", sys_exit},
    [94] = {"exit_group", sys_exit},
    [96] = {"set_tid_address", sys_getpid},
    [99] = {"set_robust_list", sys_ok},
    [113] = {"clock_gettime", sys_clock_gettime},
    [160] = {"uname", sys_uname},
    [172] = {"getpid", sys_getpid},
    [174] = {"getuid", sys_getuid},
    [175] = {"geteuid", sys_getuid},
    [176] = {"getgid", sys_getuid},
    [177] = {"getegid", sys_getuid},
    [178] = {"gettid", sys_getpid},
    [214] = {"brk", sys_brk},
    [215] = {"munmap", sys_munmap},
    [222] = {"mmap", sys_mmap},
    [226] = {"mprotect", sys_mprotect},
    [233] = {"madvise", sys_madvise},
    [278] = {"getrandom", sys_getrandom},
};

void v2_syscall_dispatch(struct v2_cpu *cpu)
{
    uint64_t site = cpu->pc;
    struct v2_proc *proc = v2_current_process;
    const struct v2_patch_site *patch = NULL;
    uint64_t number;
    long long result;

    cpu->pc = site + 4;
    if (v2_current_patcher != NULL) {
        patch = v2_patch_find(v2_current_patcher, site);
    }
    if (patch != NULL && patch->kind == V2_PATCH_MRS) {
        cpu->x[patch->reg] = v2_tls_shadow;
        return;
    }
    if (patch != NULL && patch->kind == V2_PATCH_MSR) {
        v2_tls_shadow = cpu->x[patch->reg];
        return;
    }

    number = cpu->x[8];
    if (number < 320 && table[number].fn != NULL) {
        result = table[number].fn(cpu, proc);
    } else {
        result = log_unsupported(number);
    }
    cpu->x[0] = (uint64_t)result;
}
