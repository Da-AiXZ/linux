#ifndef PROBE_PROTOCOL_H
#define PROBE_PROTOCOL_H

#include <mach/mach.h>
#include <stdint.h>
#include <stddef.h>

#define PROBE_MSG_PING   1
#define PROBE_MSG_RESULT 2
#define PROBE_MSG_DONE   3

#define PROBE_PAYLOAD_MAX 2048

typedef struct {
    mach_msg_header_t header;
    uint32_t kind;
    uint32_t length;
    char payload[PROBE_PAYLOAD_MAX];
} ProbeMessage;

typedef struct {
    mach_msg_header_t header;
    int64_t result;
    uint32_t kind;
    uint32_t length;
    char payload[PROBE_PAYLOAD_MAX];
} ProbeReply;

#endif /* PROBE_PROTOCOL_H */
