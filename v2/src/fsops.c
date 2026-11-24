/*
 * v2/fsops.c -- path-mutating syscalls.
 *
 * apk does not just read: it creates /var/cache/apk, writes temp files,
 * renames them over their targets, removes old ones and stamps mtimes.  All
 * of that is one shape, so it is one helper (`resolve`) plus a handful of
 * two-line handlers.
 */

/* -std=c11 hides symlink/lstat/fchmod behind feature macros. */
#define _GNU_SOURCE 1

#include "v2/cpu.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "v2/fsops.h"
#include "v2/proc.h"
#include "v2/vspace.h"

#define V2_AT_FDCWD             (-100)
#define V2_AT_SYMLINK_NOFOLLOW  0x100
#define V2_AT_REMOVEDIR         0x200
#define V2_AT_EMPTY_PATH        0x1000
#define V2_UTIME_NOW            0x3FFFFFFF
#define V2_UTIME_OMIT           0x3FFFFFFE

int v2_errno_from_host(int host_errno)
{
    /*
     * Below 35 the two tables are identical; above that they are not, and a
     * silent mismatch is worse than a coarse answer.  Each case is guarded
     * because on Linux the numbers already agree and a duplicate case would
     * not compile.
     */
    switch (host_errno) {
#ifdef ENOTEMPTY
#if ENOTEMPTY != 39
    case ENOTEMPTY: return 39;
#endif
#endif
#ifdef ELOOP
#if ELOOP != 40
    case ELOOP: return 40;
#endif
#endif
#ifdef ENAMETOOLONG
#if ENAMETOOLONG != 36
    case ENAMETOOLONG: return 36;
#endif
#endif
#ifdef ENOSYS
#if ENOSYS != 38
    case ENOSYS: return 38;
#endif
#endif
#ifdef EOVERFLOW
#if EOVERFLOW != 75
    case EOVERFLOW: return 75;
#endif
#endif
#ifdef EOPNOTSUPP
#if EOPNOTSUPP != 95
    case EOPNOTSUPP: return 95;
#endif
#endif
#ifdef ENOTSUP
#if ENOTSUP != 95 && ENOTSUP != EOPNOTSUPP
    case ENOTSUP: return 95;
#endif
#endif
#ifdef ENOLCK
#if ENOLCK != 37
    case ENOLCK: return 37;
#endif
#endif
#ifdef ESTALE
#if ESTALE != 116
    case ESTALE: return 116;
#endif
#endif
#ifdef EDQUOT
#if EDQUOT != 122
    case EDQUOT: return 122;
#endif
#endif
    default:
        break;
    }
    if (host_errno > 0 && host_errno <= 34) {
        return host_errno;
    }
    return V2_EIO;
}

/* Copy a guest path out and translate it; returns 0 or -errno. */
static int resolve(struct v2_proc *proc, int dirfd, uint64_t address, char *out,
                   size_t size)
{
    char guest[V2_PATH_MAX];

    if (address == 0) {
        return -V2_EFAULT;
    }
    for (size_t index = 0; index < sizeof(guest); index++) {
        if (v2_space_read(proc->space, guest + index,
                          (const void *)(uintptr_t)(address + index), 1) != 0) {
            return -V2_EFAULT;
        }
        if (guest[index] == '\0') {
            return v2_proc_translate(proc, dirfd, guest, out, size);
        }
    }
    return -V2_ENAMETOOLONG;
}

static long long finish(int result)
{
    return result == 0 ? 0 : -(long long)v2_errno_from_host(errno);
}

long long v2_fs_mkdirat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int dirfd = (int)cpu->x[0];
    char path[V2_PATH_MAX * 2];
    int status = resolve(proc, dirfd, cpu->x[1], path, sizeof(path));

    if (status != 0) {
        return status;
    }
    if (mkdir(path, (mode_t)(cpu->x[2] & 07777)) != 0) {
        return -(long long)v2_errno_from_host(errno);
    }
    return 0;
}

long long v2_fs_unlinkat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int dirfd = (int)cpu->x[0];
    uint64_t flags = cpu->x[2];
    char path[V2_PATH_MAX * 2];
    int status = resolve(proc, dirfd, cpu->x[1], path, sizeof(path));

    if (status != 0) {
        return status;
    }
    if ((flags & V2_AT_REMOVEDIR) != 0) {
        return finish(rmdir(path));
    }
    return finish(unlink(path));
}

