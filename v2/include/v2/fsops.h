/*
 * v2/fsops.h -- the syscalls that change the filesystem.
 *
 * They live apart from syscall.c for one reason: every one of them is
 * "translate a guest path, call the host, convert the errno", and that
 * pattern is worth writing once.  syscall.c keeps the dispatch table and the
 * read paths; this file owns the mutations apk needs (mkdir, unlink, rename,
 * symlink, chmod, times, truncate).
 */
#ifndef V2_FSOPS_H
#define V2_FSOPS_H

#include <stdint.h>

struct v2_cpu;
struct v2_proc;

typedef long long (*v2_syscall_fn)(struct v2_cpu *cpu, struct v2_proc *proc);

/*
 * Darwin and Linux agree on errno up to 34 and then diverge (ENOTEMPTY is 66
 * against 39, ENAMETOOLONG 63 against 36).  Handing a raw host errno to the
 * guest is how v1 made musl's resolver give up, so every mutation path goes
 * through this.
 */
int v2_errno_from_host(int host_errno);

long long v2_fs_mkdirat(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_unlinkat(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_symlinkat(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_linkat(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_renameat(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_fchmod(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_fchmodat(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_fchownat(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_fsync(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_utimensat(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_truncate(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_ftruncate(struct v2_cpu *cpu, struct v2_proc *proc);
long long v2_fs_flock(struct v2_cpu *cpu, struct v2_proc *proc);

#endif /* V2_FSOPS_H */
