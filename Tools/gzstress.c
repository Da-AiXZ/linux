/*
 * gzstress -- reproduce the apk inflate failure inside the guest, cheaply.
 *
 * Every experiment so far cost a build, a manual install and one run, so a
 * 30% failure rate needed ten of those to say anything.  This program runs the
 * same decode (the cached APKINDEX gzip members, byte for byte) in a loop, on
 * the same musl and the same zlib, and prints one line per iteration.  Two
 * hundred samples now arrive in a single app run, with no network, no apk and
 * no watchpoint -- i.e. nothing that can disturb what is being measured.
 *
 * Two things are checked per iteration:
 *
 *   1. inflate must reach Z_STREAM_END.  zlib verifies the gzip CRC32 and
 *      ISIZE from the trailer itself, so this is exactly the check apk fails
 *      on ("incorrect data check").
 *
 *   2. if --churn is given, the program grows and shrinks small arrays while
 *      it inflates, the way apk does while it walks the tar stream.  Every
 *      block it holds is compared against the live [strm.state, +0x2000)
 *      range; any overlap is printed as "GZ OVERLAP" with both ranges.  That
 *      is the condition the watchpoint caught on the device (an apk array
 *      header eight bytes inside a live inflate_state), and this build either
 *      reproduces it on demand or proves it needs apk.
 *
 * Built static for aarch64-linux-musl with zlib's own sources, so there is no
 * dynamic loader in the picture either.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "zlib.h"

#define OUT_CHUNK (128 * 1024)
#define IN_CHUNK  (64 * 1024)
#define CHURN_SLOTS 48
#define STATE_SPAN 0x2000

static unsigned char *gInput;
static size_t gInputLength;
static unsigned char *gOutput;

static unsigned char *gChurn[CHURN_SLOTS];
static size_t gChurnLength[CHURN_SLOTS];

static unsigned long gOverlap;

static int ReadWholeFile(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("GZSTRESS open failed path=%s\n", path);
        return -1;
    }
    /* The index is ~2MB; read in 1MB steps and grow. */
    size_t capacity = 1u << 21;
    size_t used = 0;
    unsigned char *buffer = malloc(capacity);
    if (buffer == NULL) {
        close(fd);
        return -1;
    }
    for (;;) {
        if (used + (1u << 20) > capacity) {
            size_t bigger = capacity * 2;
            unsigned char *moved = realloc(buffer, bigger);
            if (moved == NULL) {
                free(buffer);
                close(fd);
                return -1;
            }
            buffer = moved;
            capacity = bigger;
        }
        ssize_t got = read(fd, buffer + used, 1u << 20);
        if (got < 0) {
            free(buffer);
            close(fd);
            return -1;
        }
        if (got == 0) {
            break;
        }
        used += (size_t)got;
    }
    close(fd);
    gInput = buffer;
    gInputLength = used;
    return 0;
}

static void OverlapCheck(const char *tag, int slot, uintptr_t state)
{
    uintptr_t start = (uintptr_t)gChurn[slot];
    uintptr_t end = start + gChurnLength[slot];
    if (start == 0 || gChurnLength[slot] == 0) {
        return;
    }
    if (start < state + STATE_SPAN && state < end) {
        gOverlap++;
        printf("GZ OVERLAP %s slot=%d block=0x%lx..0x%lx state=0x%lx..0x%lx\n",
               tag, slot,
               (unsigned long)start, (unsigned long)end,
               (unsigned long)state, (unsigned long)(state + STATE_SPAN));
    }
    for (int other = 0; other < CHURN_SLOTS; other++) {
        if (other == slot || gChurn[other] == NULL || gChurnLength[other] == 0) {
            continue;
        }
        uintptr_t otherStart = (uintptr_t)gChurn[other];
        uintptr_t otherEnd = otherStart + gChurnLength[other];
        if (start < otherEnd && otherStart < end) {
            gOverlap++;
            printf("GZ OVERLAP %s slot=%d 0x%lx..0x%lx vs slot=%d 0x%lx..0x%lx\n",
                   tag, slot,
                   (unsigned long)start, (unsigned long)end,
                   other,
                   (unsigned long)otherStart, (unsigned long)otherEnd);
        }
    }
}

/*
 * apk_array_resize: grow by one element, zero the new tail.  The size pattern
 * matters (24-byte elements, one at a time), so keep it literal.
 */
static void ChurnGrow(int slot, uintptr_t state)
{
    size_t elements = gChurnLength[slot] ? gChurnLength[slot] / 8 : 0;
    size_t want = (elements + 3) * 8 + 8;
    unsigned char *moved = realloc(gChurn[slot], want);
    if (moved == NULL) {
        return;
    }
    memset(moved, 0, want);
    gChurn[slot] = moved;
    gChurnLength[slot] = want;
    OverlapCheck("grow", slot, state);
}

static void ChurnReset(void)
{
    for (int index = 0; index < CHURN_SLOTS; index++) {
        free(gChurn[index]);
        gChurn[index] = NULL;
        gChurnLength[index] = 0;
    }
}

