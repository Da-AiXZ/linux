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

/*
 * The name must be prefixed with an app group both processes are entitled
 * to, otherwise bootstrap_check_in fails with BOOTSTRAP_NOT_PRIVILEGED
 * (1100). This mirrors Nyxian's <group>.liveprocess.broker convention.
 */
#define PROBE_MACH_GROUP "group.com.daixz.linux.probe"
#define PROBE_MACH_SERVICE_SUFFIX ".liveprocess.broker"
#define PROBE_MACH_SERVICE PROBE_MACH_GROUP PROBE_MACH_SERVICE_SUFFIX

typedef struct {
    mach_msg_header_t header;
    uint32_t magic;
    uint32_t length;
    char payload[PROBE_MACH_PAYLOAD_MAX];
} ProbeMachMessage;

static inline void ProbeMachServiceNameForGroup(char *buffer,
                                                 size_t size,
                                                 const char *group)
{
    snprintf(buffer, size, "%s" PROBE_MACH_SERVICE_SUFFIX, group);
}
