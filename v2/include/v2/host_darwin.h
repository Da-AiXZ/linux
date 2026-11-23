/*
 * v2/host_darwin.h -- the platform boundary.
 */
#ifndef V2_HOST_DARWIN_H
#define V2_HOST_DARWIN_H

#include "v2/vspace.h"

/* mmap/mprotect/madvise/pread + icache, for macOS on aarch64. */
struct v2_host v2_host_darwin(void);

#endif /* V2_HOST_DARWIN_H */
