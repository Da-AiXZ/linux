/*
 * v2/proc.c -- guest process bookkeeping.
 */
#include "v2/proc.h"

#include <stdio.h>
#include <string.h>

int v2_proc_init(struct v2_proc *proc, v2_space *space, const char *root)
{
    memset(proc, 0, sizeof(*proc));
    proc->space = space;
    for (int index = 0; index < V2_MAX_FDS; index++) {
        proc->fds[index] = -1;
    }
    /* 0/1/2 are inherited: the runner's own stdio is the guest's console. */
    proc->fds[0] = 0;
    proc->fds[1] = 1;
    proc->fds[2] = 2;
    snprintf(proc->fd_path[0], V2_PATH_MAX, "/dev/stdin");
    snprintf(proc->fd_path[1], V2_PATH_MAX, "/dev/stdout");
    snprintf(proc->fd_path[2], V2_PATH_MAX, "/dev/stderr");
    if (root == NULL || root[0] == '\0') {
        return -V2_EINVAL;
    }
    snprintf(proc->root, sizeof(proc->root), "%s", root);
    snprintf(proc->cwd, sizeof(proc->cwd), "/");
    return 0;
}

/*
 * Lexical normalisation: split on '/', drop empty and ".", pop on "..".
 * Nothing here touches the filesystem, so a symlink cannot escape the root --
 * and nothing here needs to, because the guest only ever sees this root.
 */
static int normalise(const char *path, char *out, size_t size)
{
    char scratch[V2_PATH_MAX * 2];
    size_t length = 0;
    const char *cursor = path;

    if (strlen(path) >= sizeof(scratch)) {
        return -V2_EINVAL;
    }
    while (*cursor != '\0') {
        const char *slash = strchr(cursor, '/');
        size_t chunk = slash != NULL ? (size_t)(slash - cursor) : strlen(cursor);

        if (chunk == 0 || (chunk == 1 && cursor[0] == '.')) {
            /* empty or "." -- nothing to do */
        } else if (chunk == 2 && cursor[0] == '.' && cursor[1] == '.') {
            while (length > 0 && scratch[length - 1] != '/') {
                length--;
            }
            if (length > 0) {
                length--;       /* drop the separator too */
            }
        } else {
            if (length + 1 + chunk >= sizeof(scratch)) {
                return -V2_EINVAL;
            }
            scratch[length++] = '/';
            memcpy(scratch + length, cursor, chunk);
            length += chunk;
        }
        if (slash == NULL) {
            break;
        }
        cursor = slash + 1;
    }
    scratch[length] = '\0';
    if (length == 0) {
        snprintf(scratch, sizeof(scratch), "/");
        length = 1;
    }
    if (length >= size) {
        return -V2_EINVAL;
    }
    memcpy(out, scratch, length + 1);
    return 0;
}

int v2_proc_translate(struct v2_proc *proc, int dirfd, const char *guest,
                      char *out, size_t size)
{
    char combined[V2_PATH_MAX * 2];
    char normal[V2_PATH_MAX];
    int written;
    int status;

    if (guest == NULL || guest[0] == '\0') {
        return -V2_ENOENT;
    }
    if (guest[0] == '/') {
        written = snprintf(combined, sizeof(combined), "%s", guest);
    } else if (dirfd >= 0 && dirfd != -100 /* AT_FDCWD */) {
        const char *base = proc->fd_path[dirfd];

        if (dirfd >= V2_MAX_FDS || base[0] == '\0') {
            return -V2_EBADF;
        }
        written = snprintf(combined, sizeof(combined), "%s/%s", base, guest);
    } else {
        written = snprintf(combined, sizeof(combined), "%s/%s", proc->cwd,
                           guest);
    }
    if (written < 0 || (size_t)written >= sizeof(combined)) {
        return -V2_ENAMETOOLONG;
    }
    status = normalise(combined, normal, sizeof(normal));
    if (status != 0) {
        return status;
    }
    written = snprintf(out, size, "%s%s", proc->root, normal);
    if (written < 0 || (size_t)written >= size) {
        return -V2_ENAMETOOLONG;
    }
    return 0;
}

int v2_proc_fd_alloc(struct v2_proc *proc, int host_fd, const char *path)
{
    for (int index = 3; index < V2_MAX_FDS; index++) {
        if (proc->fds[index] < 0) {
            proc->fds[index] = host_fd;
            snprintf(proc->fd_path[index], V2_PATH_MAX, "%s", path);
            return index;
        }
    }
    return -1;
}

int v2_proc_fd_get(const struct v2_proc *proc, int guest_fd)
{
    if (guest_fd < 0 || guest_fd >= V2_MAX_FDS) {
        return -1;
    }
    return proc->fds[guest_fd];
}
