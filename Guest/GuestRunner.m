#import <Foundation/Foundation.h>

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <mach/thread_act.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <signal.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/ucontext.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/utsname.h>
#import <time.h>
#import <unistd.h>

/*
 * A minimal native Linux/arm64 user-space runtime.
 *
 * The guest is arm64 code, so there is no translation: we map its ELF
 * segments, replace every `svc #0` with a `bl` into our syscall
 * trampoline and jump to the entry point. JIT is enabled with the same
 * self-ptrace trick UTM uses (CS_DEBUGGED), which works on iOS 15+
 * because TrollStore runs us unsandboxed.
 */

extern int ptrace(int request, pid_t pid, caddr_t addr, int data);
extern void sys_icache_invalidate(void *start, size_t length);
extern int csops(pid_t pid, unsigned int operation, void *buffer, size_t size);

#define GUEST_PT_TRACE_ME 0

#define GUEST_CS_OPS_STATUS 0
#define GUEST_CS_DEBUGGED 0x10000000

#define GUEST_ARM_THREAD_STATE64 6
#define GUEST_ARM_THREAD_STATE64_COUNT (68)

typedef struct {
    uint64_t x[29];
    uint64_t fp;
    uint64_t lr;
    uint64_t sp;
    uint64_t pc;
    uint32_t cpsr;
    uint32_t padding;
} GuestThreadState64;

#define ELF_ET_DYN 3
#define ELF_EM_AARCH64 183
#define ELF_PT_LOAD 1
#define ELF_PF_X 1
#define ELF_PF_W 2
#define ELF_PF_R 4

typedef struct {
    unsigned char e_ident[16];
    uint16_t e_type;
    uint16_t e_machine;
    uint32_t e_version;
    uint64_t e_entry;
    uint64_t e_phoff;
    uint64_t e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize;
    uint16_t e_phentsize;
    uint16_t e_phnum;
    uint16_t e_shentsize;
    uint16_t e_shnum;
    uint16_t e_shstrndx;
} GuestElfHeader;

typedef struct {
    uint32_t p_type;
    uint32_t p_flags;
    uint64_t p_offset;
    uint64_t p_vaddr;
    uint64_t p_paddr;
    uint64_t p_filesz;
    uint64_t p_memsz;
    uint64_t p_align;
} GuestElfProgramHeader;

static uintptr_t GuestHeapBase = 0;
static uintptr_t GuestHeapEnd = 0;
static uintptr_t GuestBrkCurrent = 0;
static uint64_t GuestStackTop = 0;
static uintptr_t GuestImageBase = 0;
static uint64_t GuestImageSize = 0;
static const char *GuestElfPath = NULL;
static uint64_t GuestTlsPointer = 0;

#pragma mark - JIT and fault reporting

static void GuestWriteAll(int descriptor, const char *text, size_t length)
{
    while (length > 0) {
        ssize_t written = write(descriptor, text, length);
        if (written <= 0) {
            return;
        }
        text += written;
        length -= (size_t)written;
    }
}

static void GuestSignalHandler(int signalNumber,
                               siginfo_t *information,
                               void *context)
{
    ucontext_t *state = (ucontext_t *)context;
    uint64_t pc = 0;
    uint64_t lr = 0;
    uint64_t sp = 0;
    uint64_t far = 0;
    uint32_t esr = 0;
    if (state != NULL) {
        pc = (uint64_t)state->uc_mcontext->__ss.__pc;
        lr = (uint64_t)state->uc_mcontext->__ss.__lr;
        sp = (uint64_t)state->uc_mcontext->__ss.__sp;
        far = (uint64_t)state->uc_mcontext->__es.__far;
        esr = (uint32_t)state->uc_mcontext->__es.__esr;
    }

    char text[384];
    uint64_t address = information != NULL
        ? (uint64_t)(uintptr_t)information->si_addr
        : 0;
    int length = snprintf(text,
                          sizeof(text),
                          "[guest] signal %d addr=0x%llx pc=0x%llx lr=0x%llx "
                          "sp=0x%llx far=0x%llx esr=0x%x base=0x%lx\n",
                          signalNumber,
                          (unsigned long long)address,
                          (unsigned long long)pc,
                          (unsigned long long)lr,
                          (unsigned long long)sp,
                          (unsigned long long)far,
                          (unsigned)esr,
                          (unsigned long)GuestImageBase);
    if (length > 0) {
        GuestWriteAll(STDOUT_FILENO, text, (size_t)length);
    }
    if (GuestImageBase != 0 && pc >= GuestImageBase &&
        pc < GuestImageBase + GuestImageSize) {
        length = snprintf(text,
                          sizeof(text),
                          "[guest] fault offset=0x%llx\n",
                          (unsigned long long)(pc - GuestImageBase));
        if (length > 0) {
            GuestWriteAll(STDOUT_FILENO, text, (size_t)length);
        }
    }
    _exit(70);
}

static void GuestInstallFaultHandlers(void)
{
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = GuestSignalHandler;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);

    const int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE };
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]);
         index++) {
        sigaction(signals[index], &action, NULL);
    }
}

static void GuestLogCodeSignState(const char *tag)
{
    uint32_t flags = 0;
    int result = csops(getpid(), GUEST_CS_OPS_STATUS, &flags, sizeof(flags));
    fprintf(stdout, "[guest] %s: csops=%d flags=0x%08x debugged=%d\n",
            tag,
            result,
            flags,
            (flags & GUEST_CS_DEBUGGED) ? 1 : 0);
}

