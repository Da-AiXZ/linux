/*
 * v2/proc.h -- the guest process: file descriptors, root filesystem, heap.
 */
#ifndef V2_PROC_H
#define V2_PROC_H

#include <stddef.h>
#include <stdint.h>

#include "v2/elf.h"
#include "v2/vspace.h"

#define V2_MAX_FDS  64
#define V2_PATH_MAX 256

struct v2_proc {
    v2_space *space;
    struct v2_patcher *patcher;

    char root[V2_PATH_MAX];
    char cwd[V2_PATH_MAX];

    uint64_t brk_base;
    uint64_t brk_current;
    uint64_t brk_limit;

    uint64_t stack_base;
    uint64_t stack_top;

    uint64_t image_base;
    uint64_t image_entry;
    uint64_t image_phdr;
    uint64_t image_phnum;
    uint64_t image_phent;
    uint64_t image_base_interp;

    int fds[V2_MAX_FDS];
    char fd_path[V2_MAX_FDS][V2_PATH_MAX];
    /*
     * Directory streams, one per guest fd that has been read with getdents64.
     * Linux keeps a directory cursor in the descriptor; Darwin needs a DIR*
     * to iterate, so the cursor lives here instead of in the kernel.
     */
    void *dirs[V2_MAX_FDS];
};

int v2_proc_init(struct v2_proc *proc, v2_space *space, const char *root);

/*
 * Map a guest path into the host root, lexically: `.` and `..` are resolved
 * here and `..` can never climb above the root, so a guest cannot address
 * anything the root does not contain.
 */
int v2_proc_translate(struct v2_proc *proc, int dirfd, const char *guest,
                      char *out, size_t size);

/* The same normalisation, but the result stays in guest coordinates. */
int v2_proc_normalize(struct v2_proc *proc, int dirfd, const char *guest,
                      char *out, size_t size);

/* chdir, lexically: the host's working directory is never touched. */
int v2_proc_chdir(struct v2_proc *proc, int dirfd, const char *guest);

/* Drop a guest fd: closes the host fd and any directory stream on it. */
void v2_proc_fd_release(struct v2_proc *proc, int guest_fd);

int v2_proc_fd_alloc(struct v2_proc *proc, int host_fd, const char *path);
int v2_proc_fd_get(const struct v2_proc *proc, int guest_fd);

#endif /* V2_PROC_H */
