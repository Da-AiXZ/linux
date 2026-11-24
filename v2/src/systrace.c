/*
 * v2/systrace.c -- what the guest asked the host for, recorded two ways.
 *
 * The ring holds the last thirty-two calls and exists because the interesting
 * failure is almost always "the guest took a wild branch somewhere after call
 * N": a fault handler prints it and a bare SIGSEGV becomes a story.
 *
 * The full log exists for the opposite question -- not "what was it doing when
 * it died" but "where did this run start to differ from that one".  Every input
 * this guest sees is deterministic (the image is a file, getrandom is a
 * fixed-seed generator, the address space is built from a fixed base, and
 * V2_TIME_FREEZE pins the clock), so two runs given the same inputs must produce
 * the same sequence of calls, and the first line that differs is the answer.
 *
 * The log is opt-in through V2_SYSCALL_LOG and is never written by default.
 */
#include <stdio.h>
#include <stdlib.h>

#include "v2/cpu.h"
#include "v2/systrace.h"

struct v2_trace_entry {
    uint64_t site;
    uint64_t number;
    long long result;
    uint64_t arg0;
    uint64_t arg1;
};

static struct v2_trace_entry ring[V2_TRACE_SIZE];
static unsigned ring_count;

/* A runaway guest could otherwise fill the disk before anyone reads the log. */
#define V2_TRACE_LINES_MAX 300000

static FILE *log_file;
static long log_lines;
static int log_opened;

static void log_close(void)
{
    if (log_file != NULL) {
        fflush(log_file);
        fclose(log_file);
        log_file = NULL;
    }
}

static void log_open(void)
{
    static char buffer[1 << 20];
    const char *path = getenv("V2_SYSCALL_LOG");

    log_opened = 1;
    if (path == NULL || path[0] == '\0') {
        return;
    }
    log_file = fopen(path, "w");
    if (log_file == NULL) {
        fprintf(stderr, "[v2] cannot write a syscall log to %s\n", path);
        return;
    }
    setvbuf(log_file, buffer, _IOFBF, sizeof(buffer));
    atexit(log_close);
}

void v2_trace_record(uint64_t site, uint64_t number, const char *name,
                     long long result, const uint64_t args[6])
{
    unsigned slot = ring_count % V2_TRACE_SIZE;

    ring[slot].site = site;
    ring[slot].number = number;
    ring[slot].result = result;
    ring[slot].arg0 = args[0];
    ring[slot].arg1 = args[1];
    ring_count++;

    if (!log_opened) {
        log_open();
    }
    if (log_file == NULL || log_lines >= V2_TRACE_LINES_MAX) {
        return;
    }
    fprintf(log_file,
            "%ld %s(0x%llx 0x%llx 0x%llx 0x%llx 0x%llx 0x%llx) "
            "site=0x%llx -> %lld\n",
            log_lines, name != NULL ? name : "unknown",
            (unsigned long long)args[0], (unsigned long long)args[1],
            (unsigned long long)args[2], (unsigned long long)args[3],
            (unsigned long long)args[4], (unsigned long long)args[5],
            (unsigned long long)site, result);
    log_lines++;
}

void v2_trace_flush(void)
{
    if (log_file != NULL) {
        fflush(log_file);
    }
}

void v2_trace_dump(void)
{
    unsigned total = ring_count < V2_TRACE_SIZE ? ring_count : V2_TRACE_SIZE;

    v2_trace_flush();
    fprintf(stderr, "[v2] last %u syscall(s):\n", total);
    for (unsigned index = 0; index < total; index++) {
        unsigned slot = (ring_count - total + index) % V2_TRACE_SIZE;

        /*
         * Arguments only where they carry meaning: an mmap without its
         * address or an unlinkat without its path is not evidence.
         */
        switch (ring[slot].number) {
        case 215:  /* munmap */
        case 222:  /* mmap   */
            fprintf(stderr, "  site=0x%llx nr=%llu(0x%llx, 0x%llx) -> 0x%llx\n",
                    (unsigned long long)ring[slot].site,
                    (unsigned long long)ring[slot].number,
                    (unsigned long long)ring[slot].arg0,
                    (unsigned long long)ring[slot].arg1,
                    (unsigned long long)ring[slot].result);
            break;
        default:
            fprintf(stderr, "  site=0x%llx nr=%llu -> %lld\n",
                    (unsigned long long)ring[slot].site,
                    (unsigned long long)ring[slot].number,
                    ring[slot].result);
            break;
        }
    }
}