static int InflateOne(const unsigned char *data, size_t length, uintptr_t *stateOut,
                      size_t *outLengthOut, size_t *consumedOut, int verbose)
{
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    int result = inflateInit2(&stream, 47);
    if (result != Z_OK) {
        printf("GZ FAIL inflateInit2 ret=%d\n", result);
        return -1;
    }
    *stateOut = (uintptr_t)stream.state;

    size_t inUsed = 0;
    size_t outUsed = 0;
    int last = 0;
    int calls = 0;

    while (!last) {
        if (stream.avail_in == 0) {
            size_t remain = length - inUsed;
            if (remain == 0) {
                break;
            }
            size_t take = remain < IN_CHUNK ? remain : IN_CHUNK;
            stream.next_in = (Bytef *)(uintptr_t)(data + inUsed);
            stream.avail_in = (uInt)take;
            inUsed += take;
        }
        stream.next_out = gOutput + outUsed;
        stream.avail_out = OUT_CHUNK;
        calls++;

        if (gChurn[0] != NULL) {
            ChurnGrow(calls % 8, *stateOut);
        }

        result = inflate(&stream, Z_NO_FLUSH);
        outUsed += OUT_CHUNK - stream.avail_out;

        if (result == Z_STREAM_END) {
            last = 1;
        } else if (result == Z_OK) {
            if (stream.avail_in == 0 && inUsed == length && stream.avail_out != 0) {
                /* Out of input inside the stream: truncated file. */
                break;
            }
        } else {
            unsigned leftover = (unsigned)stream.avail_in;
            printf("GZ FAIL ret=%d total_in=%lu total_out=%lu calls=%d avail_in=%u"
                   " msg=%s\n",
                   result,
                   (unsigned long)stream.total_in,
                   (unsigned long)stream.total_out,
                   calls,
                   leftover,
                   stream.msg ? stream.msg : "(none)");
            *outLengthOut = outUsed;
            *consumedOut = inUsed - leftover;
            inflateEnd(&stream);
            return result;
        }
    }

    unsigned leftover = (unsigned)stream.avail_in;
    *outLengthOut = outUsed;
    *consumedOut = inUsed - leftover;
    if (verbose) {
        printf("GZ member in=%lu out=%lu calls=%d\n",
               (unsigned long)(*consumedOut),
               (unsigned long)outUsed,
               calls);
    }
    inflateEnd(&stream);
    return result == Z_STREAM_END ? 0 : result;
}

static int StressFile(const char *path, int iterations, int churn)
{
    if (ReadWholeFile(path) != 0) {
        return iterations;
    }
    printf("GZSTRESS file=%s bytes=%lu iterations=%d churn=%d\n",
           path, (unsigned long)gInputLength, iterations, churn);

    int failed = 0;
    size_t firstTotal = 0;
    int members = 0;

    for (int round = 1; round <= iterations; round++) {
        if (churn) {
            ChurnReset();
            for (int slot = 0; slot < 8; slot++) {
                gChurn[slot] = malloc(32 + (size_t)slot * 16);
                gChurnLength[slot] = 32 + (size_t)slot * 16;
                if (gChurn[slot] == NULL) {
                    gChurnLength[slot] = 0;
                }
            }
        }

        size_t offset = 0;
        size_t total = 0;
        int roundFail = 0;
        int roundMembers = 0;
        uintptr_t lastState = 0;

        while (offset < gInputLength) {
            uintptr_t state = 0;
            size_t produced = 0;
            size_t used = 0;
            int result = InflateOne(gInput + offset, gInputLength - offset,
                                    &state, &produced, &used, round == 1);
            lastState = state;
            if (result != 0) {
                roundFail = 1;
                break;
            }
            roundMembers++;
            total += produced;
            if (used == 0) {
                break;
            }
            offset += used;
        }

        if (!roundFail && total == 0) {
            roundFail = 1;
        }
        if (round == 1) {
            firstTotal = total;
            members = roundMembers;
        } else if (total != firstTotal) {
            roundFail = 1;
        }

        if (roundFail) {
            failed++;
            printf("GZ %d/%d FAIL total=%lu members=%d state=0x%lx\n",
                   round, iterations, (unsigned long)total, roundMembers,
                   (unsigned long)lastState);
        } else if (round <= 3 || round % 25 == 0) {
            printf("GZ %d/%d PASS total=%lu members=%d state=0x%lx\n",
                   round, iterations, (unsigned long)total, roundMembers,
                   (unsigned long)lastState);
        }

        if (churn) {
            ChurnReset();
        }
    }

    printf("GZSTRESS DONE total=%d failed=%d members=%d bytes=%lu overlap=%lu\n",
           iterations, failed, members, (unsigned long)firstTotal, gOverlap);
    return failed;
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "/var/localrepo/main";
    int iterations = argc > 2 ? atoi(argv[2]) : 200;
    int churn = 0;
    if (iterations < 1) {
        iterations = 1;
    }
    if (iterations > 2000) {
        iterations = 2000;
    }
    for (int index = 3; index < argc; index++) {
        if (strcmp(argv[index], "--churn") == 0) {
            churn = 1;
        }
    }

    const char *paths[2];
    int pathCount = 1;
    paths[0] = path;
    if (strcmp(path, "both") == 0) {
        paths[0] = "/var/localrepo/main";
        paths[1] = "/var/localrepo/community";
        pathCount = 2;
    }

    gOutput = malloc(OUT_CHUNK);
    if (gOutput == NULL) {
        return 2;
    }

    int totalFailed = 0;
    for (int which = 0; which < pathCount; which++) {
        totalFailed += StressFile(paths[which], iterations, churn);
    }
    return totalFailed == 0 ? 0 : 1;
}
