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
 * The host registers this name after TrollStore unsandboxes the app
 * (com.apple.private.security.no-sandbox), which lifts the bootstrap
 * restriction that returned BOOTSTRAP_NOT_PRIVILEGED (1100).
 */
#define PROBE_MACH_SERVICE "com.daixz.linux.probe.LiveProcess.broker"

typedef struct {
    mach_msg_header_t header;
    uint32_t magic;
    uint32_t length;
    char payload[PROBE_MACH_PAYLOAD_MAX];
} ProbeMachMessage;