static uint32_t GuestJITSelfTest(void)
{
    uint32_t *page = mmap(NULL,
                          0x4000,
                          PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANON,
                          -1,
                          0);
    if (page == MAP_FAILED) {
        fprintf(stderr, "[guest] selftest mmap failed: %s\n", strerror(errno));
        return 0;
    }

    page[0] = 0x52800540; /* mov w0, #42 */
    page[1] = 0xD65F03C0; /* ret */
    sys_icache_invalidate(page, 8);

    if (mprotect(page, 0x4000, PROT_READ | PROT_EXEC) != 0) {
        fprintf(stderr, "[guest] selftest mprotect failed: %s\n",
                strerror(errno));
        return 0;
    }
    sys_icache_invalidate(page, 8);

    uint32_t (*function)(void) = (uint32_t (*)(void))page;
    uint32_t value = function();
    munmap(page, 0x4000);
    return value;
}

static void GuestProbeTpidr(void)
{
    uint64_t original = 0;
    uint64_t written = 0;
    uint64_t afterSyscall = 0;
    const uint64_t sentinel = 0x123456789ABCDEF0ULL;

    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(original));
    __asm__ volatile("msr tpidr_el0, %0" :: "r"(sentinel));
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(written));
    getpid();
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(afterSyscall));
    __asm__ volatile("msr tpidr_el0, %0" :: "r"(original));

    fprintf(stdout,
            "[guest] tpidr probe: original=0x%llx write=0x%llx after_svc=0x%llx\n",
            (unsigned long long)original,
            (unsigned long long)written,
            (unsigned long long)afterSyscall);
    fflush(stdout);
}

static BOOL GuestEnableJIT(void)
{
    if (ptrace(GUEST_PT_TRACE_ME, 0, NULL, 0) < 0) {
        fprintf(stderr, "[guest] ptrace(PT_TRACE_ME) failed: %s\n",
                strerror(errno));
        return NO;
    }

    /*
     * PT_TRACE_ME alone grants CS_DEBUGGED, which is all JIT needs. We
     * deliberately do not use PT_SIGEXC: on iOS 16 it swallows guest
     * faults into a Mach exception port that never delivers, killing the
     * process with status 1 and no diagnostics. Plain POSIX signal
     * handlers do fire and report pc/far.
     */
    GuestInstallFaultHandlers();
    return YES;
}

#pragma mark - Syscall trampoline

uint64_t GuestSyscallDispatch(uint64_t *args,
                              uint64_t number,
                              uint64_t returnAddress)
    __attribute__((used));

__attribute__((naked, noinline, used))
static void GuestSyscallTrampoline(void)
{
    /*
     * Linux preserves every register except x0 across a syscall, and
     * glibc relies on that (e.g. __sbrk issues two brk svcs and only
     * sets x8 once). It also preserves TPIDR_EL0 and NZCV, which the
     * Darwin host runtime may otherwise change under us.
     */
    __asm__ volatile(
        "stp x29, x30, [sp, #-16]!\n"
        "stp x16, x17, [sp, #-16]!\n"
        "stp x14, x15, [sp, #-16]!\n"
        "stp x12, x13, [sp, #-16]!\n"
        "stp x10, x11, [sp, #-16]!\n"
        "stp x8, x9, [sp, #-16]!\n"
        "stp x6, x7, [sp, #-16]!\n"
        "stp x4, x5, [sp, #-16]!\n"
        "stp x2, x3, [sp, #-16]!\n"
        "stp x0, x1, [sp, #-16]!\n"
        "sub sp, sp, #16\n"
        "mrs x9, tpidr_el0\n"
        "mrs x10, nzcv\n"
        "stp x9, x10, [sp]\n"
        "add x0, sp, #16\n"
        "mov x1, x8\n"
        "mov x2, x30\n"
        "bl _GuestSyscallDispatch\n"
        "ldp x9, x10, [sp]\n"
        "msr tpidr_el0, x9\n"
        "msr nzcv, x10\n"
        "add sp, sp, #16\n"
        "ldp x9, x1, [sp], #16\n"
        "ldp x2, x3, [sp], #16\n"
        "ldp x4, x5, [sp], #16\n"
        "ldp x6, x7, [sp], #16\n"
        "ldp x8, x9, [sp], #16\n"
        "ldp x10, x11, [sp], #16\n"
        "ldp x12, x13, [sp], #16\n"
        "ldp x14, x15, [sp], #16\n"
        "ldp x16, x17, [sp], #16\n"
        "ldp x29, x30, [sp], #16\n"
        "ret\n");
}

static uint64_t GuestErrno(void)
{
    return (uint64_t)(-(int64_t)errno);
}

#pragma mark - Syscalls

