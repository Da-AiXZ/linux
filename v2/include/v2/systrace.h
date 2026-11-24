/*
 * v2/systrace.h -- the syscall trace, kept twice: a short ring for a crash
 * report, and an optional full log for comparing two runs.
 *
 * V2_TRACE_SIZE lives here rather than in cpu.h because it describes the
 * recording, not the register file.
 */
#ifndef V2_SYSTRACE_H
#define V2_SYSTRACE_H

#include <stddef.h>
#include <stdint.h>

#define V2_TRACE_SIZE 32

/* Called once per dispatched syscall.  `name` may be NULL. */
void v2_trace_record(uint64_t site, uint64_t number, const char *name,
                     long long result, const uint64_t args[6]);

/* One fingerprint line per syscall boundary, into the same log. */
void v2_trace_boundary(unsigned long index, uint64_t registers,
                       uint64_t memory, size_t pages);

/* Push the full log out, so a run that dies by signal still leaves one. */
void v2_trace_flush(void);

/* Print the last V2_TRACE_SIZE syscalls to stderr (fault reports). */
void v2_trace_dump(void);

#endif