long long v2_fs_symlinkat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    char target[V2_PATH_MAX];
    char path[V2_PATH_MAX * 2];
    int status;

    /* The target is stored verbatim: it is resolved when someone follows it,
     * and rewriting it here would break absolute symlinks inside the root. */
    if (cpu->x[0] == 0) {
        return -V2_EFAULT;
    }
    for (size_t index = 0; index < sizeof(target); index++) {
        if (v2_space_read(proc->space, target + index,
                          (const void *)(uintptr_t)(cpu->x[0] + index), 1) != 0) {
            return -V2_EFAULT;
        }
        if (target[index] == '\0') {
            break;
        }
        if (index + 1 == sizeof(target)) {
            return -V2_ENAMETOOLONG;
        }
    }
    status = resolve(proc, (int)cpu->x[1], cpu->x[2], path, sizeof(path));
    if (status != 0) {
        return status;
    }
    return finish(symlink(target, path));
}

long long v2_fs_linkat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    char old_path[V2_PATH_MAX * 2];
    char new_path[V2_PATH_MAX * 2];
    int status = resolve(proc, (int)cpu->x[0], cpu->x[1], old_path,
                         sizeof(old_path));

    if (status != 0) {
        return status;
    }
    status = resolve(proc, (int)cpu->x[2], cpu->x[3], new_path,
                     sizeof(new_path));
    if (status != 0) {
        return status;
    }
    (void)cpu->x[4];   /* AT_SYMLINK_FOLLOW has no Darwin equivalent */
    return finish(link(old_path, new_path));
}

long long v2_fs_renameat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    char old_path[V2_PATH_MAX * 2];
    char new_path[V2_PATH_MAX * 2];
    int status = resolve(proc, (int)cpu->x[0], cpu->x[1], old_path,
                         sizeof(old_path));

    if (status != 0) {
        return status;
    }
    status = resolve(proc, (int)cpu->x[2], cpu->x[3], new_path,
                     sizeof(new_path));
    if (status != 0) {
        return status;
    }
    return finish(rename(old_path, new_path));
}

long long v2_fs_fchmod(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int host = v2_proc_fd_get(proc, (int)cpu->x[0]);

    if (host < 0) {
        return -V2_EBADF;
    }
    return finish(fchmod(host, (mode_t)(cpu->x[1] & 07777)));
}

long long v2_fs_fchmodat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int dirfd = (int)cpu->x[0];
    char path[V2_PATH_MAX * 2];
    int status = resolve(proc, dirfd, cpu->x[1], path, sizeof(path));
    mode_t mode = (mode_t)(cpu->x[2] & 07777);

    if (status != 0) {
        return status;
    }
    /*
     * Darwin has fchmodat but ignores AT_SYMLINK_NOFOLLOW for it, so a
     * symlink would be followed either way; saying so is better than
     * pretending.  apk only chmods regular files it just created.
     */
    if ((cpu->x[3] & V2_AT_SYMLINK_NOFOLLOW) != 0) {
        struct stat info;

        if (lstat(path, &info) != 0) {
            return -(long long)v2_errno_from_host(errno);
        }
        if (S_ISLNK(info.st_mode)) {
            return 0;
        }
    }
    return finish(chmod(path, mode));
}

long long v2_fs_fchownat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int dirfd = (int)cpu->x[0];
    char path[V2_PATH_MAX * 2];
    int status = resolve(proc, dirfd, cpu->x[1], path, sizeof(path));

    if (status != 0) {
        return status;
    }
    /* The guest is one user; every file already belongs to root.  Succeeding
     * without touching the host is the honest answer, not a silent failure. */
    (void)cpu->x[2];
    (void)cpu->x[3];
    return 0;
}

long long v2_fs_fsync(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int host = v2_proc_fd_get(proc, (int)cpu->x[0]);

    if (host < 0) {
        return -V2_EBADF;
    }
    return finish(fsync(host));
}

