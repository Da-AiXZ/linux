/*
 * v2/syscall.c -- the guest's view of the host, table driven.
 *
 * One entry point, one exit: a handler returns 0 or -errno, the dispatcher
 * writes x0 and advances pc.  No handler is allowed to return a raw Darwin
 * errno -- the numbers differ from Linux above 34, and a wrong errno made
 * musl's resolver give up in v1.
 */
#include "v2/cpu.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "v2/fsops.h"
#include "v2/patch.h"
#include "v2/proc.h"
#include "v2/diag.h"
#include "v2/systrace.h"
#include "v2/sysnames.h"
#include "v2/vmops.h"
#include "v2/vspace.h"

struct v2_proc *v2_current_process;
struct v2_patcher *v2_current_patcher;
_Thread_local uint64_t v2_tls_shadow;

static long long log_unsupported(uint64_t number)
{
    static uint8_t seen[320];

    if (number < sizeof(seen) && !seen[number]) {
        seen[number] = 1;
        fprintf(stderr, "[v2] unsupported syscall %llu (%s)\n",
                (unsigned long long)number, v2_syscall_name((unsigned)number));
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

/* Write a guest range to a host fd, in chunks.  Shared by write and writev. */
static uint64_t write_range(struct v2_proc *proc, int host, uint64_t buffer,
                            uint64_t count, long long *error)
{
    uint8_t chunk[4096];
    uint64_t done = 0;

    while (done < count) {
        size_t want = (size_t)(count - done);
        ssize_t written;

        if (want > sizeof(chunk)) {
            want = sizeof(chunk);
        }
        if (v2_space_read(proc->space, chunk,
                          (const void *)(uintptr_t)(buffer + done),
                          want) != 0) {
            *error = -V2_EFAULT;
            return done;
        }
        written = write(host, chunk, want);
        if (written < 0) {
            *error = -V2_EIO;
            return done;
        }
        done += (uint64_t)written;
        if ((size_t)written < want) {
            break;
        }
    }
    *error = 0;
    return done;
}

/*
 * When ld.so gives up it prints "Error relocating ..." and exits 127 in the
 * next handful of instructions, so the exit-time dump is already too late.
 * This is the only moment the state exists: dump the registers and the top of
 * the stack while the guest is still standing there.
 *
 * On the device the flake reproduces on the first run, which makes this cheap
 * to iterate on; on the CI runner it fires once every ~500 runs and costs
 * nothing when it does not.
 */
static void dump_relocation_state(struct v2_cpu *cpu, struct v2_proc *proc,
                                  uint64_t address, uint64_t length)
{
    static char seen[512];
    static size_t seen_length;
    static int reported;
    char text[256];
    uint64_t words[16];
    size_t want = length < sizeof(text) - 1 ? length : sizeof(text) - 1;
    size_t room;

    if (reported || want == 0 ||
        v2_space_read(proc->space, text, (const void *)(uintptr_t)address,
                      want) != 0) {
        return;
    }
    text[want] = 0;
    /*
     * musl flushes stdio through __overflow, which writes two bytes at a time
     * when the buffer is drained -- so the sentence "Error relocating" is
     * never inside a single write().  Looking for it in one chunk missed every
     * failure of one CI run (six of them), which is a hook that silently does
     * nothing.  Accumulate what fd 2 receives instead.
     */
    room = sizeof(seen) - 1 - seen_length;
    if (room > want) {
        room = want;
    }
    memcpy(seen + seen_length, text, room);
    seen_length += room;
    seen[seen_length] = 0;
    if (strstr(seen, "Error relocating") == NULL) {
        return;
    }
    reported = 1;
    fprintf(stderr, "[v2] --- relocation error, registers at the write ---\n");
    for (int index = 0; index < 31; index += 2) {
        fprintf(stderr, "[v2] x%-2d=0x%016llx  x%-2d=0x%016llx\n", index,
                (unsigned long long)cpu->x[index], index + 1,
                (unsigned long long)cpu->x[index + 1]);
    }
    fprintf(stderr, "[v2] sp=0x%llx pc=0x%llx nzcv=0x%llx\n",
            (unsigned long long)cpu->sp, (unsigned long long)cpu->pc,
            (unsigned long long)cpu->nzcv);
    if (v2_space_read(proc->space, words,
                      (const void *)(uintptr_t)(cpu->sp & ~(uint64_t)7),
                      sizeof(words)) == 0) {
        for (int index = 0; index < 16; index++) {
            fprintf(stderr, "[v2] [sp+%3d] 0x%016llx\n", index * 8,
                    (unsigned long long)words[index]);
        }
    }
    /*
     * The registers say where find_sym was, but not whether the table it read
     * was still the file's.  Compare now, while the process is intact, and
     * over read-only pages too: a symbol lookup that fails on correct code is
     * the one thing an executable-only comparison cannot distinguish from a
     * corrupted hash table.
     */
    v2_verify_dump_at_failure();
}

static long long sys_write(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int fd = (int)cpu->x[0];
    int host = v2_proc_fd_get(proc, fd);
    long long error = 0;
    uint64_t done;

    if (host < 0) {
        return -V2_EBADF;
    }
    dump_relocation_state(cpu, proc, cpu->x[1], cpu->x[2]);
    done = write_range(proc, host, cpu->x[1], cpu->x[2], &error);
    if (done == 0 && error != 0) {
        return error;
    }
    return (long long)done;
}

/*
 * writev/readv matter more than they look: musl's stdio flushes through
 * writev whenever more than one buffer is pending, so without it every
 * applet prints nothing and the failure looks like "the program did not
 * produce output" rather than "a syscall is missing".
 */
static long long sys_writev(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int fd = (int)cpu->x[0];
    uint64_t vectors = cpu->x[1];
    uint64_t count = cpu->x[2];
    int host = v2_proc_fd_get(proc, fd);
    uint64_t total = 0;

    if (host < 0) {
        return -V2_EBADF;
    }
    if (count > 1024) {
        return -V2_EINVAL;
    }
    for (uint64_t index = 0; index < count; index++) {
        uint64_t base = 0;
        uint64_t length = 0;
        long long error = 0;
        uint64_t written;

        if (v2_space_read(proc->space, &base,
                          (const void *)(uintptr_t)(vectors + index * 16),
                          8) != 0 ||
            v2_space_read(proc->space, &length,
                          (const void *)(uintptr_t)(vectors + index * 16 + 8),
                          8) != 0) {
            return total > 0 ? (long long)total : -V2_EFAULT;
        }
        /*
         * ld.so's error goes out through writev, not write: musl's stdio
         * flushes through __stdio_write.  0.1.9's specimen proved it by
         * failing with no register dump at all.
         */
        dump_relocation_state(cpu, proc, base, length);
        written = write_range(proc, host, base, length, &error);
        total += written;
        if (written < length) {
            return total > 0 ? (long long)total : error;
        }
    }
    return (long long)total;
}

static long long sys_readv(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int fd = (int)cpu->x[0];
    uint64_t vectors = cpu->x[1];
    uint64_t count = cpu->x[2];
    int host = v2_proc_fd_get(proc, fd);
    uint64_t total = 0;
    uint8_t chunk[4096];

    if (host < 0) {
        return -V2_EBADF;
    }
    if (count > 1024) {
        return -V2_EINVAL;
    }
    for (uint64_t index = 0; index < count; index++) {
        uint64_t base = 0;
        uint64_t length = 0;
        uint64_t done = 0;

        if (v2_space_read(proc->space, &base,
                          (const void *)(uintptr_t)(vectors + index * 16),
                          8) != 0 ||
            v2_space_read(proc->space, &length,
                          (const void *)(uintptr_t)(vectors + index * 16 + 8),
                          8) != 0) {
            return total > 0 ? (long long)total : -V2_EFAULT;
        }
        while (done < length) {
            size_t want = (size_t)(length - done);
            ssize_t got;

            if (want > sizeof(chunk)) {
                want = sizeof(chunk);
            }
            got = read(host, chunk, want);
            if (got < 0) {
                return total > 0 ? (long long)total : -V2_EIO;
            }
            if (got == 0) {
                return (long long)total;
            }
            if (v2_space_write(proc->space,
                               (void *)(uintptr_t)(base + done), chunk,
                               (size_t)got) != 0) {
                return total > 0 ? (long long)total : -V2_EFAULT;
            }
            done += (uint64_t)got;
            total += (uint64_t)got;
            if ((size_t)got < want) {
                return (long long)total;
            }
        }
    }
    return (long long)total;
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

/*
 * pread64.  ld.so reads program headers with it precisely because it must not
 * disturb the file offset, and musl's mmap-based file loading relies on that.
 */
static long long sys_pread64(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int fd = (int)cpu->x[0];
    uint64_t buffer = cpu->x[1];
    uint64_t count = cpu->x[2];
    int64_t offset = (int64_t)cpu->x[3];
    int host = v2_proc_fd_get(proc, fd);
    uint8_t chunk[4096];
    uint64_t done = 0;

    if (host < 0) {
        return -V2_EBADF;
    }
    if (offset < 0) {
        return -V2_EINVAL;
    }
    while (done < count) {
        size_t want = (size_t)(count - done);
        ssize_t got;

        if (want > sizeof(chunk)) {
            want = sizeof(chunk);
        }
        got = pread(host, chunk, want, (off_t)(offset + (int64_t)done));
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
    char normal[V2_PATH_MAX];
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
    /* Store the normalised *guest* path: a later openat through this
     * descriptor joins onto it, and the raw argument may be "../x". */
    status = v2_proc_normalize(proc, dirfd, guest, normal, sizeof(normal));
    if (status != 0) {
        return status;
    }
    host_fd = open(host_path, host_flags_from_linux(flags), 0644);
    if (host_fd < 0) {
        return errno == ENOENT ? -V2_ENOENT
             : errno == ENOTDIR ? -V2_ENOTDIR : -V2_EACCES;
    }
    guest_fd = v2_proc_fd_alloc(proc, host_fd, normal);
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
    v2_proc_fd_release(proc, fd);
    return 0;
}

/* ------------------------------------------------------------ filesystem */

/*
 * aarch64 Linux `struct stat` is 128 bytes and its layout differs from
 * Darwin's in every field after the first two, so it is filled by offset
 * rather than by casting -- a cast would compile and then quietly report a
 * negative size.
 */
static void encode_stat(const struct stat *info, uint8_t out[128])
{
    uint64_t device = (uint64_t)info->st_dev;
    uint64_t inode = (uint64_t)info->st_ino;
    uint32_t mode = (uint32_t)info->st_mode;
    uint32_t links = (uint32_t)info->st_nlink;
    /*
     * The guest is a single-user machine: every file belongs to its root.
     * Passing the host's uid through made `ls -l` print "501 20" -- numbers
     * that mean nothing inside the guest and match no /etc/passwd entry.
     */
    uint32_t uid = 0;
    uint32_t gid = 0;
    uint64_t rdev = (uint64_t)info->st_rdev;
    uint64_t pad1 = 0;
    int64_t size = (int64_t)info->st_size;
    int32_t block_size = (int32_t)info->st_blksize;
    int32_t pad2 = 0;
    int64_t blocks = (int64_t)info->st_blocks;
    int64_t atime = (int64_t)info->st_atimespec.tv_sec;
    uint64_t atime_nsec = (uint64_t)info->st_atimespec.tv_nsec;
    int64_t mtime = (int64_t)info->st_mtimespec.tv_sec;
    uint64_t mtime_nsec = (uint64_t)info->st_mtimespec.tv_nsec;
    int64_t ctime = (int64_t)info->st_ctimespec.tv_sec;
    uint64_t ctime_nsec = (uint64_t)info->st_ctimespec.tv_nsec;

    memset(out, 0, 128);
    memcpy(out + 0, &device, 8);
    memcpy(out + 8, &inode, 8);
    memcpy(out + 16, &mode, 4);
    memcpy(out + 20, &links, 4);
    memcpy(out + 24, &uid, 4);
    memcpy(out + 28, &gid, 4);
    memcpy(out + 32, &rdev, 8);
    memcpy(out + 40, &pad1, 8);
    memcpy(out + 48, &size, 8);
    memcpy(out + 56, &block_size, 4);
    memcpy(out + 60, &pad2, 4);
    memcpy(out + 64, &blocks, 8);
    memcpy(out + 72, &atime, 8);
    memcpy(out + 80, &atime_nsec, 8);
    memcpy(out + 88, &mtime, 8);
    memcpy(out + 96, &mtime_nsec, 8);
    memcpy(out + 104, &ctime, 8);
    memcpy(out + 112, &ctime_nsec, 8);
}

static long long write_stat(struct v2_proc *proc, uint64_t address,
                            const struct stat *info)
{
    uint8_t encoded[128];

    encode_stat(info, encoded);
    if (v2_space_write(proc->space, (void *)(uintptr_t)address, encoded,
                       sizeof(encoded)) != 0) {
        return -V2_EFAULT;
    }
    return 0;
}

static long long sys_fstat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int host = v2_proc_fd_get(proc, (int)cpu->x[0]);
    struct stat info;

    if (host < 0) {
        return -V2_EBADF;
    }
    if (fstat(host, &info) != 0) {
        return -V2_EIO;
    }
    return write_stat(proc, cpu->x[1], &info);
}

static long long sys_newfstatat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int dirfd = (int)cpu->x[0];
    char guest[V2_PATH_MAX];
    char host_path[V2_PATH_MAX * 2];
    struct stat info;
    uint64_t flags = cpu->x[3];
    int status;

    /* AT_EMPTY_PATH: stat the descriptor itself.  musl uses this for fstat. */
    status = copy_string(proc, guest, sizeof(guest), cpu->x[1]);
    if (status != 0) {
        if (status == -V2_EFAULT && (flags & 0x1000u) != 0) {
            return sys_fstat(cpu, proc);
        }
        return status;
    }
    if (guest[0] == '\0' && (flags & 0x1000u) != 0) {
        return sys_fstat(cpu, proc);
    }
    status = v2_proc_translate(proc, dirfd, guest, host_path, sizeof(host_path));
    if (status != 0) {
        return status;
    }
    if (fstatat(AT_FDCWD, host_path, &info,
                (flags & 0x100u) != 0 ? AT_SYMLINK_NOFOLLOW : 0) != 0) {
        return errno == ENOENT ? -V2_ENOENT
             : errno == ENOTDIR ? -V2_ENOTDIR : -V2_EACCES;
    }
    return write_stat(proc, cpu->x[2], &info);
}

static uint8_t linux_dirent_type(uint8_t type)
{
    switch (type) {
    case DT_FIFO: return 1;
    case DT_CHR:  return 2;
    case DT_DIR:  return 4;
    case DT_BLK:  return 6;
    case DT_REG:  return 8;
    case DT_LNK:  return 10;
    case DT_SOCK: return 12;
    default:      return 0;      /* DT_UNKNOWN */
    }
}

static long long sys_getdents64(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int guest_fd = (int)cpu->x[0];
    uint64_t buffer = cpu->x[1];
    uint64_t count = cpu->x[2];
    int host = v2_proc_fd_get(proc, guest_fd);
    DIR *dir;
    uint8_t out[4096];
    size_t used = 0;

    if (host < 0) {
        return -V2_EBADF;
    }
    if (count == 0 || count > sizeof(out)) {
        count = count == 0 ? 0 : sizeof(out);
        if (count == 0) {
            return -V2_EINVAL;
        }
    }
    dir = (DIR *)proc->dirs[guest_fd];
    if (dir == NULL) {
        int copy = dup(host);

        if (copy < 0) {
            return -V2_EIO;
        }
        dir = fdopendir(copy);
        if (dir == NULL) {
            close(copy);
            return -V2_ENOTDIR;
        }
        proc->dirs[guest_fd] = dir;
    }
    while (used < count) {
        long position = telldir(dir);
        struct dirent *entry = readdir(dir);
        size_t name_length;
        size_t record;
        uint64_t inode;
        int64_t offset;
        uint16_t record_length;
        uint8_t type;
        int64_t next;

        if (entry == NULL) {
            break;
        }
        name_length = strlen(entry->d_name);
        record = (19 + name_length + 1 + 7) & ~(size_t)7;
        if (used + record > count) {
            seekdir(dir, position);      /* it did not fit; next call retries */
            break;
        }
        inode = (uint64_t)entry->d_ino;
        next = (int64_t)telldir(dir);
        offset = next;
        record_length = (uint16_t)record;
        type = linux_dirent_type(entry->d_type);
        memcpy(out + used + 0, &inode, 8);
        memcpy(out + used + 8, &offset, 8);
        memcpy(out + used + 16, &record_length, 2);
        out[used + 18] = type;
        memcpy(out + used + 19, entry->d_name, name_length + 1);
        used += record;
    }
    if (used > 0 &&
        v2_space_write(proc->space, (void *)(uintptr_t)buffer, out, used) != 0) {
        return -V2_EFAULT;
    }
    return (long long)used;
}

static long long sys_lseek(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int guest_fd = (int)cpu->x[0];
    int64_t offset = (int64_t)cpu->x[1];
    int whence = (int)cpu->x[2];
    int host = v2_proc_fd_get(proc, guest_fd);
    off_t result;

    if (host < 0) {
        return -V2_EBADF;
    }
    if (proc->dirs[guest_fd] != NULL && offset == 0 && whence == SEEK_SET) {
        rewinddir((DIR *)proc->dirs[guest_fd]);
        return 0;
    }
    result = lseek(host, (off_t)offset, whence);
    if (result < 0) {
        return -V2_EINVAL;
    }
    return (long long)result;
}

static long long sys_getcwd(struct v2_cpu *cpu, struct v2_proc *proc)
{
    uint64_t buffer = cpu->x[0];
    uint64_t size = cpu->x[1];
    size_t length = strlen(proc->cwd) + 1;

    if (size < length) {
        return -V2_ERANGE;
    }
    if (v2_space_write(proc->space, (void *)(uintptr_t)buffer, proc->cwd,
                       length) != 0) {
        return -V2_EFAULT;
    }
    return (long long)(int64_t)buffer;   /* Linux returns the pointer */
}

static long long sys_chdir(struct v2_cpu *cpu, struct v2_proc *proc)
{
    char guest[V2_PATH_MAX];
    int status = copy_string(proc, guest, sizeof(guest), cpu->x[0]);

    if (status != 0) {
        return status;
    }
    return v2_proc_chdir(proc, -1, guest);
}

static long long sys_fchdir(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int fd = (int)cpu->x[0];

    if (fd < 0 || fd >= V2_MAX_FDS || proc->fd_path[fd][0] == '\0') {
        return -V2_EBADF;
    }
    snprintf(proc->cwd, sizeof(proc->cwd), "%s", proc->fd_path[fd]);
    return 0;
}

static long long sys_readlinkat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int dirfd = (int)cpu->x[0];
    char guest[V2_PATH_MAX];
    char host_path[V2_PATH_MAX * 2];
    char target[V2_PATH_MAX];
    ssize_t got;
    int status;

    status = copy_string(proc, guest, sizeof(guest), cpu->x[1]);
    if (status != 0) {
        return status;
    }
    status = v2_proc_translate(proc, dirfd, guest, host_path, sizeof(host_path));
    if (status != 0) {
        return status;
    }
    got = readlink(host_path, target, sizeof(target));
    if (got < 0) {
        return errno == ENOENT ? -V2_ENOENT : -V2_EINVAL;
    }
    /*
     * readlinkat takes a buffer size and Linux truncates to it.  Writing the
     * whole target regardless would push up to V2_PATH_MAX bytes past the
     * caller's buffer, straight into whatever it had put there.
     */
    if ((uint64_t)got > cpu->x[3]) {
        got = (ssize_t)cpu->x[3];
    }
    if (v2_space_write(proc->space, (void *)(uintptr_t)cpu->x[2], target,
                       (size_t)got) != 0) {
        return -V2_EFAULT;
    }
    return (long long)got;
}

static long long sys_faccessat(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int dirfd = (int)cpu->x[0];
    char guest[V2_PATH_MAX];
    char host_path[V2_PATH_MAX * 2];
    int mode = (int)cpu->x[2];
    int status;

    status = copy_string(proc, guest, sizeof(guest), cpu->x[1]);
    if (status != 0) {
        return status;
    }
    status = v2_proc_translate(proc, dirfd, guest, host_path, sizeof(host_path));
    if (status != 0) {
        return status;
    }
    return access(host_path, mode) == 0 ? 0 : -V2_EACCES;
}

static long long sys_fcntl(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int fd = (int)cpu->x[0];
    int command = (int)cpu->x[1];
    int host = v2_proc_fd_get(proc, fd);

    if (host < 0) {
        return -V2_EBADF;
    }
    switch (command) {
    case 0:      /* F_DUPFD */
    case 1030: { /* F_DUPFD_CLOEXEC */
        int copy = dup(host);

        if (copy < 0) {
            return -V2_EMFILE;
        }
        return v2_proc_fd_alloc(proc, copy, proc->fd_path[fd]);
    }
    case 1:  /* F_GETFD */
    case 3:  /* F_GETFL */
        return fcntl(host, command, 0);
    case 2:  /* F_SETFD */
    case 4:  /* F_SETFL */
        return fcntl(host, command, (int)cpu->x[2]);
    case 5:  /* F_GETLK  */
    case 6:  /* F_SETLK  */
    case 7:  /* F_SETLKW */
        /* One process, one thread: there is no second locker.  Succeeding
         * is what apk's db lock is asking for (Darwin numbers these 7/8/9,
         * so they must not be forwarded). */
        return 0;
    default:
        return -V2_EINVAL;
    }
}

static long long sys_dup(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int fd = (int)cpu->x[0];
    int host = v2_proc_fd_get(proc, fd);
    int copy;

    if (host < 0) {
        return -V2_EBADF;
    }
    copy = dup(host);
    if (copy < 0) {
        return -V2_EMFILE;
    }
    return v2_proc_fd_alloc(proc, copy, proc->fd_path[fd]);
}

/* -------------------------------------------------------------- process */

static long long sys_prlimit64(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int resource = (int)cpu->x[0];
    uint64_t old_address = cpu->x[2];
    uint64_t pair[2];

    /* The guest heap and stack are fixed, so the honest answer is the value
     * the runtime actually has rather than the host's much larger one. */
    if (resource == 3) {          /* RLIMIT_STACK */
        pair[0] = 8u * 1024u * 1024u;
        pair[1] = 8u * 1024u * 1024u;
    } else if (resource == 7) {   /* RLIMIT_NOFILE */
        pair[0] = V2_MAX_FDS;
        pair[1] = V2_MAX_FDS;
    } else {
        pair[0] = 1024;
        pair[1] = 1024;
    }
    if (old_address != 0 &&
        v2_space_write(proc->space, (void *)(uintptr_t)old_address, pair,
                       sizeof(pair)) != 0) {
        return -V2_EFAULT;
    }
    return 0;
}

static long long sys_sched_getaffinity(struct v2_cpu *cpu, struct v2_proc *proc)
{
    uint64_t mask = 1;      /* one CPU: the guest is a single thread today */

    if (v2_space_write(proc->space, (void *)(uintptr_t)cpu->x[2], &mask,
                       sizeof(mask)) != 0) {
        return -V2_EFAULT;
    }
    return (long long)sizeof(mask);
}

static long long sys_nanosleep(struct v2_cpu *cpu, struct v2_proc *proc)
{
    int64_t request[2];
    struct timespec wanted;

    if (v2_space_read(proc->space, request, (const void *)(uintptr_t)cpu->x[0],
                      sizeof(request)) != 0) {
        return -V2_EFAULT;
    }
    wanted.tv_sec = (time_t)request[0];
    wanted.tv_nsec = (long)request[1];
    while (nanosleep(&wanted, &wanted) != 0 && errno == EINTR) {
        /* a signal is not modelled yet; keep sleeping like SA_RESTART */
    }
    return 0;
}

static long long sys_getppid(struct v2_cpu *cpu, struct v2_proc *proc)
{
    (void)cpu;
    (void)proc;
    return 1;
}

static long long sys_getgroups(struct v2_cpu *cpu, struct v2_proc *proc)
{
    uint64_t size = cpu->x[0];
    uint64_t list = cpu->x[1];
    uint32_t group = 0;         /* the guest runs as root, in root's group */

    if (size == 0) {
        return 1;
    }
    if (size > 1) {
        size = 1;
    }
    if (v2_space_write(proc->space, (void *)(uintptr_t)list, &group,
                       sizeof(group)) != 0) {
        return -V2_EFAULT;
    }
    return (long long)size;
}

static long long sys_umask(struct v2_cpu *cpu, struct v2_proc *proc)
{
    (void)cpu;
    (void)proc;
    return 022;
}

static long long sys_ignore(struct v2_cpu *cpu, struct v2_proc *proc)
{
    (void)cpu;
    (void)proc;
    return 0;
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

    if (getenv("V2_TIME_FREEZE") != NULL) {
        /*
         * Every other input this guest sees is deterministic: the image is a
         * file, getrandom is a fixed-seed generator, and the address space is
         * built from a fixed base.  The clock was the one exception, which
         * makes it impossible to say two runs had the same inputs -- and a
         * trace diff between two runs that differ in their inputs proves
         * nothing.  Frozen for diagnosis only; never in a shipped build.
         */
        value.tv_sec = 1735689600;   /* 2025-01-01T00:00:00Z */
        value.tv_nsec = 0;
    } else if (id == 0) {
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
    /* Under V2_VERIFY this says whether any library's bytes changed while the
     * guest was running -- the difference between "we broke it" and "musl
     * cannot find a symbol that is right there". */
    v2_verify_dump();
    v2_trace_flush();
    fflush(stderr);
    _exit((int)(cpu->x[0] & 0xFF));
}

/* ---------------------------------------------------------------- table */

struct v2_sysent {
    const char *name;
    v2_syscall_fn fn;
};

static const struct v2_sysent table[320] = {
    [17] = {"getcwd", sys_getcwd},
    [23] = {"dup", sys_dup},
    [25] = {"fcntl", sys_fcntl},
    [29] = {"ioctl", sys_ioctl},
    [32] = {"flock", v2_fs_flock},
    [34] = {"mkdirat", v2_fs_mkdirat},
    [35] = {"unlinkat", v2_fs_unlinkat},
    [36] = {"symlinkat", v2_fs_symlinkat},
    [37] = {"linkat", v2_fs_linkat},
    [38] = {"renameat", v2_fs_renameat},
    [43] = {"statfs", v2_fs_statfs},
    [44] = {"fstatfs", v2_fs_fstatfs},
    [45] = {"truncate", v2_fs_truncate},
    [46] = {"ftruncate", v2_fs_ftruncate},
    [52] = {"fchmod", v2_fs_fchmod},
    [53] = {"fchmodat", v2_fs_fchmodat},
    [54] = {"fchownat", v2_fs_fchownat},
    [81] = {"sync", sys_ok},
    [82] = {"fsync", v2_fs_fsync},
    [83] = {"fdatasync", v2_fs_fsync},
    [88] = {"utimensat", v2_fs_utimensat},
    [48] = {"faccessat", sys_faccessat},
    [49] = {"chdir", sys_chdir},
    [50] = {"fchdir", sys_fchdir},
    [56] = {"openat", sys_openat},
    [57] = {"close", sys_close},
    [61] = {"getdents64", sys_getdents64},
    [62] = {"lseek", sys_lseek},
    [63] = {"read", sys_read},
    [64] = {"write", sys_write},
    [65] = {"readv", sys_readv},
    [66] = {"writev", sys_writev},
    [67] = {"pread64", sys_pread64},
    [78] = {"readlinkat", sys_readlinkat},
    [79] = {"newfstatat", sys_newfstatat},
    [80] = {"fstat", sys_fstat},
    [93] = {"exit", sys_exit},
    [94] = {"exit_group", sys_exit},
    [96] = {"set_tid_address", sys_getpid},
    [99] = {"set_robust_list", sys_ok},
    [101] = {"nanosleep", sys_nanosleep},
    [113] = {"clock_gettime", sys_clock_gettime},
    [123] = {"sched_getaffinity", sys_sched_getaffinity},
    [132] = {"sigaltstack", sys_ignore},
    [134] = {"rt_sigaction", sys_ignore},
    [135] = {"rt_sigprocmask", sys_ignore},
    [139] = {"rt_sigreturn", sys_ignore},
    [153] = {"getgroups", sys_getgroups},
    [154] = {"setgroups", sys_ok},
    [155] = {"sched_setscheduler", sys_ok},
    [156] = {"sched_getscheduler", sys_ok},
    [157] = {"sched_getparam", sys_ok},
    [158] = {"sched_setparam", sys_ok},
    [160] = {"uname", sys_uname},
    [166] = {"umask", sys_umask},
    [172] = {"getpid", sys_getpid},
    [173] = {"getppid", sys_getppid},
    [174] = {"getuid", sys_getuid},
    [175] = {"geteuid", sys_getuid},
    [176] = {"getgid", sys_getuid},
    [177] = {"getegid", sys_getuid},
    [178] = {"gettid", sys_getpid},
    [214] = {"brk", v2_vm_brk},
    [215] = {"munmap", v2_vm_munmap},
    [216] = {"mremap", v2_vm_mremap},
    [222] = {"mmap", v2_vm_mmap},
    [226] = {"mprotect", v2_vm_mprotect},
    [233] = {"madvise", v2_vm_madvise},
    [261] = {"prlimit64", sys_prlimit64},
    [278] = {"getrandom", sys_getrandom},
};

static unsigned long dispatch_count;

void v2_syscall_dispatch(struct v2_cpu *cpu)
{
    uint64_t site = cpu->pc;
    struct v2_proc *proc = v2_current_process;
    const struct v2_patch_site *patch = NULL;
    const char *name = "unknown";
    uint64_t args[6];
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

    /*
     * x0..x5 are the arguments and the handler owns them, so they are copied
     * out first: after the call x0 is the result and the rest are whatever the
     * handler left behind.  A trace that records those is a trace of the
     * handler, not of the call.
     */
    v2_diag_entry(cpu);
    number = cpu->x[8];
    for (int index = 0; index < 6; index++) {
        args[index] = cpu->x[index];
    }
    if (number < 320 && table[number].fn != NULL) {
        name = table[number].name;
        result = table[number].fn(cpu, proc);
    } else {
        result = log_unsupported(number);
    }
    cpu->x[0] = (uint64_t)result;
    v2_trace_record(site, number, name, result, args);
    v2_diag_boundary(cpu, dispatch_count++);
}
