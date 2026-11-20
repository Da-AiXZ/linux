#pragma once

#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/types.h>

/*
 * Framing for the host <-> extension Mach channel. This is deliberately a
 * raw mach_msg with an inline JSON body: no XPC objects, no bootstrap name
 * lookup on the extension side beyond the service itself.
 */

#define PROBE_MACH_MAGIC 0x50524231u  /* 'PRB1' */
#define PROBE_MACH_PAYLOAD_MAX 4096
#define PROBE_MACH_SERVICE_PREFIX "com.daixz.linux.probe.LiveProcess"

typedef struct {
    mach_msg_header_t header;
    uint32_t magic;
    uint32_t length;
    char payload[PROBE_MACH_PAYLOAD_MAX];
} ProbeMachMessage;

static inline void ProbeMachServiceName(char *buffer,
                                        size_t size,
                                        pid_t hostPid)
{
    snprintf(buffer, size, PROBE_MACH_SERVICE_PREFIX "-%d", hostPid);
}