uint64_t GuestSyscallDispatch(uint64_t *args,
                              uint64_t number,
                              uint64_t returnAddress)
{
    static unsigned int traceCount = 0;
    if (traceCount < 40) {
        traceCount++;
        fprintf(stdout,
                "[guest] svc %llu site=0x%llx x0=0x%llx x1=0x%llx "
                "x2=0x%llx x3=0x%llx tls=0x%llx\n",
                (unsigned long long)number,
                (unsigned long long)(returnAddress - 4),
                (unsigned long long)args[0],
                (unsigned long long)args[1],
                (unsigned long long)args[2],
                (unsigned long long)args[3],
                (unsigned long long)GuestTlsPointer);
    }

    if (number > 500) {
        const uint32_t *site = (const uint32_t *)(uintptr_t)(returnAddress - 4);
        fprintf(stdout, "[guest] site code:");
        for (int index = -3; index <= 1; index++) {
            fprintf(stdout, " %08x", site[index]);
        }
        fprintf(stdout, "\n");
    }

    switch (number) {
    case 64: { /* write */
        ssize_t result = write((int)args[0],
                               (const void *)args[1],
                               (size_t)args[2]);
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 63: { /* read */
        ssize_t result = read((int)args[0],
                              (void *)args[1],
                              (size_t)args[2]);
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 62: { /* lseek */
        off_t result = lseek((int)args[0], (off_t)args[1], (int)args[2]);
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 57: /* close */
        return close((int)args[0]) == 0 ? 0 : GuestErrno();
    case 93: /* exit */
    case 94: /* exit_group */
        fprintf(stdout,
                "[guest] exit syscall %llu code=%lld\n",
                (unsigned long long)number,
                (long long)args[0]);
        fflush(stdout);
        _exit((int)args[0]);
    case 172: /* getpid */
        return (uint64_t)getpid();
    case 173: /* getppid */
        return (uint64_t)getppid();
    case 174:
        return (uint64_t)getuid();
    case 175:
        return (uint64_t)geteuid();
    case 176:
        return (uint64_t)getgid();
    case 177:
        return (uint64_t)getegid();
    case 160: { /* uname */
        char *output = (char *)args[0];
        if (output == NULL) {
            return (uint64_t)(-EFAULT);
        }
        memset(output, 0, 65 * 6);
        snprintf(output + 0, 65, "Linux");
        snprintf(output + 65, 65, "linuxprobe");
        snprintf(output + 130, 65, "6.6.0");
        snprintf(output + 195, 65, "#1");
        snprintf(output + 260, 65, "aarch64");
        snprintf(output + 325, 65, "(none)");
        return 0;
    }
    case 113: { /* clock_gettime */
        struct timespec value;
        clockid_t clock = args[0] == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC;
        if (clock_gettime(clock, &value) != 0) {
            return GuestErrno();
        }
        uint64_t *output = (uint64_t *)args[1];
        if (output == NULL) {
            return (uint64_t)(-EFAULT);
        }
        output[0] = (uint64_t)value.tv_sec;
        output[1] = (uint64_t)value.tv_nsec;
        return 0;
    }
    case 96: /* set_tid_address */
        return (uint64_t)getpid();
    case 99: /* set_robust_list */
    case 135: /* rt_sigprocmask */
        return 0;
    case 293: /* rseq */
        return (uint64_t)(-ENOSYS);
    case 29: /* ioctl */
        return (uint64_t)(-ENOTTY);
    case 169: { /* gettimeofday */
        struct timeval value;
        if (gettimeofday(&value, NULL) != 0) {
            return GuestErrno();
        }
        if (args[0] != 0) {
            uint64_t *output = (uint64_t *)args[0];
            output[0] = (uint64_t)value.tv_sec;
            output[1] = (uint64_t)value.tv_usec;
        }
        if (args[1] != 0) {
            uint64_t *zone = (uint64_t *)args[1];
            zone[0] = 0;
            zone[1] = 0;
        }
        return 0;
    }
    case 261: { /* prlimit64 */
        uint64_t *output = (uint64_t *)args[3];
        if (output != NULL) {
            output[0] = ~0ULL;
            output[1] = ~0ULL;
        }
        return 0;
    }
    case 278: { /* getrandom */
        size_t length = (size_t)args[1];
        arc4random_buf((void *)args[0], length);
        return (uint64_t)length;
    }
    case 17: { /* getcwd */
        char *output = (char *)args[0];
        if (getcwd(output, (size_t)args[1]) == NULL) {
            return GuestErrno();
        }
        return (uint64_t)strlen(output) + 1;
    }
    case 78: { /* readlinkat */
        const char *path = (const char *)args[1];
        char *output = (char *)args[2];
        size_t size = (size_t)args[3];
        if (path == NULL || output == NULL) {
            return (uint64_t)(-EFAULT);
        }
        if (strcmp(path, "/proc/self/exe") != 0 || GuestElfPath == NULL) {
            return (uint64_t)(-ENOENT);
        }
        /* glibc's _dl_get_origin() asks for the running executable. */
        size_t length = strlen(GuestElfPath);
        if (length > size) {
            length = size;
        }
        memcpy(output, GuestElfPath, length);
        return (uint64_t)length;
    }
    case 214: { /* brk */
        if (args[0] == 0) {
            return GuestBrkCurrent;
        }
        if (args[0] >= GuestHeapBase && args[0] <= GuestHeapEnd) {
            uintptr_t requested = (uintptr_t)args[0];
            if (requested > GuestBrkCurrent) {
                /* Linux gives fresh zero pages when the break grows. */
                memset((void *)GuestBrkCurrent,
                       0,
                       requested - GuestBrkCurrent);
            }
            GuestBrkCurrent = requested;
            return GuestBrkCurrent;
        }
        return GuestBrkCurrent;
    }
    case 222: { /* mmap */
        static unsigned int mmapTrace = 0;
        uint64_t guestFlags = args[3];
        int flags = 0;
        if (guestFlags & 0x01) flags |= MAP_SHARED;      /* Linux MAP_SHARED */
        if (guestFlags & 0x02) flags |= MAP_PRIVATE;     /* Linux MAP_PRIVATE */
        if (guestFlags & 0x10) flags |= MAP_FIXED;       /* same on both */
        if (guestFlags & 0x20) flags |= MAP_ANON;        /* Linux MAP_ANONYMOUS */
        if (guestFlags & 0x4000) flags |= MAP_NORESERVE; /* Linux MAP_NORESERVE */

        void *result = mmap((void *)args[0],
                            (size_t)args[1],
                            (int)args[2],
                            flags,
                            (guestFlags & 0x20) ? -1 : (int)args[4],
                            (off_t)args[5]);
        int error = errno;
        if (mmapTrace < 8) {
            mmapTrace++;
            fprintf(stdout,
                    "[guest] mmap addr=0x%llx len=0x%llx prot=0x%llx "
                    "flags=0x%llx->0x%x fd=%d result=%p errno=%d\n",
                    (unsigned long long)args[0],
                    (unsigned long long)args[1],
                    (unsigned long long)args[2],
                    (unsigned long long)guestFlags,
                    flags,
                    (int)args[4],
                    result,
                    result == MAP_FAILED ? error : 0);
            fflush(stdout);
        }
        return result == MAP_FAILED ? GuestErrno() : (uint64_t)result;
    }
    case 215: { /* munmap */
        return munmap((void *)args[0], (size_t)args[1]) == 0
            ? 0
            : GuestErrno();
    }
    case 226: { /* mprotect */
        return mprotect((void *)args[0],
                        (size_t)args[1],
                        (int)args[2]) == 0 ? 0 : GuestErrno();
    }
    case 233: { /* madvise */
        int advice = (int)args[2];
        if (advice == 4 || advice == 8) { /* MADV_DONTNEED / MADV_FREE */
            /* Linux zero-fills anonymous pages on next touch. */
            uintptr_t start = (uintptr_t)args[0];
            size_t length = (size_t)args[1];
            if (start >= GuestHeapBase && length != 0 &&
                start + length > start && start + length <= GuestHeapEnd) {
                memset((void *)start, 0, length);
            }
        }
        return 0;
    }
    default:
        fprintf(stderr, "[guest] unsupported syscall %llu\n",
                (unsigned long long)number);
        return (uint64_t)(-ENOSYS);
    }
}

#pragma mark - Loader

#ifndef VM_FLAGS_OVERWRITE
#define VM_FLAGS_OVERWRITE 0x4000
#endif

static BOOL GuestRangeFree(uintptr_t address, size_t size)
{
    vm_address_t target = (vm_address_t)address;
    kern_return_t result = vm_allocate(mach_task_self(),
                                       &target,
                                       (vm_size_t)size,
                                       VM_FLAGS_FIXED);

    if (result != KERN_SUCCESS && address < 0x100000000ULL) {
        /* iOS reserves the low 4GB with the Mach-O __PAGEZERO entry.
         * Overwrite that entry so a fixed-address guest can live here. */
        target = (vm_address_t)address;
        result = vm_allocate(mach_task_self(),
                             &target,
                             (vm_size_t)size,
                             VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE);
        if (result == KERN_SUCCESS) {
            fprintf(stdout,
                    "[guest] low range 0x%lx reclaimed (%llu bytes)\n",
                    (unsigned long)address,
                    (unsigned long long)size);
        }
    }

    if (result != KERN_SUCCESS) {
        return NO;
    }
    vm_deallocate(mach_task_self(), target, (vm_size_t)size);
    return target == (vm_address_t)address;
}

static uintptr_t GuestChooseBase(uint64_t imageSize, uintptr_t trampoline)
{
    const uintptr_t offsets[] = {
        0x04000000, 0x06000000, 0x02000000, 0x07000000,
    };

    for (size_t index = 0; index < sizeof(offsets) / sizeof(offsets[0]);
         index++) {
        uintptr_t candidate = (trampoline + offsets[index]) & ~0x3FFFULL;
        int64_t distance = (int64_t)candidate - (int64_t)trampoline;
        if (distance < 0 || distance > 0x07000000) {
            continue;
        }
        if (candidate + imageSize > trampoline + 0x07800000ULL) {
            continue;
        }
        if (GuestRangeFree(candidate, (size_t)imageSize)) {
            return candidate;
        }
    }

    return 0;
}

static void GuestJump(uint64_t entry, uint64_t stack)
{
    __asm__ volatile("mov sp, %0\n"
                     "br %1\n"
                     :: "r"(stack), "r"(entry) : "memory");
}

typedef struct {
    mach_port_t thread;
} GuestWatchdogContext;

static void GuestDumpMachThread(mach_port_t thread, const char *tag)
{
    GuestThreadState64 state;
    mach_msg_type_number_t count = GUEST_ARM_THREAD_STATE64_COUNT;
    kern_return_t result = thread_get_state(thread,
                                            GUEST_ARM_THREAD_STATE64,
                                            (thread_state_t)&state,
                                            &count);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "[guest] %s: thread_get_state=%d\n", tag, result);
        return;
    }

    fprintf(stdout,
            "[guest] %s: pc=0x%llx sp=0x%llx lr=0x%llx fp=0x%llx "
            "x0=0x%llx x1=0x%llx x8=0x%llx\n",
            tag,
            (unsigned long long)state.pc,
            (unsigned long long)state.sp,
            (unsigned long long)state.lr,
            (unsigned long long)state.fp,
            (unsigned long long)state.x[0],
            (unsigned long long)state.x[1],
            (unsigned long long)state.x[8]);
}

static void *GuestWatchdogThread(void *argument)
{
    GuestWatchdogContext *context = (GuestWatchdogContext *)argument;
    struct timespec delay = { 1, 0 };
    nanosleep(&delay, NULL);
    GuestDumpMachThread(context->thread, "watchdog1");
    delay.tv_sec = 2;
    delay.tv_nsec = 0;
    nanosleep(&delay, NULL);
    GuestDumpMachThread(context->thread, "watchdog2");
    fprintf(stdout, "[guest] watchdog: guest still running, aborting\n");
    fflush(stdout);
    _exit(4);
}

#define GUEST_AT_NULL 0
#define GUEST_AT_PHDR 3
#define GUEST_AT_PHENT 4
#define GUEST_AT_PHNUM 5
#define GUEST_AT_PAGESZ 6
#define GUEST_AT_BASE 7
#define GUEST_AT_FLAGS 8
#define GUEST_AT_ENTRY 9
#define GUEST_AT_UID 11
#define GUEST_AT_EUID 12
#define GUEST_AT_GID 13
#define GUEST_AT_EGID 14
#define GUEST_AT_HWCAP 16
#define GUEST_AT_CLKTCK 17
#define GUEST_AT_SECURE 23
#define GUEST_AT_RANDOM 25
#define GUEST_AT_EXECFN 31

static uint64_t GuestBuildStack(uint64_t stackTop,
                                int count,
                                char *items[],
                                uintptr_t imageStart,
                                const GuestElfHeader *header,
                                uint64_t entry)
{
    if (count > 64) {
        count = 64;
    }

    uint64_t cursor = stackTop & ~0xFULL;
    uint64_t pointers[64];
    for (int index = count - 1; index >= 0; index--) {
        size_t length = strlen(items[index]) + 1;
        cursor = (cursor - length) & ~0xFULL;
        memcpy((void *)cursor, items[index], length);
        pointers[index] = cursor;
    }

    cursor = (cursor - 16) & ~0xFULL;
    uint64_t randomAddress = cursor;
    arc4random_buf((void *)randomAddress, 16);

    uint64_t values[][2] = {
        { GUEST_AT_PHDR, (uint64_t)(imageStart + header->e_phoff) },
        { GUEST_AT_PHENT, (uint64_t)header->e_phentsize },
        { GUEST_AT_PHNUM, (uint64_t)header->e_phnum },
        { GUEST_AT_PAGESZ, 4096 },
        { GUEST_AT_BASE, 0 },
        { GUEST_AT_FLAGS, 0 },
        { GUEST_AT_ENTRY, entry },
        { GUEST_AT_UID, (uint64_t)getuid() },
        { GUEST_AT_EUID, (uint64_t)geteuid() },
        { GUEST_AT_GID, (uint64_t)getgid() },
        { GUEST_AT_EGID, (uint64_t)getegid() },
        { GUEST_AT_HWCAP, 0 },
        { GUEST_AT_CLKTCK, 100 },
        { GUEST_AT_SECURE, 0 },
        { GUEST_AT_RANDOM, randomAddress },
        { GUEST_AT_EXECFN, pointers[0] },
        { GUEST_AT_NULL, 0 },
    };
    size_t valueCount = sizeof(values) / sizeof(values[0]);

    size_t words = 1 + (size_t)count + 1 + 1 + valueCount * 2;
    cursor = (cursor - words * sizeof(uint64_t)) & ~0xFULL;

    uint64_t *table = (uint64_t *)cursor;
    *table++ = (uint64_t)count;
    for (int index = 0; index < count; index++) {
        *table++ = pointers[index];
    }
    *table++ = 0; /* argv terminator */
    *table++ = 0; /* envp terminator */
    for (size_t index = 0; index < valueCount; index++) {
        *table++ = values[index][0];
        *table++ = values[index][1];
    }

    return cursor;
}

#define GUEST_TLS_STUB_COUNT 29

static uintptr_t GuestTlsReadStubs[GUEST_TLS_STUB_COUNT];
static uintptr_t GuestTlsWriteStubs[GUEST_TLS_STUB_COUNT];

static uint32_t GuestEncodeAdrp(uint32_t rd, uintptr_t from, uintptr_t to)
{
    int64_t pages = ((int64_t)(to & ~0xFFFULL) -
                     (int64_t)(from & ~0xFFFULL)) >> 12;
    uint32_t immlo = (uint32_t)(pages & 0x3);
    uint32_t immhi = (uint32_t)((pages >> 2) & 0x7FFFF);
    return 0x90000000U | (immlo << 29) | (immhi << 5) | rd;
}

static uint32_t GuestEncodeStpPre(uint32_t rt, uint32_t rt2)
{
    return 0xA9800000U | (0x7EU << 15) | (rt2 << 10) | (31U << 5) | rt;
}

static uint32_t GuestEncodeLdpPost(uint32_t rt, uint32_t rt2)
{
    return 0xA8C00000U | (2U << 15) | (rt2 << 10) | (31U << 5) | rt;
}

void GuestTlsWriteLog(uint64_t value, uint64_t returnAddress)
{
    GuestTlsPointer = value;
    fprintf(stdout,
            "[guest] tls write value=0x%llx site=0x%llx\n",
            (unsigned long long)value,
            (unsigned long long)(returnAddress - 4));
    fflush(stdout);
}

/*
 * TPIDR_EL0 cannot be trusted here: XNU resets it to its own value (0x4)
 * on some kernel returns, so a guest TLS pointer written by glibc is gone
 * before the next TLS access.  Emulate it in a shadow variable instead:
 *
 *   mrs xN, tpidr_el0 -> bl readStub[N]  (xN = GuestTlsPointer)
 *   msr tpidr_el0, xN -> bl writeStub[N] (GuestTlsPointer = xN, logged)
 *
 * Stubs only touch x30 (saved on the stack) and xN.
 */
static void GuestEmitTlsReadStub(uint8_t *stub, uint32_t rt)
{
    uintptr_t shadow = (uintptr_t)&GuestTlsPointer;
    uint32_t pageOffset = (uint32_t)(shadow & 0xFFF);
    uint32_t *code = (uint32_t *)stub;

    code[0] = 0xF81F0FFEU; /* str x30, [sp, #-16]! */
    code[1] = GuestEncodeAdrp(30, (uintptr_t)stub, shadow);
    code[2] = 0xF9400000U |
              ((pageOffset / 8) << 10) |
              (30U << 5) |
              rt;
    code[3] = 0xF84107FEU; /* ldr x30, [sp], #16 */
    code[4] = 0xD65F03C0U; /* ret */
}

static void GuestEmitTlsWriteStub(uint8_t *stub, uint32_t rt)
{
    uint32_t *code = (uint32_t *)stub;
    size_t index = 0;

    code[index++] = 0xF81F0FFEU; /* str x30, [sp, #-16]! */
    for (uint32_t pair = 28; pair >= 2; pair -= 2) {
        code[index++] = GuestEncodeStpPre(pair, pair + 1);
    }
    code[index++] = 0xD53B4209U; /* mrs x9, nzcv */
    code[index++] = 0xF81F0FE9U; /* str x9, [sp, #-16]! */

    code[index++] = 0xAA1E03E1U; /* mov x1, x30 */
    code[index++] = 0xAA0003E0U | rt; /* mov x0, x<rt> */
    code[index++] = GuestEncodeAdrp(16, (uintptr_t)stub,
                                    (uintptr_t)&GuestTlsWriteLog);
    code[index++] = 0x91000210U |
                    (((uintptr_t)&GuestTlsWriteLog & 0xFFF) << 10);
    code[index++] = 0xD63F0200U; /* blr x16 */

    code[index++] = 0xF84107E9U; /* ldr x9, [sp], #16 */
    code[index++] = 0xD51B4209U; /* msr nzcv, x9 */
    for (uint32_t pair = 0; pair <= 26; pair += 2) {
        code[index++] = GuestEncodeLdpPost(pair, pair + 1);
    }
    code[index++] = 0xF84107FEU; /* ldr x30, [sp], #16 */
    code[index++] = 0xD65F03C0U; /* ret */
}

static uintptr_t GuestMapStub(uintptr_t imageStart,
                              uint64_t imageSize,
                              uintptr_t target)
{
    const int64_t offsets[] = {
        (int64_t)imageSize + 0x10000,
        -0x1000000,
        0x1000000,
        -0x2000000,
        0x2000000,
    };

    for (size_t index = 0; index < sizeof(offsets) / sizeof(offsets[0]);
         index++) {
        uintptr_t candidate = (uintptr_t)((int64_t)imageStart + offsets[index]);
        candidate &= ~0x3FFFULL;

        int64_t distance = (int64_t)candidate - (int64_t)imageStart;
        if (distance < -(1LL << 26) || distance > (1LL << 26)) {
            continue;
        }
        if (!GuestRangeFree(candidate, 0x4000)) {
            continue;
        }

        uint8_t *page = mmap((void *)candidate,
                             0x4000,
                             PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANON | MAP_FIXED,
                             -1,
                             0);
        if (page == MAP_FAILED) {
            continue;
        }

        uint32_t *code = (uint32_t *)page;
        code[0] = 0x58000050; /* ldr x16, #8 */
        code[1] = 0xD61F0200; /* br x16 */
        *(uint64_t *)(page + 8) = (uint64_t)target;

        for (uint32_t rt = 0; rt < GUEST_TLS_STUB_COUNT; rt++) {
            uint8_t *readStub = page + 0x400 + rt * 32;
            uint8_t *writeStub = page + 0x800 + rt * 0xB0;
            GuestEmitTlsReadStub(readStub, rt);
            GuestEmitTlsWriteStub(writeStub, rt);
            GuestTlsReadStubs[rt] = (uintptr_t)readStub;
            GuestTlsWriteStubs[rt] = (uintptr_t)writeStub;
        }

        sys_icache_invalidate(page, 0x2000);
        mprotect(page, 0x4000, PROT_READ | PROT_EXEC);

        const uint32_t *readStub =
            (const uint32_t *)GuestTlsReadStubs[0];
        const uint32_t *writeStub =
            (const uint32_t *)GuestTlsWriteStubs[19];
        fprintf(stdout,
                "[guest] tls stubs: read0=0x%lx code=%08x %08x %08x %08x %08x\n",
                (unsigned long)GuestTlsReadStubs[0],
                readStub[0],
                readStub[1],
                readStub[2],
                readStub[3],
                readStub[4]);
        fprintf(stdout,
                "[guest] tls stubs: write19=0x%lx code=%08x %08x %08x %08x %08x\n",
                (unsigned long)GuestTlsWriteStubs[19],
                writeStub[0],
                writeStub[1],
                writeStub[2],
                writeStub[3],
                writeStub[4]);
        return candidate;
    }

    return 0;
}

static int GuestLoadAndRun(int argc, char *argv[])
{
    const char *path = argv[1];
    GuestElfPath = path;
    NSString *pathString = [NSString stringWithUTF8String:path];
    NSData *data = pathString != nil
        ? [NSData dataWithContentsOfFile:pathString]
        : nil;
    if (data.length < sizeof(GuestElfHeader)) {
        fprintf(stderr, "[guest] cannot read %s\n", path);
        return 1;
    }

    const uint8_t *file = data.bytes;
    const GuestElfHeader *header = (const GuestElfHeader *)file;
    if (memcmp(header->e_ident, "\x7f""ELF", 4) != 0 ||
        header->e_ident[4] != 2 ||
        header->e_machine != ELF_EM_AARCH64) {
        fprintf(stderr, "[guest] not an aarch64 ELF64\n");
        return 1;
    }

    const GuestElfProgramHeader *programs =
        (const GuestElfProgramHeader *)(file + header->e_phoff);

    uint64_t minAddress = UINT64_MAX;
    uint64_t maxAddress = 0;
    for (uint16_t index = 0; index < header->e_phnum; index++) {
        if (programs[index].p_type != ELF_PT_LOAD) {
            continue;
        }
        minAddress = MIN(minAddress, programs[index].p_vaddr);
        maxAddress = MAX(maxAddress,
                         programs[index].p_vaddr + programs[index].p_memsz);
    }
    if (maxAddress <= minAddress) {
        fprintf(stderr, "[guest] no loadable segments\n");
        return 1;
    }

    uint64_t imageSize = (maxAddress - minAddress + 0x3FFF) & ~0x3FFFULL;
    uintptr_t trampoline = (uintptr_t)&GuestSyscallTrampoline;

    uintptr_t base = 0;
    if (header->e_type == ELF_ET_DYN) {
        base = GuestChooseBase(imageSize, trampoline);
        if (base == 0) {
            fprintf(stderr, "[guest] no free address range near trampoline\n");
            return 1;
        }
    } else if (!GuestRangeFree((uintptr_t)minAddress, (size_t)imageSize)) {
        fprintf(stderr, "[guest] fixed ELF range is occupied\n");
        return 1;
    }

    uintptr_t imageStart = base + (uintptr_t)minAddress;
    GuestImageBase = imageStart;
    GuestImageSize = imageSize;
    void *image = mmap((void *)imageStart,
                       (size_t)imageSize,
                       PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON | MAP_FIXED,
                       -1,
                       0);
    if (image == MAP_FAILED) {
        fprintf(stderr, "[guest] mmap image failed: %s\n", strerror(errno));
        return 1;
    }

    for (uint16_t index = 0; index < header->e_phnum; index++) {
        const GuestElfProgramHeader *program = &programs[index];
        if (program->p_type != ELF_PT_LOAD) {
            continue;
        }

        uint8_t *destination =
            (uint8_t *)image + (program->p_vaddr - minAddress);
        if (program->p_offset + program->p_filesz > data.length) {
            fprintf(stderr, "[guest] segment outside file\n");
            return 1;
        }
        memcpy(destination, file + program->p_offset, (size_t)program->p_filesz);
        if (program->p_memsz > program->p_filesz) {
            memset(destination + program->p_filesz,
                   0,
                   (size_t)(program->p_memsz - program->p_filesz));
        }
    }

    uint32_t patched = 0;
    uint32_t tlsReads = 0;
    uint32_t tlsWrites = 0;
    uintptr_t island = GuestMapStub(imageStart,
                                    imageSize,
                                    (uintptr_t)&GuestSyscallTrampoline);
    if (island == 0) {
        fprintf(stderr, "[guest] no trampoline island near image\n");
        return 1;
    }
    fprintf(stdout, "[guest] island=0x%lx\n", (unsigned long)island);

    for (uint16_t index = 0; index < header->e_phnum; index++) {
        const GuestElfProgramHeader *program = &programs[index];
        if (program->p_type != ELF_PT_LOAD ||
            !(program->p_flags & ELF_PF_X)) {
            continue;
        }

        uint8_t *start = (uint8_t *)image + (program->p_vaddr - minAddress);
        for (uint64_t offset = 0; offset + 4 <= program->p_filesz; offset += 4) {
            uint32_t instruction = *(uint32_t *)(start + offset);
            uintptr_t destination = 0;

            if (instruction == 0xD4000001) {
                destination = island;
            } else if ((instruction & 0xFFFFFFE0U) == 0xD53BD040U) {
                uint32_t rt = instruction & 0x1F;
                if (rt >= GUEST_TLS_STUB_COUNT) {
                    fprintf(stderr,
                            "[guest] mrs tpidr_el0, x%u is unsupported\n",
                            rt);
                    return 1;
                }
                destination = GuestTlsReadStubs[rt];
                tlsReads++;
            } else if ((instruction & 0xFFFFFFE0U) == 0xD51BD040U) {
                uint32_t rt = instruction & 0x1F;
                if (rt >= GUEST_TLS_STUB_COUNT) {
                    fprintf(stderr,
                            "[guest] msr tpidr_el0, x%u is unsupported\n",
                            rt);
                    return 1;
                }
                destination = GuestTlsWriteStubs[rt];
                tlsWrites++;
            } else {
                continue;
            }

            int64_t delta = (int64_t)(destination - (uintptr_t)(start + offset));
            if (delta < -(1LL << 27) || delta >= (1LL << 27)) {
                fprintf(stderr, "[guest] patch site out of bl range\n");
                return 1;
            }
            uint32_t immediate = ((uint32_t)(delta >> 2)) & 0x03FFFFFF;
            *(uint32_t *)(start + offset) = 0x94000000 | immediate;
            if (instruction == 0xD4000001) {
                if (patched < 8) {
                    fprintf(stdout,
                            "[guest] patch site=0x%lx island=0x%lx "
                            "delta=0x%llx word=0x%08x\n",
                            (unsigned long)(start + offset),
                            (unsigned long)island,
                            (unsigned long long)delta,
                            *(uint32_t *)(start + offset));
                }
                patched++;
            }
        }
    }
    sys_icache_invalidate((void *)imageStart, (size_t)imageSize);
    fprintf(stdout,
            "[guest] loaded %s base=0x%lx size=0x%llx patched=%u "
            "tls_mrs=%u tls_msr=%u\n",
            path,
            (unsigned long)base,
            (unsigned long long)imageSize,
            patched,
            tlsReads,
            tlsWrites);

    for (uint16_t index = 0; index < header->e_phnum; index++) {
        const GuestElfProgramHeader *program = &programs[index];
        if (program->p_type != ELF_PT_LOAD || program->p_memsz == 0) {
            continue;
        }

        uintptr_t segmentBase =
            (uintptr_t)image + (program->p_vaddr - minAddress);
        uintptr_t segmentStart = segmentBase & ~0x3FFFULL;
        uintptr_t segmentEnd = (segmentBase + program->p_memsz + 0x3FFF) & ~0x3FFFULL;
        int protection = 0;
        if (program->p_flags & ELF_PF_R) protection |= PROT_READ;
        if (program->p_flags & ELF_PF_W) protection |= PROT_WRITE;
        if (program->p_flags & ELF_PF_X) protection |= PROT_EXEC;
        if (program->p_flags & ELF_PF_X) {
            protection = PROT_READ | PROT_EXEC;
        }
        if (mprotect((void *)segmentStart,
                     (size_t)(segmentEnd - segmentStart),
                     protection) != 0) {
            fprintf(stderr, "[guest] mprotect failed: %s\n", strerror(errno));
            return 1;
        }
    }
    sys_icache_invalidate((void *)imageStart, (size_t)imageSize);

    size_t heapSize = 64 * 1024 * 1024;
    GuestHeapBase = (uintptr_t)mmap(NULL,
                                    heapSize,
                                    PROT_READ | PROT_WRITE,
                                    MAP_PRIVATE | MAP_ANON,
                                    -1,
                                    0);
    if (GuestHeapBase == (uintptr_t)MAP_FAILED) {
        fprintf(stderr, "[guest] heap mmap failed\n");
        return 1;
    }
    GuestHeapEnd = GuestHeapBase + heapSize;
    GuestBrkCurrent = GuestHeapBase;
    fprintf(stdout,
            "[guest] heap=0x%lx..0x%lx\n",
            (unsigned long)GuestHeapBase,
            (unsigned long)GuestHeapEnd);

    size_t stackSize = 8 * 1024 * 1024;
    void *stack = mmap(NULL,
                       stackSize,
                       PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON,
                       -1,
                       0);
    if (stack == MAP_FAILED) {
        fprintf(stderr, "[guest] stack mmap failed\n");
        return 1;
    }
    GuestStackTop = (uint64_t)stack + stackSize;

    int guestArgc = argc > 2 ? argc - 2 : 1;
    char *fallbackArgv[] = { (char *)"guest" };
    char **guestArgv = argc > 2 ? argv + 2 : fallbackArgv;

    uint64_t entry = base + header->e_entry;
    uint64_t stackPointer = GuestBuildStack(GuestStackTop,
                                            guestArgc,
                                            guestArgv,
                                            imageStart,
                                            header,
                                            entry);

    const uint32_t *entryWords =
        (const uint32_t *)(imageStart + (header->e_entry - minAddress));
    fprintf(stdout,
            "[guest] entry=0x%llx stack=0x%llx aligned=%d argc=%d argv0=%s "
            "words=%08x %08x %08x %08x %08x\n",
            (unsigned long long)entry,
            (unsigned long long)stackPointer,
            (stackPointer & 0xF) == 0 ? 1 : 0,
            guestArgc,
            guestArgv[0],
            entryWords[0],
            entryWords[1],
            entryWords[2],
            entryWords[3],
            entryWords[4]);
    fflush(stdout);

    static GuestWatchdogContext watchdogContext;
    watchdogContext.thread = pthread_mach_thread_np(pthread_self());

    pthread_t watchdog;
    if (pthread_create(&watchdog,
                       NULL,
                       GuestWatchdogThread,
                       &watchdogContext) != 0) {
        fprintf(stderr, "[guest] watchdog thread create failed\n");
        return 1;
    }

    fprintf(stdout, "[guest] jump\n");
    fflush(stdout);

    GuestJump(entry, stackPointer);
    fprintf(stdout, "[guest] jump returned\n");
    fflush(stdout);
    return 0;
}

static void GuestHostExit(void)
{
    fprintf(stdout, "[guest] host exit handler\n");
    fflush(stdout);
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
        atexit(GuestHostExit);

        fprintf(stdout, "[guest] runner pid=%d\n", getpid());
        if (argc < 2) {
            fprintf(stderr, "[guest] usage: guest-runner <elf>\n");
            return 2;
        }
        GuestLogCodeSignState("before");
        if (!GuestEnableJIT()) {
            fprintf(stderr, "[guest] JIT unavailable\n");
            return 3;
        }
        GuestLogCodeSignState("after");
        fprintf(stdout, "[guest] jit enabled\n");

        uint32_t selfTest = GuestJITSelfTest();
        fprintf(stdout, "[guest] selftest=%u\n", selfTest);
        if (selfTest != 42) {
            fprintf(stderr, "[guest] self-test failed, aborting\n");
            return 5;
        }

        GuestProbeTpidr();

        int result = GuestLoadAndRun(argc, argv);
        fprintf(stdout, "[guest] host main rc=%d\n", result);
        fflush(stdout);
        return result;
    }
}
