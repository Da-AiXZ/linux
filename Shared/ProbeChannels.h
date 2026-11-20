#pragma once

#include <stdint.h>

/*
 * Privilege-free result channels tried by the probe extension:
 *
 * 1. Reverse bootstrap: the extension checks in, the host looks it up and
 *    sends a receive right back.
 * 2. POSIX shared memory (a global name both processes can open).
 * 3. Darwin notify 64-bit state words, published under fixed names.
 * 4. The general pasteboard (may prompt the user on read).
 */

#define PROBE_BOOT_SERVICE "com.daixz.linux.probe.LiveProcess.broker"

#define PROBE_SHM_NAME "/linuxprobe-probe"
#define PROBE_SHM_SIZE (64 * 1024)
#define PROBE_SHM_MAGIC 0x50524F42u

typedef struct {
    uint32_t magic;
    uint32_t length;
    uint64_t sequence;
    char json[PROBE_SHM_SIZE - 16];
} ProbeShmBlock;

#define PROBE_NOTIFY_PREFIX "com.daixz.linux.probe.chunk."
#define PROBE_NOTIFY_CHUNKS 64
#define PROBE_NOTIFY_BYTES (PROBE_NOTIFY_CHUNKS * 8)
#define PROBE_NOTIFY_DONE "com.daixz.linux.probe.chunks-done"
#define PROBE_NOTIFY_LEN "com.daixz.linux.probe.chunks-len"