long long v2_fs_utimensat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int dirfd = (int)cpu->x[0];
    char path[V2_PATH_MAX * 2];
    struct stat info;
    int status;

    /* A NULL times pointer means "now", which is the common case. */
    if (cpu->x[2] == 0) {
        status = resolve(proc, dirfd, cpu->x[1], path, sizeof(path));
        if (status != 0) {
            return status;
        }
        return finish(utimes(path, NULL));
    }
    {
        int64_t seconds[2];
        int32_t nanos[2];

        if (v2_space_read(proc->space, seconds,
                          (const void *)(uintptr_t)cpu->x[2],
                          sizeof(seconds)) != 0 ||
            v2_space_read(proc->space, nanos,
                          (const void *)(uintptr_t)(cpu->x[2] + 16),
                          sizeof(nanos)) != 0) {
            return -V2_EFAULT;
        }
        status = resolve(proc, dirfd, cpu->x[1], path, sizeof(path));
        if (status != 0) {
            return status;
        }
        if (lstat(path, &info) != 0) {
            return -(long long)v2_errno_from_host(errno);
        }
        {
            struct timeval times[2];
            int64_t node[2];
            int64_t now = (int64_t)time(NULL);

            for (int index = 0; index < 2; index++) {
                if ((uint32_t)nanos[index] == V2_UTIME_OMIT) {
                    /* Darwin cannot express "leave this one alone"; using
                     * its current value is the closest honest answer. */
                    node[index] = index == 0 ? (int64_t)info.st_atime
                                             : (int64_t)info.st_mtime;
                } else if ((uint32_t)nanos[index] == V2_UTIME_NOW) {
                    node[index] = now;
                } else {
                    node[index] = seconds[index];
                }
                times[index].tv_sec = (time_t)node[index];
                times[index].tv_usec = 0;
            }
            return finish(utimes(path, times));
        }
    }
}

long long v2_fs_truncate(struct v2_cpu *cpu, struct v2_proc *proc)
{
    char path[V2_PATH_MAX * 2];
    int status = resolve(proc, V2_AT_FDCWD, cpu->x[0], path, sizeof(path));

    if (status != 0) {
        return status;
    }
    return finish(truncate(path, (off_t)(int64_t)cpu->x[1]));
}

long long v2_fs_ftruncate(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int host = v2_proc_fd_get(proc, (int)cpu->x[0]);

    if (host < 0) {
        return -V2_EBADF;
    }
    return finish(ftruncate(host, (off_t)(int64_t)cpu->x[1]));
}

long long v2_fs_flock(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int host = v2_proc_fd_get(proc, (int)cpu->x[0]);

    if (host < 0) {
        return -V2_EBADF;
    }
    /*
     * Single-threaded guest, one process: there is no second locker to
     * exclude.  Returning success is what the guest's lock is asking for.
     */
    (void)host;
    (void)cpu->x[1];
    return 0;
}

/* ------------------------------------------------------------------ statfs */

/*
 * aarch64's struct statfs is eight 8-byte words, then a two-int fsid, then
 * three more words and four spare -- 120 bytes.  It is filled by offset for
 * the same reason struct stat is: Darwin's layout differs after the first
 * field and a cast would compile and lie.
 */
#define V2_STATFS_SIZE 120

static long long fill_statfs(struct v2_proc *proc, uint64_t address)
{
    uint8_t block[V2_STATFS_SIZE];
    const uint64_t words[13] = {
        0xEF53,                 /* f_type: ext2/3/4, what Alpine's root is */
        4096,                   /* f_bsize */
        32ULL * 1024 * 1024,    /* f_blocks: 128 GiB of make-believe */
        24ULL * 1024 * 1024,    /* f_bfree */
        24ULL * 1024 * 1024,    /* f_bavail */
        1024 * 1024,            /* f_files */
        1024 * 1024,            /* f_ffree */
        0,                      /* f_fsid[0] */
        0,                      /* f_fsid[1] */
        255,                    /* f_namelen */
        4096,                   /* f_frsize */
        0,                      /* f_flags */
        0,                      /* f_spare[0] */
    };

    if (address == 0) {
        return -V2_EFAULT;
    }
    memset(block, 0, sizeof(block));
    for (int index = 0; index < 7; index++) {
        memcpy(block + index * 8, &words[index], 8);
    }
    memcpy(block + 56, &words[7], 8);       /* fsid is two 32-bit halves */
    for (int index = 0; index < 4; index++) {
        memcpy(block + 64 + index * 8, &words[9 + index], 8);
    }
    if (v2_space_write(proc->space, (void *)(uintptr_t)address, block,
                       sizeof(block)) != 0) {
        return -V2_EFAULT;
    }
    return 0;
}

long long v2_fs_statfs(struct v2_cpu *cpu, struct v2_proc *proc)
{
    char path[V2_PATH_MAX * 2];
    int status = resolve(proc, V2_AT_FDCWD, cpu->x[0], path, sizeof(path));

    if (status != 0) {
        return status;
    }
    /* Touching it proves the path exists; the numbers are ours. */
    if (access(path, F_OK) != 0) {
        return -(long long)v2_errno_from_host(errno);
    }
    return fill_statfs(proc, cpu->x[1]);
}

long long v2_fs_fstatfs(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int host = v2_proc_fd_get(proc, (int)cpu->x[0]);

    if (host < 0) {
        return -V2_EBADF;
    }
    return fill_statfs(proc, cpu->x[1]);
}
