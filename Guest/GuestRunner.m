#import <Foundation/Foundation.h>

#import <TargetConditionals.h>
#import <dirent.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <mach/thread_info.h>
#import <mach/thread_act.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <sched.h>
#import <signal.h>
#import <spawn.h>
#import <stdarg.h>
#import <stddef.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/mount.h>
#import <sys/file.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/ucontext.h>
#import <sys/un.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <poll.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/uio.h>
#import <sys/utsname.h>
#import <sys/wait.h>
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

#define GUEST_DARWIN_SYS_FORK 2

#define GUEST_PT_TRACE_ME 0
#define GUEST_PT_DETACH 11

#define GUEST_CS_OPS_STATUS 0
#define GUEST_CS_DEBUGGED 0x10000000

#define GUEST_ROOT_MAX 1024
#define GUEST_AT_FDCWD (-100)
#define GUEST_F_GETPATH 50

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
#define ELF_PT_INTERP 3
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
static uint64_t GuestStackBase = 0;
static uint64_t GuestStackSize = 0;
static uintptr_t GuestImageBase = 0;
static uint64_t GuestImageSize = 0;
static char GuestElfPath[GUEST_ROOT_MAX];
static char GuestElfHostPath[GUEST_ROOT_MAX];
static uint64_t GuestTlsPointer = 0;
static uintptr_t GuestTlsInitImage = 0;
static uint64_t GuestTlsInitSize = 0;
static uintptr_t GuestIrelSlot = 0;
static uint64_t GuestIrelAddend = 0;

/*
 * Dynamically linked guests: the PT_INTERP image (musl/glibc ld.so) lives at
 * its own base.  AT_BASE points at it, AT_ENTRY at the main executable.
 */
static uintptr_t GuestInterpBase = 0;
static uint64_t GuestInterpSize = 0;
static char GuestInterpPath[GUEST_ROOT_MAX];

/* Bump allocator for guest mmap()/ld.so mappings, kept near the stub page. */
static uintptr_t GuestMmapCursor = 0;

/* Root filesystem: guest "/" maps to <container>/Documents/rootfs. */
static char GuestRootPath[GUEST_ROOT_MAX];
static char GuestCwd[GUEST_ROOT_MAX] = "/";

/*
 * Alpine runtime shipped inside the app bundle.  If copying it into rootfs
 * fails for any reason, /lib/<name> falls back to this directory.
 */
static char GuestAlpineLibPath[PATH_MAX];

/* Most recently forked guest child; used by the watchdog diagnostics. */
static volatile pid_t GuestLastForkChild = 0;

/*
 * Fork has to be issued from anonymous executable memory.  A fork child of
 * this iOS build gets the main executable's __TEXT mapped read-only with
 * max_protection read-only (vm_region says prot=1 max=1, and vm_protect
 * cannot add VM_PROT_EXECUTE), so the instruction after the syscall return
 * faults if it lives in __TEXT.  GuestForkStub therefore runs entirely in
 * the stub page: save, raw fork, and for the child restore the guest frame
 * and branch back through a copied trampoline epilogue.
 */
/*
 * fork() children on this iOS build cannot execute any of our mappings: the
 * main executable's __TEXT is downgraded to read-only with max_protection
 * read-only, and even anonymous r-x pages fault on their first fetch
 * (instruction abort, ESR 0x82000006).  So guest fork is implemented the way
 * Nyxian/WSL1/Cygwin do it: serialise the guest address space, posix_spawn a
 * fresh guest-runner, restore at the very same addresses and resume at the
 * instruction after the original svc.  A fresh exec'd process has normal
 * executable mappings, so this sidesteps the whole problem.
 */
#define GUEST_FORK_MAGIC 0x4C4B4631U /* 'LKF1' */

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t imageBase;
    uint64_t imageSize;
    uint64_t heapBase;
    uint64_t heapSize;
    uint64_t brkCurrent;
    uint64_t stackBase;
    uint64_t stackSize;
    uint64_t stackTop;
    uint64_t stackPage;
    uint64_t frame;
    uint64_t resume;
    uint64_t tlsPointer;
    uint64_t imageOffset;
    uint64_t heapOffset;
    uint64_t stackOffset;
    char cwd[GUEST_ROOT_MAX];
} GuestForkSnapshot;

static uintptr_t GuestForkStub = 0;
static uintptr_t GuestForcedBase = 0;
static uintptr_t GuestForcedHeap = 0;
static uintptr_t GuestForcedStack = 0;
static const char *GuestRestorePath = NULL;

extern char **environ;

static uint64_t GuestExecSyscall(uint64_t pathAddress,
                                 uint64_t argvAddress,
                                 uint64_t envpAddress);

static uint64_t GuestForkWithSnapshot(uint64_t *args, uint64_t resume);
static void GuestRestoreImage(void);
static void GuestRestoreStackAndJump(void);

static int GuestLoadAndRunInternal(const char *guestPath,
                                   const char *hostPath,
                                   int guestArgc,
                                   char *guestArgv[],
                                   int environmentCount,
                                   char *environment[],
                                   BOOL initial);

/* Loader helpers shared with the mmap() path (implemented below). */
static int GuestPatchCodeRange(uintptr_t start,
                               uint64_t length,
                               uint32_t *patched,
                               uint32_t *tlsReads,
                               uint32_t *tlsWrites);
static int GuestPatchMappedElf(int descriptor,
                               uint64_t fileOffset,
                               uintptr_t mapAddress,
                               size_t mapLength,
                               uint32_t *patched,
                               uint32_t *tlsReads,
                               uint32_t *tlsWrites);
static uintptr_t GuestAllocateMmapAddress(size_t length,
                                          uintptr_t hint,
                                          BOOL fixed);
static BOOL GuestRangeOverlapsRuntime(uintptr_t address, size_t length);
static void GuestRememberMmap(uintptr_t address, size_t length);
static void GuestDumpMmapRecords(void);
static void GuestDescribeAddress(uintptr_t address,
                                 char *buffer,
                                 size_t size);
static unsigned GuestMunmapSharedPages;
static unsigned GuestMunmapReleasedPages;
static unsigned GuestMunmapKeptPages;
static unsigned GuestMappingChecks;
static unsigned GuestMappingUnbacked;
/*
 * The fault address is in no record and in no runtime range, so the most
 * likely story is "it was released while still owned".  Keep the last freed
 * ranges and check them when a fault happens: that names the release instead
 * of inferring it.
 */
#define GUEST_FREED_SLOTS 64
static uintptr_t GuestFreedStart[GUEST_FREED_SLOTS];
static uintptr_t GuestFreedEnd[GUEST_FREED_SLOTS];
static unsigned GuestFreedCount;

static void GuestRememberFreed(uintptr_t address, size_t length)
{
    unsigned slot = GuestFreedCount % GUEST_FREED_SLOTS;
    GuestFreedStart[slot] = address;
    GuestFreedEnd[slot] = address + length;
    GuestFreedCount++;
}

static BOOL GuestAddressWasFreed(uintptr_t address, uintptr_t *start,
                                 uintptr_t *end)
{
    unsigned limit = GuestFreedCount < GUEST_FREED_SLOTS
        ? GuestFreedCount : GUEST_FREED_SLOTS;
    for (unsigned index = 0; index < limit; index++) {
        if (address >= GuestFreedStart[index] &&
            address < GuestFreedEnd[index]) {
            *start = GuestFreedStart[index];
            *end = GuestFreedEnd[index];
            return YES;
        }
    }
    return NO;
}
/*
 * Passing a file mapping straight to Darwin is only safe for data: iOS refuses
 * to mprotect a file-backed page to PROT_EXEC (that is exactly how the guarded
 * libz failed to load: "Permission denied (needed by apk)").  ld.so maps whole
 * libraries PROT_READ first and only later marks segments executable, so any
 * file that starts with the ELF magic must stay on the emulated path.
 */
static BOOL GuestFileIsElf(int descriptor)
{
    unsigned char magic[4];
    if (descriptor < 0) {
        return NO;
    }
    if (pread(descriptor, magic, sizeof(magic), 0) != (ssize_t)sizeof(magic)) {
        return NO;
    }
    return magic[0] == 0x7f && magic[1] == 'E' &&
           magic[2] == 'L' && magic[3] == 'F';
}

static uint64_t GuestHandleMmap(uint64_t hint,
                                uint64_t length,
                                int prot,
                                uint64_t guestFlags,
                                int descriptor,
                                uint64_t offset);
static uint64_t GuestHandleMunmap(uintptr_t address, size_t length);
static uint64_t GuestHandleMremap(uintptr_t oldAddress,
                                  size_t oldLength,
                                  size_t newLength,
                                  uint64_t flags,
                                  uintptr_t newAddress);
static uint64_t GuestHandleMprotect(uintptr_t address,
                                    size_t length,
                                    int prot);
static void GuestSealStubPage(void);
static void GuestUnsealStubPage(void);

#pragma mark - JIT and fault reporting

static uint64_t GuestSafeRead64(uint64_t address, kern_return_t *status);
static void GuestAlarmHandler(int signalNumber,
                              siginfo_t *information,
                              void *context);

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

/*
 * Logging must not use stdio.  After fork() the child inherits whatever
 * locks libc held at fork time; if another thread (the watchdog) held the
 * stdout FILE lock, the child would deadlock on its first fprintf and the
 * parent would sit in wait4 forever.  Format into a stack buffer and use
 * write(2) directly.
 */
static void GuestLog(const char *format, ...) __attribute__((format(printf, 1, 2)));

static void GuestLog(const char *format, ...)
{
    char buffer[1024];
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(buffer, sizeof(buffer), format, arguments);
    va_end(arguments);
    if (length <= 0) {
        return;
    }
    size_t size = (size_t)length;
    if (size >= sizeof(buffer)) {
        size = sizeof(buffer) - 1;
    }
    GuestWriteAll(STDOUT_FILENO, buffer, size);
}

/*
 * Path syscalls only logged the first few failures, which hid the EACCES that
 * aborted `apk add'.  Record the guest path, the translated host path and the
 * errno for the first 40 failures of any of them.
 */
static unsigned int GuestFileErrorCount = 0;

static void GuestLogFileError(const char *operation,
                              const char *guestPath,
                              const char *hostPath,
                              int error)
{
    if (GuestFileErrorCount >= 40) {
        return;
    }
    GuestFileErrorCount++;
    GuestLog("[guest] %s failed guest=%s host=%s errno=%d (%s)\n",
             operation,
             guestPath != NULL ? guestPath : "-",
             hostPath != NULL ? hostPath : "-",
             error,
             strerror(error));
}

static void GuestSignalHandler(int signalNumber,
                               siginfo_t *information,
                               void *context)
{
    /* First thing: prove the handler actually runs, using only write(2). */
    GuestWriteAll(STDOUT_FILENO, "[H]", 3);

    ucontext_t *state = (ucontext_t *)context;
    uint64_t pc = 0;
    uint64_t lr = 0;
    uint64_t sp = 0;
    uint64_t far = 0;
    uint32_t esr = 0;
    uint64_t registers[29] = { 0 };
    if (state != NULL && state->uc_mcontext != NULL) {
        pc = (uint64_t)state->uc_mcontext->__ss.__pc;
        lr = (uint64_t)state->uc_mcontext->__ss.__lr;
        sp = (uint64_t)state->uc_mcontext->__ss.__sp;
        far = (uint64_t)state->uc_mcontext->__es.__far;
        esr = (uint32_t)state->uc_mcontext->__es.__esr;
        for (int index = 0; index < 29; index++) {
            registers[index] = (uint64_t)state->uc_mcontext->__ss.__x[index];
        }
    }

    char text[512];
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

    /*
     * "pc=0x..." alone says nothing once libraries are loaded: the number has
     * to be tied to a module before it can be disassembled.  Name the record
     * that contains pc, so the offset is relative to a known base.
     */
    {
        char module[128];
        GuestDescribeAddress((uintptr_t)pc, module, sizeof(module));
        length = snprintf(text, sizeof(text), "[guest] pc in %s\n", module);
        if (length > 0) {
            GuestWriteAll(STDOUT_FILENO, text, (size_t)length);
        }
    }
    /*
     * The fault address matters as much as pc: if it lands inside a live
     * mapping the writer aliased somebody else's memory, and if it lands in no
     * mapping at all then a range we handed out was never mapped (or was
     * released while still owned).
     */
    {
        char faulted[128];
        GuestDescribeAddress((uintptr_t)far, faulted, sizeof(faulted));
        length = snprintf(text, sizeof(text), "[guest] far in %s\n", faulted);
        uintptr_t freedStart = 0;
        uintptr_t freedEnd = 0;
        if (GuestAddressWasFreed((uintptr_t)far, &freedStart, &freedEnd)) {
            snprintf(faulted, sizeof(faulted),
                     "[guest] far was released earlier: 0x%lx..0x%lx\n",
                     (unsigned long)freedStart, (unsigned long)freedEnd);
            GuestWriteAll(STDOUT_FILENO, faulted, strlen(faulted));
        }
        if (length > 0) {
            GuestWriteAll(STDOUT_FILENO, text, (size_t)length);
        }
        /*
         * 0.40.13: "no guest mapping" cannot distinguish "never mapped" from
         * "mapped PROT_NONE" -- Darwin reports both as a translation fault.
         * Ask the kernel about the fault address itself and print its host
         * region and protection, then dump the whole record table: the answer
         * is which of the two worlds far belongs to.
         */
        {
            vm_address_t faultRegion = (vm_address_t)far;
            vm_size_t faultRegionSize = 0;
            vm_region_basic_info_data_64_t faultInfo;
            mach_msg_type_number_t faultCount = VM_REGION_BASIC_INFO_COUNT_64;
            mach_port_t faultObject = MACH_PORT_NULL;
            memset(&faultInfo, 0, sizeof(faultInfo));
            kern_return_t faultKr = vm_region_64(mach_task_self(),
                                                 &faultRegion,
                                                 &faultRegionSize,
                                                 VM_REGION_BASIC_INFO_64,
                                                 (vm_region_info_t)&faultInfo,
                                                 &faultCount,
                                                 &faultObject);
            if (faultObject != MACH_PORT_NULL) {
                mach_port_deallocate(mach_task_self(), faultObject);
            }
            if (faultKr == KERN_SUCCESS) {
                length = snprintf(text,
                                  sizeof(text),
                                  "[guest] far host region: 0x%lx..0x%lx"
                                  " prot=%d max=%d\n",
                                  (unsigned long)faultRegion,
                                  (unsigned long)(faultRegion +
                                                  faultRegionSize),
                                  (int)faultInfo.protection,
                                  (int)faultInfo.max_protection);
            } else {
                length = snprintf(text,
                                  sizeof(text),
                                  "[guest] far host region: none (kr=%d)\n",
                                  (int)faultKr);
            }
            if (length > 0) {
                GuestWriteAll(STDOUT_FILENO, text, (size_t)length);
            }
        }
        /*
         * 0.40.14: the crash is a byte store at the tail of a copy, so the
         * registers name src/dst/bound, and x0 is zlib's z_stream.  Print
         * both instead of inferring the buffer size from the mapping.
         */
        for (int base = 8; base <= 28; base += 7) {
            int count = 28 - base + 1;
            if (count > 7) {
                count = 7;
            }
            int used = snprintf(text, sizeof(text), "[guest] regs");
            for (int index = 0; index < count; index++) {
                int room = (int)sizeof(text) - used;
                if (room <= 1) {
                    break;
                }
                int wrote = snprintf(text + used,
                                     (size_t)room,
                                     " x%d=0x%llx",
                                     base + index,
                                     (unsigned long long)registers[base + index]);
                if (wrote <= 0) {
                    break;
                }
                used += wrote;
                if ((size_t)used >= sizeof(text)) {
                    used = (int)sizeof(text) - 1;
                    break;
                }
            }
            if (used > 0) {
                text[used++] = '\n';
                GuestWriteAll(STDOUT_FILENO, text, (size_t)used);
            }
        }
        {
            uint64_t stream = registers[0];
            kern_return_t readStatus = KERN_FAILURE;
            uint64_t nextIn = GuestSafeRead64(stream + 0x00, &readStatus);
            uint64_t availInWord = GuestSafeRead64(stream + 0x08, &readStatus);
            uint64_t totalIn = GuestSafeRead64(stream + 0x10, &readStatus);
            uint64_t nextOut = GuestSafeRead64(stream + 0x18, &readStatus);
            uint64_t availOutWord = GuestSafeRead64(stream + 0x20, &readStatus);
            uint64_t totalOut = GuestSafeRead64(stream + 0x28, &readStatus);
            uint64_t stateField = GuestSafeRead64(stream + 0x38, &readStatus);
            if (readStatus == KERN_SUCCESS) {
                length = snprintf(text,
                                  sizeof(text),
                                  "[guest] strm in=0x%llx avail_in=%u"
                                  " total_in=%llu out=0x%llx avail_out=%u"
                                  " total_out=%llu state=0x%llx\n",
                                  (unsigned long long)nextIn,
                                  (unsigned)(availInWord & 0xffffffffu),
                                  (unsigned long long)totalIn,
                                  (unsigned long long)nextOut,
                                  (unsigned)(availOutWord & 0xffffffffu),
                                  (unsigned long long)totalOut,
                                  (unsigned long long)stateField);
                if (length > 0) {
                    GuestWriteAll(STDOUT_FILENO, text, (size_t)length);
                }
            }
        }
        GuestDumpMmapRecords();
    }

    length = snprintf(text,
                      sizeof(text),
                      "[guest] in-process x0=0x%llx x1=0x%llx x2=0x%llx "
                      "x3=0x%llx x4=0x%llx x5=0x%llx x6=0x%llx x7=0x%llx "
                      "tls=0x%llx\n",
                      (unsigned long long)registers[0],
                      (unsigned long long)registers[1],
                      (unsigned long long)registers[2],
                      (unsigned long long)registers[3],
                      (unsigned long long)registers[4],
                      (unsigned long long)registers[5],
                      (unsigned long long)registers[6],
                      (unsigned long long)registers[7],
                      (unsigned long long)GuestTlsPointer);
    if (length > 0) {
        GuestWriteAll(STDOUT_FILENO, text, (size_t)length);
    }

    kern_return_t slotStatus = KERN_FAILURE;
    kern_return_t localeStatus = KERN_FAILURE;
    uint64_t slot = GuestSafeRead64(GuestTlsPointer + 0x10, &slotStatus);
    uint64_t locale = slotStatus == KERN_SUCCESS
        ? GuestSafeRead64(slot, &localeStatus) : 0;
    length = snprintf(text,
                      sizeof(text),
                      "[guest] in-process slot=0x%llx locale=0x%llx (%d/%d)\n",
                      (unsigned long long)slot,
                      (unsigned long long)locale,
                      (int)slotStatus,
                      (int)localeStatus);
    if (length > 0) {
        GuestWriteAll(STDOUT_FILENO, text, (size_t)length);
    }

    /*
     * If this is the __ctype_init fault, the faulting instruction is
     * "ldr x1,[x1]" and the mrs stub site is 0x1c bytes earlier.  Dump the
     * memory the instruction would have dereferenced, plus the code word at
     * the mrs site, to tell "mrs stub never ran" from "x0 changed later".
     */
    kern_return_t x0Status = KERN_FAILURE;
    kern_return_t x010Status = KERN_FAILURE;
    kern_return_t x048Status = KERN_FAILURE;
    kern_return_t siteStatus = KERN_FAILURE;
    uint64_t x0Word = GuestSafeRead64(registers[0], &x0Status);
    uint64_t x010Word = GuestSafeRead64(registers[0] + 0x10, &x010Status);
    uint64_t x048Word = GuestSafeRead64(registers[0] + 0x48, &x048Status);
    uint64_t siteWord = pc >= 0x1c
        ? GuestSafeRead64(pc - 0x1c, &siteStatus) : 0;
    length = snprintf(text,
                      sizeof(text),
                      "[guest] in-process x0mem=0x%llx x0+10=0x%llx "
                      "x0+48=0x%llx siteword=0x%08x (%d/%d/%d/%d)\n",
                      (unsigned long long)x0Word,
                      (unsigned long long)x010Word,
                      (unsigned long long)x048Word,
                      (unsigned)(siteWord & 0xFFFFFFFFU),
                      (int)x0Status,
                      (int)x010Status,
                      (int)x048Status,
                      (int)siteStatus);
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
    static void *alternateStack = NULL;
    if (alternateStack == NULL) {
        alternateStack = mmap(NULL,
                              64 * 1024,
                              PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANON,
                              -1,
                              0);
        if (alternateStack != MAP_FAILED) {
            stack_t stack;
            memset(&stack, 0, sizeof(stack));
            stack.ss_sp = alternateStack;
            stack.ss_size = 64 * 1024;
            sigaltstack(&stack, NULL);
        }
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = GuestSignalHandler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);

    const int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE };
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]);
         index++) {
        sigaction(signals[index], &action, NULL);
    }

    struct sigaction alarmAction;
    memset(&alarmAction, 0, sizeof(alarmAction));
    alarmAction.sa_sigaction = GuestAlarmHandler;
    alarmAction.sa_flags = SA_SIGINFO | SA_RESTART | SA_ONSTACK;
    sigemptyset(&alarmAction.sa_mask);
    sigaction(SIGALRM, &alarmAction, NULL);
}

static void GuestLogCodeSignState(const char *tag)
{
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    (void)tag;
    GuestLog("[guest] csops skipped on host/simulator\n");
#else
    uint32_t flags = 0;
    int result = csops(getpid(), GUEST_CS_OPS_STATUS, &flags, sizeof(flags));
    GuestLog( "[guest] %s: csops=%d flags=0x%08x debugged=%d\n",
            tag,
            result,
            flags,
            (flags & GUEST_CS_DEBUGGED) ? 1 : 0);
#endif
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
        GuestLog( "[guest] selftest mmap failed: %s\n", strerror(errno));
        return 0;
    }

    page[0] = 0x52800540; /* mov w0, #42 */
    page[1] = 0xD65F03C0; /* ret */
    sys_icache_invalidate(page, 8);

    if (mprotect(page, 0x4000, PROT_READ | PROT_EXEC) != 0) {
        GuestLog( "[guest] selftest mprotect failed: %s\n",
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

    GuestLog(
            "[guest] tpidr probe: original=0x%llx write=0x%llx after_svc=0x%llx\n",
            (unsigned long long)original,
            (unsigned long long)written,
            (unsigned long long)afterSyscall);
}

static BOOL GuestEnableJIT(void)
{
#if TARGET_OS_SIMULATOR
    /*
     * The simulator runs on the Mac but is not hardened and allows RWX for
     * anonymous pages, so no CS_DEBUGGED handshake is needed.
     */
    GuestInstallFaultHandlers();
    return YES;
#elif TARGET_OS_OSX
    /*
     * macOS arm64 has 16 KB pages like the iPad.  The runtime deliberately
     * unions permissions for 4 KB guest pages sharing a 16 KB host page,
     * which can produce RWX; local JIT self-tests show that only a debugged
     * process gets that permission, exactly like iOS.  PT_TRACE_ME is
     * enough; do not raise SIGSTOP (there is no App-side tracer in CI).
     */
    if (ptrace(GUEST_PT_TRACE_ME, 0, NULL, 0) < 0) {
        GuestLog("[guest] macOS ptrace(PT_TRACE_ME) failed: %s\n",
                 strerror(errno));
    }
    GuestInstallFaultHandlers();
    return YES;
#else
    if (ptrace(GUEST_PT_TRACE_ME, 0, NULL, 0) < 0) {
        GuestLog( "[guest] ptrace(PT_TRACE_ME) failed: %s\n",
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
#endif
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
        "mov x2, x16\n"
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

/*
 * Darwin and Linux agree on errno 1..34 and then diverge almost
 * everywhere.  The guest is Linux, so every error returned to it must be
 * translated.  This matters immediately for networking: Darwin EAGAIN is
 * 35 while Linux EAGAIN is 11, and musl's resolver treats anything other
 * than 11 as a hard failure.
 */
static int GuestLinuxErrnoFromDarwin(int error)
{
    switch (error) {
    case 0:
        return 0;
    case EDEADLK:
        return 35;
    case EAGAIN:
        return 11;
    case EINPROGRESS:
        return 115;
    case EALREADY:
        return 114;
    case ENOTSOCK:
        return 88;
    case EDESTADDRREQ:
        return 89;
    case EMSGSIZE:
        return 90;
    case EPROTOTYPE:
        return 91;
    case ENOPROTOOPT:
        return 92;
    case EPROTONOSUPPORT:
        return 93;
    case ESOCKTNOSUPPORT:
        return 94;
    case ENOTSUP:
        return 95;
    case EPFNOSUPPORT:
        return 96;
    case EAFNOSUPPORT:
        return 97;
    case EADDRINUSE:
        return 98;
    case EADDRNOTAVAIL:
        return 99;
    case ENETDOWN:
        return 100;
    case ENETUNREACH:
        return 101;
    case ENETRESET:
        return 102;
    case ECONNABORTED:
        return 103;
    case ECONNRESET:
        return 104;
    case ENOBUFS:
        return 105;
    case EISCONN:
        return 106;
    case ENOTCONN:
        return 107;
    case ESHUTDOWN:
        return 108;
    case ETOOMANYREFS:
        return 109;
    case ETIMEDOUT:
        return 110;
    case ECONNREFUSED:
        return 111;
    case EHOSTDOWN:
        return 112;
    case EHOSTUNREACH:
        return 113;
    case ELOOP:
        return 40;
    case ENAMETOOLONG:
        return 36;
    case ENOTEMPTY:
        return 39;
    case EUSERS:
        return 87;
    case EDQUOT:
        return 122;
    case ESTALE:
        return 116;
    case EREMOTE:
        return 66;
    case EOVERFLOW:
        return 75;
    case ECANCELED:
        return 125;
    case EIDRM:
        return 43;
    case ENOMSG:
        return 42;
    case EILSEQ:
        return 84;
    case ENOATTR:
        return 61;
    case EBADMSG:
        return 74;
    case EMULTIHOP:
        return 72;
    case ENODATA:
        return 61;
    case ENOLINK:
        return 67;
    case ENOSR:
        return 63;
    case ENOSTR:
        return 60;
    case EPROTO:
        return 71;
    case ETIME:
        return 62;
    case EOPNOTSUPP:
        return 95;
    case ENOTRECOVERABLE:
        return 131;
    case EOWNERDEAD:
        return 130;
    default:
        return error;
    }
}

static int GuestErrorCode(int error)
{
    return -GuestLinuxErrnoFromDarwin(error);
}

static uint64_t GuestError(int error)
{
    return (uint64_t)(int64_t)GuestErrorCode(error);
}

static uint64_t GuestErrno(void)
{
    return GuestError(errno);
}

#pragma mark - Guest filesystem

static void GuestEnsureDirectory(const char *path)
{
    char buffer[GUEST_ROOT_MAX];
    size_t length = strlen(path);
    if (length == 0 || length >= sizeof(buffer)) {
        return;
    }
    memcpy(buffer, path, length + 1);
    for (char *cursor = buffer + 1; *cursor != 0; cursor++) {
        if (*cursor != '/') {
            continue;
        }
        *cursor = 0;
        if (mkdir(buffer, 0755) != 0 && errno != EEXIST) {
            GuestLog("[guest] mkdir %s failed errno=%d\n", buffer, errno);
        }
        *cursor = '/';
    }
    if (mkdir(buffer, 0755) != 0 && errno != EEXIST) {
        GuestLog("[guest] mkdir %s failed errno=%d\n", buffer, errno);
    }
}

/*
 * Some guest programs (apk) assume /etc/apk and /lib/apk/db already exist.
 * If an O_CREAT open fails with ENOENT, create the parent directories under
 * the synthetic root and retry once.
 */
static void GuestCreateParentDirectories(const char *hostPath)
{
    char buffer[GUEST_ROOT_MAX];
    size_t length = strlen(hostPath);
    if (length == 0 || length >= sizeof(buffer)) {
        return;
    }
    memcpy(buffer, hostPath, length + 1);
    char *slash = strrchr(buffer, '/');
    if (slash == NULL || slash == buffer) {
        return;
    }
    *slash = 0;
    GuestEnsureDirectory(buffer);
}

static void GuestWriteTextFile(const char *path, const char *text)
{
    int descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (descriptor < 0) {
        return;
    }
    size_t length = strlen(text);
    ssize_t written = write(descriptor, text, length);
    (void)written;
    close(descriptor);
}

/*
 * apk owns /etc/apk/world and /lib/apk/db/installed.  Recreating them on
 * every run would erase the installed package database, so only create them
 * when they are missing (first boot).
 */
static void GuestCreateEmptyFileIfMissing(const char *path)
{
    if (access(path, F_OK) == 0) {
        return;
    }
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (descriptor >= 0) {
        close(descriptor);
    }
}

static void GuestCopyHostFile(const char *sourcePath, const char *targetPath)
{
    int source = open(sourcePath, O_RDONLY);
    if (source < 0) {
        return;
    }
    int target = open(targetPath, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (target < 0) {
        close(source);
        return;
    }
    char chunk[65536];
    for (;;) {
        ssize_t count = read(source, chunk, sizeof(chunk));
        if (count <= 0) {
            break;
        }
        if (write(target, chunk, (size_t)count) != count) {
            break;
        }
    }
    close(target);
    close(source);
    chmod(targetPath, 0755);
}

static void GuestCreateAppletLinks(const char *directory, const char *target)
{
    static const char *applets[] = {
        "sh", "ash", "ls", "cat", "echo", "printf", "uname", "id", "whoami",
        "pwd", "mkdir", "rmdir", "rm", "mv", "cp", "ln", "chmod", "chown",
        "touch", "sleep", "date", "hostname", "env", "printenv", "grep",
        "egrep", "fgrep", "sed", "awk", "sort", "uniq", "wc", "head", "tail",
        "cut", "tr", "find", "xargs", "tar", "gzip", "gunzip", "df", "du",
        "free", "ps", "kill", "killall", "mount", "umount", "dmesg", "vi",
        "less", "more", "hexdump", "od", "md5sum", "sha256sum", "basename",
        "dirname", "expr", "seq", "test", "[", "true", "false", "yes",
        "which", "readlink", "realpath", "stat", "mktemp", "tee", "test",
        "dos2unix", "unix2dos", "patch", "diff", "cmp", "tar", "dd", "sync",
    };

    size_t count = sizeof(applets) / sizeof(applets[0]);
    for (size_t index = 0; index < count; index++) {
        char linkPath[GUEST_ROOT_MAX];
        snprintf(linkPath,
                 sizeof(linkPath),
                 "%s/%s",
                 directory,
                 applets[index]);
        struct stat status;
        if (lstat(linkPath, &status) == 0) {
            continue;
        }
        symlink(target, linkPath);
    }
}

/*
 * Install the Alpine runtime files that ship next to the runner.  Only the
 * musl loader/libc and the libraries apk needs live here; the binaries stay
 * in the bundle.  Symlinks are copied as symlinks by NSFileManager.
 */
static void GuestInstallAlpineRuntime(NSString *directory)
{
    NSString *source =
        [directory stringByAppendingPathComponent:@"alpine"];
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    BOOL exists = [manager fileExistsAtPath:source isDirectory:&isDirectory];
    GuestLog("[guest] alpine source=%s exists=%d dir=%d\n",
             source.fileSystemRepresentation,
             exists ? 1 : 0,
             isDirectory ? 1 : 0);
    if (!exists || !isDirectory) {
        return;
    }

    NSString *destination = [NSString stringWithUTF8String:GuestRootPath];
    NSDirectoryEnumerator<NSString *> *enumerator =
        [manager enumeratorAtPath:source];
    NSUInteger copied = 0;
    for (NSString *relative in enumerator) {
        NSString *from = [source stringByAppendingPathComponent:relative];
        /*
         * enumeratorAtPath: also yields directories.  Copying one with
         * copyItemAtPath: would replace the whole destination directory and
         * delete rootfs files that were not in the bundle (this is how 0.38.0
         * lost /etc/apk/arch and /etc/resolv.conf).  Only copy leaves;
         * parent directories are created below.
         */
        BOOL relativeIsDirectory = NO;
        if ([manager fileExistsAtPath:from isDirectory:&relativeIsDirectory] &&
            relativeIsDirectory) {
            continue;
        }
        NSString *to = [destination stringByAppendingPathComponent:relative];
        [manager createDirectoryAtPath:[to stringByDeletingLastPathComponent]
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:NULL];
        [manager removeItemAtPath:to error:NULL];
        NSError *error = nil;
        if ([manager copyItemAtPath:from toPath:to error:&error]) {
            copied++;
        } else {
            GuestLog("[guest] alpine copy %s failed: %s\n",
                     relative.fileSystemRepresentation,
                     error.localizedDescription.UTF8String);
        }
    }
    GuestLog("[guest] alpine runtime files=%lu\n", (unsigned long)copied);
    {
        /* Which zlib actually made it into the rootfs: the inflate failures
         * are version-specific suspects, so log the size we ended up with. */
        char zlibPath[GUEST_ROOT_MAX];
        struct stat zlibInfo;
        snprintf(zlibPath,
                 sizeof(zlibPath),
                 "%s/lib/libz.so.1",
                 GuestRootPath);
        if (stat(zlibPath, &zlibInfo) == 0) {
            GuestLog("[guest] libz size=%lld\n", (long long)zlibInfo.st_size);
        } else {
            GuestLog("[guest] libz missing at %s\n", zlibPath);
        }
    }

    char certificatePath[GUEST_ROOT_MAX];
    snprintf(certificatePath,
             sizeof(certificatePath),
             "%s/etc/ssl/certs/ca-certificates.crt",
             GuestRootPath);
    struct stat certificateStatus;
    int certificateExists = stat(certificatePath, &certificateStatus) == 0;
    GuestLog("[guest] ca bundle=%s exists=%d size=%lld\n",
             certificatePath,
             certificateExists,
             certificateExists ? (long long)certificateStatus.st_size : -1LL);

    /*
     * OpenSSL's compiled-in default is <openssldir>/cert.pem.  Keep a second
     * diagnostic for it: with a bad SSL_CERT_FILE the whole default trust
     * store is skipped, so knowing whether this fallback exists matters.
     */
    char defaultCertificatePath[GUEST_ROOT_MAX];
    snprintf(defaultCertificatePath,
             sizeof(defaultCertificatePath),
             "%s/etc/ssl/cert.pem",
             GuestRootPath);
    struct stat defaultCertificateStatus;
    int defaultCertificateExists =
        stat(defaultCertificatePath, &defaultCertificateStatus) == 0;
    GuestLog("[guest] cert.pem=%s exists=%d size=%lld\n",
             defaultCertificatePath,
             defaultCertificateExists,
             defaultCertificateExists
                 ? (long long)defaultCertificateStatus.st_size
                 : -1LL);

    const char *certificateVariable = getenv("SSL_CERT_FILE");
    const char *certificateDirectoryVariable = getenv("SSL_CERT_DIR");
    GuestLog("[guest] tls env: SSL_CERT_FILE=%s SSL_CERT_DIR=%s\n",
             certificateVariable != NULL ? certificateVariable : "(unset)",
             certificateDirectoryVariable != NULL
                 ? certificateDirectoryVariable
                 : "(unset)");
    GuestLog("[guest] time=%lld\n", (long long)time(NULL));
}

static void GuestBootstrapRootfs(void)
{
    const char *configured = getenv("LINUXPROBE_ROOT");
    if (configured != NULL && configured[0] == '/') {
        snprintf(GuestRootPath,
                 sizeof(GuestRootPath),
                 "%s",
                 configured);
    } else {
        /*
         * TrollStore apps run unsandboxed, so NSDocumentDirectory resolves
         * to /var/mobile/Documents rather than the app's data container.
         * TMPDIR still points inside the container, so derive Documents
         * from it when possible.
         */
        NSString *temporary = NSTemporaryDirectory();
        NSString *documents = nil;
        if ([temporary containsString:@"/Containers/Data/Application/"]) {
            documents = [[temporary stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"Documents"];
        }
        if (documents.length == 0) {
            documents = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        }
        if (documents.length > 0) {
            snprintf(GuestRootPath,
                     sizeof(GuestRootPath),
                     "%s/rootfs",
                     documents.fileSystemRepresentation);
        } else {
            const char *home = getenv("HOME");
            if (home == NULL || home[0] == 0) {
                home = "/tmp";
            }
            snprintf(GuestRootPath,
                     sizeof(GuestRootPath),
                     "%s/Documents/rootfs",
                     home);
        }
    }
    GuestEnsureDirectory(GuestRootPath);

    static const char *directories[] = {
        "bin", "sbin", "lib", "lib64", "usr", "usr/bin", "usr/sbin",
        "usr/lib", "usr/lib64", "usr/share", "etc", "etc/apk", "etc/apk/keys",
        "etc/ssl", "etc/ssl/certs", "lib/apk", "lib/apk/db", "tmp", "var",
        "var/tmp", "var/log", "var/cache", "var/cache/apk", "dev", "proc",
        "sys", "root", "home", "mnt", "media", "opt", "srv", "run", "boot",
    };
    for (size_t index = 0;
         index < sizeof(directories) / sizeof(directories[0]);
         index++) {
        char path[GUEST_ROOT_MAX];
        snprintf(path, sizeof(path), "%s/%s", GuestRootPath, directories[index]);
        GuestEnsureDirectory(path);
    }

    char path[GUEST_ROOT_MAX];
    snprintf(path, sizeof(path), "%s/etc/motd", GuestRootPath);
    GuestWriteTextFile(path, "Welcome to Linux Probe on iPad.\n");

    snprintf(path, sizeof(path), "%s/etc/hostname", GuestRootPath);
    GuestWriteTextFile(path, "linuxprobe\n");

    snprintf(path, sizeof(path), "%s/etc/os-release", GuestRootPath);
    GuestWriteTextFile(path,
                       "NAME=\"Linux Probe\"\n"
                       "ID=linuxprobe\n"
                       "PRETTY_NAME=\"Linux Probe (native arm64)\"\n"
                       "VERSION_ID=0.27.0\n"
                       "HOME_URL=https://github.com/Da-AiXZ/linux\n"
                       "ARCH=aarch64\n");

    snprintf(path, sizeof(path), "%s/etc/passwd", GuestRootPath);
    char passwd[512];
    snprintf(passwd,
             sizeof(passwd),
             "root:x:0:0:root:/root:/bin/sh\n"
             "linux:x:%u:%u:linux:/home:/bin/sh\n",
             (unsigned)getuid(),
             (unsigned)getgid());
    GuestWriteTextFile(path, passwd);

    snprintf(path, sizeof(path), "%s/etc/group", GuestRootPath);
    GuestWriteTextFile(path,
                       "root:x:0:\n"
                       "linux:x:501:\n");

    snprintf(path, sizeof(path), "%s/etc/resolv.conf", GuestRootPath);
    GuestWriteTextFile(path, "nameserver 1.1.1.1\nnameserver 8.8.8.8\n");

    snprintf(path, sizeof(path), "%s/etc/hosts", GuestRootPath);
    GuestWriteTextFile(path,
                       "127.0.0.1 localhost localhost.localdomain\n"
                       "::1 localhost\n");

    snprintf(path, sizeof(path), "%s/etc/nsswitch.conf", GuestRootPath);
    GuestWriteTextFile(path, "passwd: files\ngroup: files\nhosts: files\n");

    snprintf(path, sizeof(path), "%s/etc/apk/arch", GuestRootPath);
    GuestWriteTextFile(path, "aarch64\n");

    snprintf(path, sizeof(path), "%s/etc/apk/repositories", GuestRootPath);
    GuestWriteTextFile(path,
                       "https://dl-cdn.alpinelinux.org/alpine/v3.20/main\n"
                       "https://dl-cdn.alpinelinux.org/alpine/v3.20/community\n");

    snprintf(path, sizeof(path), "%s/etc/apk/world", GuestRootPath);
    GuestCreateEmptyFileIfMissing(path);

    snprintf(path, sizeof(path), "%s/lib/apk/db/installed", GuestRootPath);
    GuestCreateEmptyFileIfMissing(path);

    snprintf(path, sizeof(path), "%s/lib/apk/db", GuestRootPath);
    struct stat apkDatabaseStatus;
    GuestLog("[guest] apk db dir=%s exists=%d\n",
             path,
             stat(path, &apkDatabaseStatus) == 0 ? 1 : 0);

    char executable[PATH_MAX];
    uint32_t executableSize = sizeof(executable);
    if (_NSGetExecutablePath(executable, &executableSize) == 0) {
        char *slash = strrchr(executable, '/');
        if (slash != NULL) {
            *slash = 0;
        }
        char source[PATH_MAX];
        snprintf(source, sizeof(source), "%s/busybox", executable);
        char target[GUEST_ROOT_MAX];
        snprintf(target, sizeof(target), "%s/bin/busybox", GuestRootPath);

        struct stat sourceStatus;
        struct stat targetStatus;
        BOOL copy = YES;
        if (stat(source, &sourceStatus) == 0) {
            if (stat(target, &targetStatus) == 0 &&
                targetStatus.st_size == sourceStatus.st_size) {
                copy = NO;
            }
            if (copy) {
                GuestCopyHostFile(source, target);
            }
        }

        snprintf(target, sizeof(target), "%s/bin", GuestRootPath);
        GuestCreateAppletLinks(target, "busybox");
        snprintf(target, sizeof(target), "%s/usr/bin", GuestRootPath);
        GuestCreateAppletLinks(target, "../../bin/busybox");

        snprintf(source, sizeof(source), "%s/alpine-apk", executable);
        snprintf(target, sizeof(target), "%s/sbin/apk", GuestRootPath);
        struct stat apkStatus;
        if (stat(target, &apkStatus) != 0 ||
            apkStatus.st_size == 0) {
            GuestCopyHostFile(source, target);
        } else {
            struct stat sourceApkStatus;
            if (stat(source, &sourceApkStatus) == 0 &&
                sourceApkStatus.st_size != apkStatus.st_size) {
                GuestCopyHostFile(source, target);
            }
        }
        snprintf(target, sizeof(target), "%s/sbin/apk", GuestRootPath);
        chmod(target, 0755);

        /* Test package for `apk add --allow-untrusted /tmp/hello.apk`. */
        snprintf(source, sizeof(source), "%s/hello.apk", executable);
        struct stat helloSource;
        if (stat(source, &helloSource) == 0) {
            snprintf(target, sizeof(target), "%s/tmp/hello.apk", GuestRootPath);
            GuestCopyHostFile(source, target);
            chmod(target, 0644);
        }

        GuestInstallAlpineRuntime([NSString stringWithUTF8String:executable]);

        snprintf(GuestAlpineLibPath,
                 sizeof(GuestAlpineLibPath),
                 "%s/alpine/lib",
                 executable);
        struct stat alpineStatus;
        GuestLog("[guest] alpine libs=%s exists=%d\n",
                 GuestAlpineLibPath,
                 stat(GuestAlpineLibPath, &alpineStatus) == 0 ? 1 : 0);
    }

    GuestLog( "[guest] rootfs=%s\n", GuestRootPath);
}

static BOOL GuestDevicePath(const char *guestPath, char *buffer, size_t size)
{
    static const char *mappings[][2] = {
        { "/dev/null", "/dev/null" },
        { "/dev/zero", "/dev/zero" },
        { "/dev/random", "/dev/urandom" },
        { "/dev/urandom", "/dev/urandom" },
        { "/dev/full", "/dev/null" },
    };
    for (size_t index = 0;
         index < sizeof(mappings) / sizeof(mappings[0]);
         index++) {
        if (strcmp(guestPath, mappings[index][0]) != 0) {
            continue;
        }
        int written = snprintf(buffer, size, "%s", mappings[index][1]);
        return written > 0 && (size_t)written < size;
    }
    return NO;
}

static const char *GuestTranslatePath(int dirfd,
                                      const char *guestPath,
                                      char *buffer,
                                      size_t size)
{
    if (guestPath == NULL || guestPath[0] == 0) {
        return NULL;
    }
    if (GuestDevicePath(guestPath, buffer, size)) {
        return buffer;
    }
    if (guestPath[0] == '/') {
        int written = snprintf(buffer, size, "%s%s", GuestRootPath, guestPath);
        if (written <= 0 || (size_t)written >= size) {
            return NULL;
        }
        /*
         * Copying the Alpine runtime into rootfs is best-effort.  If a
         * library is missing there, serve it straight from the app bundle
         * instead of failing the dynamic link.
         */
        if (GuestAlpineLibPath[0] != '\0' &&
            (strncmp(guestPath, "/lib/", 5) == 0 ||
             strncmp(guestPath, "/usr/lib/", 9) == 0)) {
            struct stat status;
            if (stat(buffer, &status) != 0) {
                const char *name = strrchr(guestPath, '/');
                name = name != NULL ? name + 1 : guestPath;
                if (strstr(name, ".so") == NULL) {
                    return buffer;
                }
                written = snprintf(buffer,
                                   size,
                                   "%s/%s",
                                   GuestAlpineLibPath,
                                   name);
                if (written <= 0 || (size_t)written >= size) {
                    return NULL;
                }
            }
        }
        return buffer;
    }
    if (dirfd >= 0) {
        char host[PATH_MAX];
        if (fcntl(dirfd, GUEST_F_GETPATH, host) != 0) {
            return NULL;
        }
        int written = snprintf(buffer, size, "%s/%s", host, guestPath);
        return written > 0 && (size_t)written < size ? buffer : NULL;
    }
    if (dirfd != GUEST_AT_FDCWD) {
        return NULL;
    }
    int written = snprintf(buffer,
                           size,
                           "%s%s/%s",
                           GuestRootPath,
                           strcmp(GuestCwd, "/") == 0 ? "" : GuestCwd,
                           guestPath);
    return written > 0 && (size_t)written < size ? buffer : NULL;
}

static int GuestToHostOpenFlags(uint64_t flags)
{
    int result = -1;
    switch (flags & 3) {
    case 0:
        result = O_RDONLY;
        break;
    case 1:
        result = O_WRONLY;
        break;
    case 2:
        result = O_RDWR;
        break;
    default:
        return -1;
    }
    if (flags & 0x40) result |= O_CREAT;
    if (flags & 0x80) result |= O_EXCL;
    if (flags & 0x100) result |= O_NOCTTY;
    if (flags & 0x200) result |= O_TRUNC;
    if (flags & 0x400) result |= O_APPEND;
    if (flags & 0x800) result |= O_NONBLOCK;
    if (flags & 0x1000) result |= O_DSYNC;
    if (flags & 0x100000) {
        result &= ~O_DSYNC;
        result |= O_SYNC;
    }
    /*
     * aarch64 Linux values (musl arch/aarch64/bits/fcntl.h):
     *   0x4000 O_DIRECTORY, 0x8000 O_NOFOLLOW, 0x20000 O_LARGEFILE.
     * musl's openat() always ORs O_LARGEFILE into the flags, so treating
     * 0x20000 as O_NOFOLLOW made every open reject symlinks with ELOOP.
     */
    if (flags & 0x4000) result |= O_DIRECTORY;
    if (flags & 0x8000) result |= O_NOFOLLOW;
    /* 0x20000 O_LARGEFILE: meaningless on Darwin. */
    if (flags & 0x80000) result |= O_CLOEXEC;
    return result;
}

static uint64_t GuestFromHostOpenFlags(int flags)
{
    uint64_t result = 0;
    switch (flags & O_ACCMODE) {
    case O_WRONLY:
        result = 1;
        break;
    case O_RDWR:
        result = 2;
        break;
    default:
        break;
    }
    if (flags & O_CREAT) result |= 0x40;
    if (flags & O_EXCL) result |= 0x80;
    if (flags & O_TRUNC) result |= 0x200;
    if (flags & O_APPEND) result |= 0x400;
    if (flags & O_NONBLOCK) result |= 0x800;
    if (flags & O_DSYNC) result |= 0x1000;
    if (flags & O_SYNC) result |= 0x100000;
    if (flags & O_DIRECTORY) result |= 0x4000;
    if (flags & O_NOFOLLOW) result |= 0x8000;
    if (flags & O_CLOEXEC) result |= 0x80000;
    /* Linux reports O_LARGEFILE on F_GETFL; musl expects it. */
    result |= 0x20000;
    return result;
}

static void GuestFillStat(const struct stat *source, void *destination)
{
    uint8_t *bytes = (uint8_t *)destination;
    memset(bytes, 0, 128);
    *(uint64_t *)(bytes + 0) = (uint64_t)source->st_dev;
    *(uint64_t *)(bytes + 8) = (uint64_t)source->st_ino;
    *(uint32_t *)(bytes + 16) = (uint32_t)source->st_mode;
    *(uint32_t *)(bytes + 20) = (uint32_t)source->st_nlink;
    *(uint32_t *)(bytes + 24) = (uint32_t)source->st_uid;
    *(uint32_t *)(bytes + 28) = (uint32_t)source->st_gid;
    *(uint64_t *)(bytes + 32) = (uint64_t)source->st_rdev;
    *(uint64_t *)(bytes + 48) = (uint64_t)source->st_size;
    *(uint32_t *)(bytes + 56) = (uint32_t)source->st_blksize;
    *(uint64_t *)(bytes + 64) = (uint64_t)source->st_blocks;
    *(uint64_t *)(bytes + 72) = (uint64_t)source->st_atimespec.tv_sec;
    *(uint64_t *)(bytes + 80) = (uint64_t)source->st_atimespec.tv_nsec;
    *(uint64_t *)(bytes + 88) = (uint64_t)source->st_mtimespec.tv_sec;
    *(uint64_t *)(bytes + 96) = (uint64_t)source->st_mtimespec.tv_nsec;
    *(uint64_t *)(bytes + 104) = (uint64_t)source->st_ctimespec.tv_sec;
    *(uint64_t *)(bytes + 112) = (uint64_t)source->st_ctimespec.tv_nsec;
}

/*
 * Linux arm64 struct statfs (120 bytes).  Darwin's struct statfs has a
 * completely different layout, so apk (free-space checks) would read junk
 * if we passed it through.
 */
static void GuestFillStatfs(const struct statfs *source, void *destination)
{
    uint8_t *bytes = (uint8_t *)destination;
    memset(bytes, 0, 120);
    *(uint64_t *)(bytes + 0) = 0xEF53; /* looks like a normal writable FS */
    *(uint64_t *)(bytes + 8) = (uint64_t)source->f_bsize;
    *(uint64_t *)(bytes + 16) = (uint64_t)source->f_blocks;
    *(uint64_t *)(bytes + 24) = (uint64_t)source->f_bfree;
    *(uint64_t *)(bytes + 32) = (uint64_t)source->f_bavail;
    *(uint64_t *)(bytes + 40) = (uint64_t)source->f_files;
    *(uint64_t *)(bytes + 48) = (uint64_t)source->f_ffree;
    *(uint64_t *)(bytes + 64) = 255; /* f_namelen */
    *(uint64_t *)(bytes + 72) = (uint64_t)source->f_bsize; /* f_frsize */
}

/*
 * getdents64 is served through a per-fd DIR cache: Darwin has no
 * getdirentries64 equivalent we can rely on, but readdir() gives the same
 * entries plus d_seekoff/d_type.  One entry may not fit into the guest
 * buffer, so it is stashed and returned by the next call.
 */
typedef struct {
    int fd;
    int valid;
    DIR *directory;
    uint64_t pendingInode;
    int64_t pendingOffset;
    uint8_t pendingType;
    char pendingName[256];
    int pendingValid;
} GuestDirCache;

static GuestDirCache GuestDirCaches[8];

static GuestDirCache *GuestDirCacheFor(int fd, BOOL create)
{
    for (size_t index = 0; index < 8; index++) {
        if (GuestDirCaches[index].valid && GuestDirCaches[index].fd == fd) {
            return &GuestDirCaches[index];
        }
    }
    if (!create) {
        return NULL;
    }
    for (size_t index = 0; index < 8; index++) {
        if (GuestDirCaches[index].valid) {
            continue;
        }
        int duplicate = dup(fd);
        if (duplicate < 0) {
            return NULL;
        }
        DIR *directory = fdopendir(duplicate);
        if (directory == NULL) {
            close(duplicate);
            return NULL;
        }
        GuestDirCaches[index].fd = fd;
        GuestDirCaches[index].valid = 1;
        GuestDirCaches[index].directory = directory;
        GuestDirCaches[index].pendingValid = 0;
        return &GuestDirCaches[index];
    }
    return NULL;
}

static void GuestDirCacheDrop(int fd)
{
    for (size_t index = 0; index < 8; index++) {
        GuestDirCache *cache = &GuestDirCaches[index];
        if (!cache->valid || cache->fd != fd) {
            continue;
        }
        closedir(cache->directory);
        memset(cache, 0, sizeof(*cache));
    }
}

static void GuestDirCacheRewind(int fd)
{
    GuestDirCache *cache = GuestDirCacheFor(fd, NO);
    if (cache == NULL) {
        return;
    }
    rewinddir(cache->directory);
    cache->pendingValid = 0;
}

static BOOL GuestDirCacheNext(GuestDirCache *cache)
{
    if (cache->pendingValid) {
        return YES;
    }
    struct dirent *entry = readdir(cache->directory);
    if (entry == NULL) {
        return NO;
    }
    cache->pendingInode = (uint64_t)entry->d_ino;
    cache->pendingOffset = (int64_t)entry->d_seekoff;
    cache->pendingType = (uint8_t)entry->d_type;
    size_t length = entry->d_namlen;
    if (length >= sizeof(cache->pendingName)) {
        length = sizeof(cache->pendingName) - 1;
    }
    memcpy(cache->pendingName, entry->d_name, length);
    cache->pendingName[length] = 0;
    cache->pendingValid = 1;
    return YES;
}

static uint64_t GuestGetDents64(int fd, void *buffer, uint64_t count)
{
    GuestDirCache *cache = GuestDirCacheFor(fd, YES);
    if (cache == NULL) {
        return (uint64_t)(-EBADF);
    }
    uint8_t *output = (uint8_t *)buffer;
    uint64_t written = 0;
    while (GuestDirCacheNext(cache)) {
        size_t nameLength = strlen(cache->pendingName);
        uint64_t recordSize = (19 + nameLength + 1 + 7) & ~7ULL;
        if (written + recordSize > count) {
            if (written == 0) {
                return (uint64_t)(-EINVAL);
            }
            break;
        }
        *(uint64_t *)(output + written) = cache->pendingInode;
        *(int64_t *)(output + written + 8) = cache->pendingOffset;
        *(uint16_t *)(output + written + 16) = (uint16_t)recordSize;
        output[written + 18] = cache->pendingType;
        memcpy(output + written + 19, cache->pendingName, nameLength + 1);
        written += recordSize;
        cache->pendingValid = 0;
    }
    return written;
}

#pragma mark - Guest network

#define GUEST_SOCK_CLOEXEC 0x80000
#define GUEST_SOCK_NONBLOCK 0x800

#define GUEST_SOL_SOCKET 1
#define GUEST_AF_UNIX 1
#define GUEST_AF_INET 2
#define GUEST_AF_INET6 10

/*
 * Linux msghdr is 56 bytes: name, namelen(4)+pad, iov, iovlen(8),
 * control, controllen(8), flags(4)+pad.  Darwin uses int/socklen_t for
 * the two lengths and is 48 bytes, so the header is rebuilt field by
 * field instead of passed straight through.
 */
typedef struct {
    void *name;
    uint32_t nameLength;
    uint32_t namePadding;
    void *iov;
    uint64_t iovLength;
    void *control;
    uint64_t controlLength;
    int32_t flags;
    uint32_t flagsPadding;
} GuestMessageHeader;

static int GuestToHostSocketFamily(int family)
{
    switch (family) {
    case GUEST_AF_UNIX:
        return AF_UNIX;
    case GUEST_AF_INET:
        return AF_INET;
    case GUEST_AF_INET6:
        /* Linux AF_INET6 is 10, Darwin AF_INET6 is 30. */
        return AF_INET6;
    default:
        return -1;
    }
}

static int GuestFromHostSocketFamily(int family)
{
    switch (family) {
    case AF_UNIX:
        return GUEST_AF_UNIX;
    case AF_INET:
        return GUEST_AF_INET;
    case AF_INET6:
        return GUEST_AF_INET6;
    default:
        return 0;
    }
}

/*
 * MSG_NOSIGNAL does not exist on Darwin (0x4000 there means MSG_RCVMORE),
 * so it is stripped from guest flags and replaced by SO_NOSIGPIPE on every
 * socket we hand out.  MSG_DONTWAIT and MSG_WAITALL also have different
 * numeric values on the two kernels.
 */
static int GuestConfigureSocket(int descriptor, int flags)
{
    if (descriptor < 0) {
        return descriptor;
    }
    int enabled = 1;
    setsockopt(descriptor,
               SOL_SOCKET,
               SO_NOSIGPIPE,
               &enabled,
               (socklen_t)sizeof(enabled));
    if (flags & GUEST_SOCK_NONBLOCK) {
        int current = fcntl(descriptor, F_GETFL);
        if (current >= 0) {
            fcntl(descriptor, F_SETFL, current | O_NONBLOCK);
        }
    }
    if (flags & GUEST_SOCK_CLOEXEC) {
        int current = fcntl(descriptor, F_GETFD);
        if (current >= 0) {
            fcntl(descriptor, F_SETFD, current | FD_CLOEXEC);
        }
    }
    return descriptor;
}

static int GuestToHostMessageFlags(int flags)
{
    int result = 0;
    if (flags & 0x0001) result |= MSG_OOB;
    if (flags & 0x0002) result |= MSG_PEEK;
    if (flags & 0x0004) result |= MSG_DONTROUTE;
    if (flags & 0x0008) result |= MSG_CTRUNC;
    if (flags & 0x0020) result |= MSG_TRUNC;
#ifdef MSG_DONTWAIT
    if (flags & 0x0040) result |= MSG_DONTWAIT;
#endif
    if (flags & 0x0080) result |= MSG_EOR;
    if (flags & 0x0100) result |= MSG_WAITALL;
    /* 0x4000 (MSG_NOSIGNAL) and 0x40000000 (MSG_CMSG_CLOEXEC) dropped. */
    return result;
}

static int GuestFromHostMessageFlags(int flags)
{
    int result = 0;
    if (flags & MSG_OOB) result |= 0x0001;
    if (flags & MSG_PEEK) result |= 0x0002;
    if (flags & MSG_DONTROUTE) result |= 0x0004;
    if (flags & MSG_CTRUNC) result |= 0x0008;
    if (flags & MSG_TRUNC) result |= 0x0020;
#ifdef MSG_DONTWAIT
    if (flags & MSG_DONTWAIT) result |= 0x0040;
#endif
    if (flags & MSG_EOR) result |= 0x0080;
    if (flags & MSG_WAITALL) result |= 0x0100;
    return result;
}

static short GuestToHostPollEvents(short events)
{
    short result = 0;
    if (events & 0x0001) result |= POLLIN;
    if (events & 0x0002) result |= POLLPRI;
    if (events & 0x0004) result |= POLLOUT;
    if (events & 0x0008) result |= POLLERR;
    if (events & 0x0010) result |= POLLHUP;
    if (events & 0x0020) result |= POLLNVAL;
#ifdef POLLRDNORM
    if (events & 0x0040) result |= POLLRDNORM;
#endif
#ifdef POLLRDBAND
    if (events & 0x0080) result |= POLLRDBAND;
#endif
#ifdef POLLWRNORM
    if (events & 0x0100) result |= POLLWRNORM;
#endif
#ifdef POLLWRBAND
    if (events & 0x0200) result |= POLLWRBAND;
#endif
    return result;
}

static short GuestFromHostPollEvents(short events)
{
    short result = 0;
    if (events & POLLIN) result |= 0x0001;
    if (events & POLLPRI) result |= 0x0002;
    if (events & POLLOUT) result |= 0x0004;
    if (events & POLLERR) result |= 0x0008;
    if (events & POLLHUP) result |= 0x0010;
    if (events & POLLNVAL) result |= 0x0020;
#ifdef POLLRDNORM
    if (events & POLLRDNORM) result |= 0x0040;
#endif
#ifdef POLLRDBAND
    if (events & POLLRDBAND) result |= 0x0080;
#endif
#ifdef POLLWRNORM
    if (events & POLLWRNORM) result |= 0x0100;
#endif
#ifdef POLLWRBAND
    if (events & POLLWRBAND) result |= 0x0200;
#endif
    return result;
}

static int GuestToHostSocketOption(int level, int option)
{
    if (level != GUEST_SOL_SOCKET) {
        return option;
    }
    switch (option) {
    case 1: return SO_DEBUG;
    case 2: return SO_REUSEADDR;
    case 3: return SO_TYPE;
    case 4: return SO_ERROR;
    case 5: return SO_DONTROUTE;
    case 6: return SO_BROADCAST;
    case 7: return SO_SNDBUF;
    case 8: return SO_RCVBUF;
    case 9: return SO_KEEPALIVE;
    case 10: return SO_OOBINLINE;
    case 13: return SO_LINGER;
    case 15: return SO_REUSEPORT;
    case 18: return SO_RCVLOWAT;
    case 19: return SO_SNDLOWAT;
    case 20: return SO_RCVTIMEO;
    case 21: return SO_SNDTIMEO;
    case 30: return SO_ACCEPTCONN;
    default:
        return -1;
    }
}

static const char *GuestFromHostUnixPath(const char *hostPath,
                                         char *buffer,
                                         size_t size)
{
    size_t rootLength = strlen(GuestRootPath);
    if (rootLength != 0 &&
        strncmp(hostPath, GuestRootPath, rootLength) == 0 &&
        (hostPath[rootLength] == '/' || hostPath[rootLength] == 0)) {
        const char *relative = hostPath + rootLength;
        int written = snprintf(buffer,
                               size,
                               "%s",
                               relative[0] == 0 ? "/" : relative);
        if (written > 0 && (size_t)written < size) {
            return buffer;
        }
    }
    return hostPath;
}

/*
 * Linux sockaddr has a 16-bit sa_family at offset 0.  Darwin has sa_len
 * at 0 and an 8-bit sa_family at 1.  Port/flowinfo/address fields sit at
 * the same offsets on both sides, so only the first two bytes and the
 * total length need fixing.
 */
static int GuestToHostSockaddr(const void *guestAddress,
                               uint32_t guestLength,
                               struct sockaddr_storage *storage,
                               socklen_t *hostLength)
{
    if (guestAddress == NULL || guestLength < 2) {
        return -EINVAL;
    }
    uint16_t family = *(const uint16_t *)guestAddress;
    memset(storage, 0, sizeof(*storage));

    if (family == GUEST_AF_INET) {
        if (guestLength < 16) {
            return -EINVAL;
        }
        struct sockaddr_in *output = (struct sockaddr_in *)storage;
        output->sin_len = (uint8_t)sizeof(struct sockaddr_in);
        output->sin_family = AF_INET;
        memcpy(&output->sin_port, (const uint8_t *)guestAddress + 2, 2);
        memcpy(&output->sin_addr, (const uint8_t *)guestAddress + 4, 4);
        *hostLength = (socklen_t)sizeof(struct sockaddr_in);
        return 0;
    }

    if (family == GUEST_AF_INET6) {
        if (guestLength < 28) {
            return -EINVAL;
        }
        struct sockaddr_in6 *output = (struct sockaddr_in6 *)storage;
        output->sin6_len = (uint8_t)sizeof(struct sockaddr_in6);
        output->sin6_family = AF_INET6;
        memcpy(&output->sin6_port, (const uint8_t *)guestAddress + 2, 2);
        memcpy(&output->sin6_flowinfo, (const uint8_t *)guestAddress + 4, 4);
        memcpy(&output->sin6_addr, (const uint8_t *)guestAddress + 8, 16);
        memcpy(&output->sin6_scope_id, (const uint8_t *)guestAddress + 24, 4);
        *hostLength = (socklen_t)sizeof(struct sockaddr_in6);
        return 0;
    }

    if (family == GUEST_AF_UNIX) {
        const char *guestPath = (const char *)guestAddress + 2;
        size_t guestPathLength = (size_t)guestLength - 2;
        if (guestPathLength > 0 && guestPath[0] == 0) {
            /* Darwin has no abstract Unix sockets. */
            return GuestErrorCode(EOPNOTSUPP);
        }
        char relative[GUEST_ROOT_MAX];
        if (guestPathLength >= sizeof(relative)) {
            return GuestErrorCode(ENAMETOOLONG);
        }
        memcpy(relative, guestPath, guestPathLength);
        relative[guestPathLength] = 0;

        char hostPath[PATH_MAX];
        const char *translated = GuestTranslatePath(GUEST_AT_FDCWD,
                                                    relative,
                                                    hostPath,
                                                    sizeof(hostPath));
        if (translated == NULL) {
            return GuestErrorCode(ENAMETOOLONG);
        }
        size_t translatedLength = strlen(translated);
        struct sockaddr_un *output = (struct sockaddr_un *)storage;
        if (translatedLength > sizeof(output->sun_path) - 1) {
            return GuestErrorCode(ENAMETOOLONG);
        }
        memcpy(output->sun_path, translated, translatedLength + 1);
        output->sun_family = AF_UNIX;
        output->sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) +
                                    translatedLength + 1);
        *hostLength = (socklen_t)output->sun_len;
        return 0;
    }

    return GuestErrorCode(EAFNOSUPPORT);
}

static uint32_t GuestFromHostSockaddr(const struct sockaddr *address,
                                      socklen_t addressLength,
                                      void *guestAddress,
                                      uint32_t guestCapacity)
{
    if (guestAddress == NULL || guestCapacity < 2 || address == NULL) {
        return 0;
    }
    uint8_t *output = (uint8_t *)guestAddress;
    int family = GuestFromHostSocketFamily(address->sa_family);
    uint32_t length = 2;

    if (family == GUEST_AF_INET && addressLength >= 16) {
        length = 16;
        memcpy(output + 2, (const uint8_t *)address + 2, 14);
    } else if (family == GUEST_AF_INET6 && addressLength >= 28) {
        length = 28;
        memcpy(output + 2, (const uint8_t *)address + 2, 26);
    } else if (family == GUEST_AF_UNIX) {
        const struct sockaddr_un *unixAddress =
            (const struct sockaddr_un *)address;
        char relative[GUEST_ROOT_MAX];
        const char *guestPath = GuestFromHostUnixPath(unixAddress->sun_path,
                                                      relative,
                                                      sizeof(relative));
        size_t guestPathLength = strnlen(guestPath,
                                         sizeof(unixAddress->sun_path));
        if (guestPathLength > sizeof(unixAddress->sun_path)) {
            guestPathLength = sizeof(unixAddress->sun_path);
        }
        if (2 + guestPathLength > guestCapacity) {
            guestPathLength = guestCapacity - 2;
        }
        length = 2 + (uint32_t)guestPathLength;
        if (length > 2) {
            memcpy(output + 2, guestPath, guestPathLength);
        }
    } else {
        family = 0;
    }

    if (length > guestCapacity) {
        length = guestCapacity;
    }
    *(uint16_t *)output = (uint16_t)family;
    return length;
}

static int GuestTimeoutToMilliseconds(const struct timespec *timeout)
{
    if (timeout == NULL) {
        return -1;
    }
    if (timeout->tv_sec < 0 || timeout->tv_nsec < 0) {
        return 0;
    }
    int64_t milliseconds = (int64_t)timeout->tv_sec * 1000 +
        ((int64_t)timeout->tv_nsec + 999999) / 1000000;
    if (milliseconds > INT_MAX) {
        milliseconds = INT_MAX;
    }
    return (int)milliseconds;
}

static uint64_t GuestHandlePoll(uint64_t descriptorPointer,
                                uint64_t descriptorCount,
                                int timeoutMilliseconds)
{
    if (descriptorCount > 1024) {
        return (uint64_t)(-EINVAL);
    }
    struct pollfd *descriptors = (struct pollfd *)(uintptr_t)descriptorPointer;
    if (descriptorCount != 0 && descriptors == NULL) {
        return (uint64_t)(-EFAULT);
    }
    for (uint64_t index = 0; index < descriptorCount; index++) {
        descriptors[index].events =
            GuestToHostPollEvents(descriptors[index].events);
        descriptors[index].revents = 0;
    }
    int result = poll(descriptors, (nfds_t)descriptorCount, timeoutMilliseconds);
    int error = errno;
    for (uint64_t index = 0; index < descriptorCount; index++) {
        descriptors[index].events =
            GuestFromHostPollEvents(descriptors[index].events);
        descriptors[index].revents =
            GuestFromHostPollEvents(descriptors[index].revents);
    }
    if (result < 0) {
        errno = error;
        return GuestErrno();
    }
    return (uint64_t)result;
}

#pragma mark - Syscalls

static uint32_t GuestSyscallCounts[512];
static uint32_t GuestSyscallErrorCounts[512];
static int64_t GuestSyscallLastErrors[512];

/*
 * Socket accounting.  0.38.7 showed that apk's index download fails after a
 * random amount of data, so we need to know whether the TLS socket actually
 * delivered the whole file.  Counts are per guest fd and dumped at exit.
 */
#define GUEST_SOCKET_TRACK 64
typedef struct {
    int fd;
    uint64_t readBytes;
    uint64_t writeBytes;
} GuestSocketStats;

static GuestSocketStats GuestSocketTable[GUEST_SOCKET_TRACK];
static int GuestSocketTableCount = 0;

static GuestSocketStats *GuestSocketEntry(int fd, BOOL create)
{
    for (int index = 0; index < GuestSocketTableCount; index++) {
        if (GuestSocketTable[index].fd == fd) {
            return &GuestSocketTable[index];
        }
    }
    if (!create || GuestSocketTableCount >= GUEST_SOCKET_TRACK) {
        return NULL;
    }
    GuestSocketStats *entry = &GuestSocketTable[GuestSocketTableCount++];
    entry->fd = fd;
    entry->readBytes = 0;
    entry->writeBytes = 0;
    return entry;
}

static void GuestTrackSocket(int fd)
{
    (void)GuestSocketEntry(fd, YES);
}

static void GuestDropSocket(int fd)
{
    for (int index = 0; index < GuestSocketTableCount; index++) {
        if (GuestSocketTable[index].fd != fd) {
            continue;
        }
        /* Log now: apk closes the TLS socket long before it exits. */
        GuestLog("[guest] sock fd=%d closed read=%llu write=%llu\n",
                 fd,
                 (unsigned long long)GuestSocketTable[index].readBytes,
                 (unsigned long long)GuestSocketTable[index].writeBytes);
        GuestSocketTable[index] = GuestSocketTable[GuestSocketTableCount - 1];
        GuestSocketTableCount--;
        return;
    }
}

static void GuestAccountSocket(int fd, ssize_t bytes, BOOL writing)
{
    if (bytes <= 0) {
        return;
    }
    GuestSocketStats *entry = GuestSocketEntry(fd, NO);
    if (entry == NULL) {
        return;
    }
    if (writing) {
        entry->writeBytes += (uint64_t)bytes;
    } else {
        entry->readBytes += (uint64_t)bytes;
    }
}

static unsigned int GuestReadTraceCount = 0;

/*
 * The index parser keeps failing with a zlib data error even though the
 * bytes on disk (and on the wire) are correct, and the failure point moves
 * between runs.  That means live guest memory is being modified.  These two
 * probes catch exactly that:
 *
 *  - a canary in the 16KB host-page slack of every large anonymous mapping
 *    (the guest must never touch past the length it asked for), and
 *  - an FNV hash of every large read buffer, re-checked before the next
 *    fill of the same buffer, so a write into apk's 128KB istream buffer
 *    shows up with the offset of the first changed word.
 */
#define GUEST_CANARY_SLOTS 64
/*
 * anonymous-mmap size histogram
 *
 * The 0.39.3 run showed 1426 mmaps and 1413 munmaps for one `apk update',
 * with brk never growing past 0x10000 of the 64MB heap.  Everything therefore
 * lives in mmap-backed mallocng groups, and the group geometry (slot count
 * per mapping) depends on the page size musl was told: at 16KB, mallocng's
 * "size*cnt + UNIT > pagesize/2" test packs two 7KB objects into one mapping,
 * while at 4KB each of them gets its own.  That is exactly the neighbourhood
 * of zlib's inflate_state, so the distribution is worth logging.
 */
#define GUEST_MMAP_HISTOGRAM_BUCKETS 8
static unsigned int GuestMmapHistogram[GUEST_MMAP_HISTOGRAM_BUCKETS];
static unsigned int GuestMmapFixedRejected;
static unsigned int GuestMmapFixedBelowBrk;

static void GuestRecordMmapSize(size_t requested)
{
    unsigned int bucket = 0;
    size_t limit = 4096;
    while (bucket + 1 < GUEST_MMAP_HISTOGRAM_BUCKETS && requested > limit) {
        bucket++;
        limit <<= 1;
    }
    GuestMmapHistogram[bucket]++;
}

static void GuestLogMmapHistogram(void)
{
    static const char *labels[GUEST_MMAP_HISTOGRAM_BUCKETS] = {
        "<=4K", "<=8K", "<=16K", "<=32K", "<=64K", "<=128K", "<=256K", ">256K"
    };
    GuestLog("[guest] mmap hist:");
    for (int index = 0; index < GUEST_MMAP_HISTOGRAM_BUCKETS; index++) {
        GuestLog(" %s=%u", labels[index], GuestMmapHistogram[index]);
    }
    GuestLog("  fixed-rejected=%u fixed-below-brk=%u\n",
             GuestMmapFixedRejected,
             GuestMmapFixedBelowBrk);
}
/*
 * Page size reported to the guest in AT_PAGESZ.  Darwin behaves like a
 * 16KB-page kernel, and advertising 16KB makes musl/mallocng round every
 * mmap/munmap to the same granularity, which removes the 4KB/16KB mismatch
 * that produced the record leak and (suspected) the stray-write corruption.
 * Asahi Linux runs Alpine on 16KB pages, so this is a supported musl
 * configuration.
 */
#ifndef GUEST_TARGET_PAGE_SIZE
#define GUEST_TARGET_PAGE_SIZE 0x4000ULL
#endif

typedef struct {
    uintptr_t address;
    size_t requested;
    size_t mapLength;
    int valid;
} GuestCanary;

static GuestCanary GuestCanaries[GUEST_CANARY_SLOTS];
static uint64_t GuestCanaryMagic = 0x4C50524F42454E43ULL; /* "LPROBENC" */

static void GuestCanaryReport(const char *what, uintptr_t address, size_t requested)
{
    GuestLog("[guest] %s addr=0x%lx requested=0x%lx\n",
             what,
             (unsigned long)address,
             (unsigned long)requested);
}

/*
 * mallocng tracks the size of an individually-mmapped block in 4KB units
 * (`g->maplen = (needed+4095)/4096`, and `alloc_group` always rounds
 * `needed` up to the page size), so `align4k(requested)` is exactly one
 * byte past everything it can write even when the guest page size is 16KB.
 */
static uintptr_t GuestCanarySlot(uintptr_t address, size_t requested)
{
    size_t used = (requested + 4095) & ~(size_t)4095;
    return (address + used + 7) & ~(uintptr_t)7;
}

static void GuestCanaryPlace(uintptr_t address, size_t requested, size_t mapLength)
{
    /*
     * 0.39.3 only armed this for mappings of 64KB or more, which excluded the
     * two objects that actually matter: zlib's inflate_state (~7.2KB) and its
     * 32KB window.  Arm every mapping that still has a 4K-aligned slot inside
     * the host mapping; when `requested' is already 16KB-aligned the slot
     * coincides with the guard page and is skipped by the check below.
     */
    if (requested < 4096) {
        return;
    }
    uintptr_t slot = GuestCanarySlot(address, requested);
    if (slot + 8 > address + mapLength) {
        return;
    }
    for (int index = 0; index < GUEST_CANARY_SLOTS; index++) {
        if (GuestCanaries[index].valid &&
            GuestCanaries[index].address == address) {
            return;
        }
    }
    for (int index = 0; index < GUEST_CANARY_SLOTS; index++) {
        if (GuestCanaries[index].valid) {
            continue;
        }
        *(uint64_t *)slot = GuestCanaryMagic;
        GuestCanaries[index].address = address;
        GuestCanaries[index].requested = requested;
        GuestCanaries[index].mapLength = mapLength;
        GuestCanaries[index].valid = 1;
        return;
    }
}

static void GuestCanaryCheck(uintptr_t address)
{
    for (int index = 0; index < GUEST_CANARY_SLOTS; index++) {
        if (!GuestCanaries[index].valid ||
            GuestCanaries[index].address != address) {
            continue;
        }
        uintptr_t slot = GuestCanarySlot(address, GuestCanaries[index].requested);
        if (*(uint64_t *)slot != GuestCanaryMagic) {
            GuestCanaryReport("mmap slack overwritten at",
                              address,
                              GuestCanaries[index].requested);
        }
        GuestCanaries[index].valid = 0;
        return;
    }
}

static void GuestCanaryCheckAll(void)
{
    for (int index = 0; index < GUEST_CANARY_SLOTS; index++) {
        if (!GuestCanaries[index].valid) {
            continue;
        }
        uintptr_t address = GuestCanaries[index].address;
        uintptr_t slot = GuestCanarySlot(address, GuestCanaries[index].requested);
        if (*(uint64_t *)slot != GuestCanaryMagic) {
            GuestCanaryReport("mmap slack overwritten at",
                              address,
                              GuestCanaries[index].requested);
        }
        GuestCanaries[index].valid = 0;
    }
}

#define GUEST_READ_GUARD_SLOTS 8
#define GUEST_READ_GUARD_PAGES 32 /* 128KB / 4KB */
typedef struct {
    int fd;
    uintptr_t address;
    size_t length;
    int pageCount;
    uint64_t pageHash[GUEST_READ_GUARD_PAGES];
    int valid;
    off_t nextOffset;
    int offsetValid;
} GuestReadGuard;

static GuestReadGuard GuestReadGuards[GUEST_READ_GUARD_SLOTS];
static unsigned char *GuestReadVerifyBuffer = NULL;

static uint64_t GuestFastHash(const void *data, size_t length)
{
    const uint8_t *bytes = (const uint8_t *)data;
    uint64_t hash = 1469598103934665603ULL;
    size_t words = length / 8;
    for (size_t index = 0; index < words; index++) {
        uint64_t word = 0;
        memcpy(&word, bytes + index * 8, 8);
        hash ^= word;
        hash *= 1099511628211ULL;
    }
    for (size_t index = words * 8; index < length; index++) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static int GuestReadGuardPages(size_t length)
{
    size_t pages = (length + 4095) / 4096;
    return pages > GUEST_READ_GUARD_PAGES ? GUEST_READ_GUARD_PAGES : (int)pages;
}

static unsigned int GuestReadGuardChecks = 0;
static unsigned int GuestReadGuardChanges = 0;
static unsigned int GuestReadGuardJump = 0;
static unsigned int GuestReadGuardVerified = 0;
static unsigned int GuestReadGuardMismatch = 0;

/*
 * Re-read the same range straight from the file and compare it with what the
 * guest just received.  This is the only check that proves the guest's
 * compressed bytes are the file's bytes: a seek that silently rewinds the
 * index fd, a wrong fd, or a host read that lands in the wrong place all show
 * up here as a mismatch instead of as a mysterious zlib data error.
 */
static void GuestReadGuardVerifyBytes(int fd, uintptr_t address, size_t length,
                                      off_t offset)
{
    if (length < 65536 || length > 131072) {
        return;
    }
    if (GuestReadVerifyBuffer == NULL) {
        GuestReadVerifyBuffer = malloc(131072);
        if (GuestReadVerifyBuffer == NULL) {
            return;
        }
    }
    ssize_t got = pread(fd, GuestReadVerifyBuffer, length, offset);
    if (got != (ssize_t)length) {
        GuestLog("[guest] read verify short fd=%d off=%lld want=0x%lx got=%lld\n",
                 fd,
                 (long long)offset,
                 (unsigned long)length,
                 (long long)got);
        GuestReadGuardMismatch++;
        return;
    }
    GuestReadGuardVerified++;
    if (memcmp(GuestReadVerifyBuffer, (const void *)address, length) == 0) {
        return;
    }
    size_t index = 0;
    while (index < length &&
           GuestReadVerifyBuffer[index] == ((const uint8_t *)address)[index]) {
        index++;
    }
    GuestLog("[guest] read verify MISMATCH fd=%d off=%lld first=0x%lx\n",
             fd,
             (long long)offset,
             (unsigned long)index);
    GuestReadGuardMismatch++;
}

/*
 * Log every page whose contents changed while the buffer was idle.  The
 * page index maps directly onto the offset inside the istream buffer, which
 * is enough to tell whether apk's own stale write or a stray runtime write
 * hit it.
 */
static void GuestReadGuardReport(int fd, uintptr_t address, size_t length,
                                 const uint64_t *expected)
{
    int pages = GuestReadGuardPages(length);
    int changed = 0;
    GuestReadGuardChecks++;
    for (int index = 0; index < pages; index++) {
        size_t offset = (size_t)index * 4096;
        size_t size = length - offset;
        if (size > 4096) {
            size = 4096;
        }
        uint64_t current =
            GuestFastHash((const void *)(address + offset), size);
        if (current == expected[index]) {
            continue;
        }
        if (changed == 0) {
            GuestLog("[guest] read buffer changed fd=%d addr=0x%lx len=0x%lx"
                     " pages=",
                     fd,
                     (unsigned long)address,
                     (unsigned long)length);
        }
        GuestLog(" %d+0x%lx", index, (unsigned long)offset);
        changed++;
    }
    if (changed != 0) {
        GuestLog("\n");
        GuestReadGuardChanges++;
    }
}

static void GuestReadGuardPreRead(int fd, uintptr_t address, size_t length)
{
    (void)length;
    for (int index = 0; index < GUEST_READ_GUARD_SLOTS; index++) {
        GuestReadGuard *guard = &GuestReadGuards[index];
        if (!guard->valid || guard->fd != fd || guard->address != address) {
            continue;
        }
        GuestReadGuardReport(fd,
                             guard->address,
                             guard->length,
                             guard->pageHash);
        guard->valid = 0;
    }
}

static void GuestReadGuardPostRead(int fd, uintptr_t address, size_t length)
{
    if (length < 65536) {
        return;
    }
    GuestReadGuard *slot = NULL;
    int reuse = 0;
    for (int index = 0; index < GUEST_READ_GUARD_SLOTS; index++) {
        GuestReadGuard *guard = &GuestReadGuards[index];
        if (guard->fd != fd) {
            continue;
        }
        if (guard->address == address) {
            /* Same fd and buffer: keep the offset continuity state, even
             * when PreRead already dropped the hash snapshot. */
            slot = guard;
            reuse = 1;
            continue;
        }
        if (!guard->valid) {
            continue;
        }
        /* Switching to a different buffer: check the old one now. */
        GuestReadGuardReport(fd,
                             guard->address,
                             guard->length,
                             guard->pageHash);
        guard->valid = 0;
        guard->offsetValid = 0;
    }
    if (slot == NULL) {
        for (int index = 0; index < GUEST_READ_GUARD_SLOTS; index++) {
            if (!GuestReadGuards[index].valid) {
                slot = &GuestReadGuards[index];
                break;
            }
        }
    }
    if (slot == NULL) {
        return;
    }
    if (!reuse) {
        slot->offsetValid = 0;
    }
    slot->fd = fd;
    slot->address = address;
    slot->length = length;
    slot->pageCount = GuestReadGuardPages(length);
    slot->valid = 1;
    for (int index = 0; index < slot->pageCount; index++) {
        size_t offset = (size_t)index * 4096;
        size_t size = length - offset;
        if (size > 4096) {
            size = 4096;
        }
        slot->pageHash[index] =
            GuestFastHash((const void *)(address + offset), size);
    }

    /* Sockets and pipes do not have file offsets; skip those. */
    off_t current = lseek(fd, 0, SEEK_CUR);
    if (current < 0) {
        slot->offsetValid = 0;
        return;
    }
    off_t start = current - (off_t)length;
    if (slot->offsetValid && slot->nextOffset != start) {
        GuestLog("[guest] read offset jump fd=%d expected=%lld actual=%lld\n",
                 fd,
                 (long long)slot->nextOffset,
                 (long long)start);
        GuestReadGuardJump++;
    }
    slot->nextOffset = current;
    slot->offsetValid = 1;
    GuestReadGuardVerifyBytes(fd, address, length, start);
}

static void GuestReadGuardVerifyAll(void)
{
    for (int index = 0; index < GUEST_READ_GUARD_SLOTS; index++) {
        GuestReadGuard *guard = &GuestReadGuards[index];
        if (!guard->valid) {
            continue;
        }
        GuestReadGuardReport(guard->fd,
                             guard->address,
                             guard->length,
                             guard->pageHash);
        guard->valid = 0;
    }
}

static void GuestReadGuardDrop(int fd)
{
    for (int index = 0; index < GUEST_READ_GUARD_SLOTS; index++) {
        GuestReadGuard *guard = &GuestReadGuards[index];
        if (!guard->valid || guard->fd != fd) {
            continue;
        }
        GuestReadGuardReport(guard->fd,
                             guard->address,
                             guard->length,
                             guard->pageHash);
        guard->valid = 0;
        guard->offsetValid = 0;
    }
}

static void GuestTraceRead(int fd, uint64_t request, ssize_t result, int error)
{
    BOOL socket = GuestSocketEntry(fd, NO) != NULL;
    if (GuestReadTraceCount >= 96) {
        return;
    }
    /*
     * For sockets only the end of the stream matters (EOF or error); for
     * regular files the large reads belong to apk's 128KB index istreams.
     */
    if (socket) {
        if (result > 0) {
            return;
        }
    } else if (result > 0 && request < 65536) {
        return;
    }
    GuestReadTraceCount++;
    if (result < 0) {
        GuestLog("[guest] read fd=%d want=0x%llx error=%d\n",
                 fd,
                 (unsigned long long)request,
                 error);
    } else {
        GuestLog("[guest] read fd=%d want=0x%llx got=%lld%s\n",
                 fd,
                 (unsigned long long)request,
                 (long long)result,
                 result == 0 ? (socket ? " (socket eof)" : " (eof)") : "");
    }
}

static void GuestLogSyscallStats(void)
{
    GuestCanaryCheckAll();
    GuestReadGuardVerifyAll();
    GuestLog("[guest] munmap pages: released=%u kept-shared=%u\n",
             GuestMunmapReleasedPages, GuestMunmapSharedPages);
    GuestLog("[guest] munmap kept=%u (unowned, shared or sub-page)\n",
             GuestMunmapKeptPages);
    GuestLog("[guest] mapping checks=%u unbacked=%u\n",
             GuestMappingChecks, GuestMappingUnbacked);
    GuestLogMmapHistogram();
    GuestLog("[guest] read guard checks=%u changed=%u jumps=%u verified=%u"
             " mismatch=%u\n",
             GuestReadGuardChecks,
             GuestReadGuardChanges,
             GuestReadGuardJump,
             GuestReadGuardVerified,
             GuestReadGuardMismatch);
    for (int index = 0; index < GuestSocketTableCount; index++) {
        GuestLog("[guest] sock fd=%d read=%llu write=%llu\n",
                 GuestSocketTable[index].fd,
                 (unsigned long long)GuestSocketTable[index].readBytes,
                 (unsigned long long)GuestSocketTable[index].writeBytes);
    }
    GuestLog( "[guest] svc totals:");
    for (int number = 0; number < 512; number++) {
        if (GuestSyscallCounts[number] == 0) {
            continue;
        }
        GuestLog( " %d×%u", number, GuestSyscallCounts[number]);
    }
    GuestLog( "\n[guest] svc errors:");
    for (int number = 0; number < 512; number++) {
        if (GuestSyscallErrorCounts[number] == 0) {
            continue;
        }
        GuestLog( " %d×%u(last=%lld)",
                  number,
                  GuestSyscallErrorCounts[number],
                  (long long)GuestSyscallLastErrors[number]);
    }
    GuestLog( "\n");
}

static uint64_t GuestSyscallDispatchInner(uint64_t *args,
                                          uint64_t number,
                                          uint64_t returnAddress)
{
    static unsigned int traceCount = 0;
    if (traceCount < 40) {
        traceCount++;
        GuestLog(
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
        GuestLog( "[guest] site code:");
        for (int index = -3; index <= 1; index++) {
            GuestLog( " %08x", site[index]);
        }
        GuestLog( "\n");
    }

    switch (number) {
    case 64: { /* write */
        ssize_t result = write((int)args[0],
                               (const void *)args[1],
                               (size_t)args[2]);
        if (result < 0) {
            int error = errno;
            if (GuestSocketEntry((int)args[0], NO) != NULL) {
                GuestLog("[guest] sock fd=%d write error=%d\n",
                         (int)args[0],
                         error);
            }
            errno = error;
            return GuestErrno();
        }
        GuestAccountSocket((int)args[0], result, YES);
        return (uint64_t)result;
    }
    case 63: { /* read */
        GuestReadGuardPreRead((int)args[0],
                              (uintptr_t)args[1],
                              (size_t)args[2]);
        ssize_t result = read((int)args[0],
                              (void *)args[1],
                              (size_t)args[2]);
        if (result < 0) {
            int error = errno;
            GuestTraceRead((int)args[0], args[2], -1, error);
            errno = error;
            return GuestErrno();
        }
        GuestAccountSocket((int)args[0], result, NO);
        GuestTraceRead((int)args[0], args[2], result, 0);
        GuestReadGuardPostRead((int)args[0],
                               (uintptr_t)args[1],
                               (size_t)result);
        return (uint64_t)result;
    }
    case 65: { /* readv (struct iovec is identical on Darwin) */
        ssize_t result = readv((int)args[0],
                               (const struct iovec *)(uintptr_t)args[1],
                               (int)args[2]);
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 66: { /* writev */
        ssize_t result = writev((int)args[0],
                                (const struct iovec *)(uintptr_t)args[1],
                                (int)args[2]);
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 62: { /* lseek */
        if (args[2] == 0 && args[1] == 0) {
            GuestDirCacheRewind((int)args[0]);
        }
        off_t result = lseek((int)args[0], (off_t)args[1], (int)args[2]);
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 57: /* close */
        GuestDirCacheDrop((int)args[0]);
        GuestReadGuardDrop((int)args[0]);
        GuestDropSocket((int)args[0]);
        return close((int)args[0]) == 0 ? 0 : GuestErrno();
    case 93: /* exit */
    case 94: /* exit_group */
        GuestLog(
                "[guest] exit syscall %llu code=%lld\n",
                (unsigned long long)number,
                (long long)args[0]);
        GuestLogSyscallStats();
        _exit((int)args[0]);
    case 172: /* getpid */
        return (uint64_t)getpid();
    case 173: /* getppid */
        return (uint64_t)getppid();
    case 174: /* getuid */
    case 175: /* geteuid */
    case 176: /* getgid */
    case 177: /* getegid */
        /*
         * The guest is a single-user Linux runtime and apk refuses to install
         * unless it runs as root.  Host file permissions still apply.
         */
        return 0;
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
        size_t size = (size_t)args[1];
        size_t length = strlen(GuestCwd) + 1;
        if (args[0] == 0 || size < length) {
            return (uint64_t)(-ERANGE);
        }
        memcpy((void *)args[0], GuestCwd, length);
        return (uint64_t)length;
    }
    case 49: { /* chdir */
        const char *path = (const char *)args[0];
        if (path == NULL || path[0] != '/') {
            return (uint64_t)(-ENOENT);
        }
        char hostPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath(GUEST_AT_FDCWD, path, hostPath, sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        struct stat status;
        if (stat(hostPath, &status) != 0) {
            return GuestErrno();
        }
        if (!S_ISDIR(status.st_mode)) {
            return (uint64_t)(-ENOTDIR);
        }
        snprintf(GuestCwd, sizeof(GuestCwd), "%s", path);
        return 0;
    }
    case 50: { /* fchdir */
        char host[PATH_MAX];
        if (fcntl((int)args[0], GUEST_F_GETPATH, host) != 0) {
            return GuestErrno();
        }
        const char *relative = strstr(host, GuestRootPath);
        snprintf(GuestCwd,
                 sizeof(GuestCwd),
                 "%s",
                 relative != NULL ? host + strlen(GuestRootPath) : "/");
        return 0;
    }
    case 56: { /* openat */
        const char *guestPath = (const char *)args[1];
        char hostPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath((int)args[0], guestPath, hostPath, sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        int hostFlags = GuestToHostOpenFlags(args[2]);
        if (hostFlags < 0) {
            return (uint64_t)(-EINVAL);
        }
        int descriptor = open(hostPath, hostFlags, (mode_t)args[3]);
        int error = errno;
        if (descriptor < 0 && error == ENOENT && (args[2] & 0x40) != 0) {
            /* O_CREAT with a missing parent directory (apk's lib/apk/db). */
            GuestCreateParentDirectories(hostPath);
            descriptor = open(hostPath, hostFlags, (mode_t)args[3]);
            error = errno;
        }
        if (descriptor < 0) {
            GuestLogFileError("openat", guestPath, hostPath, error);
            return (uint64_t)(-(int64_t)error);
        }
        /*
         * apk reads its repository indexes through the cache directory, and a
         * failing index parse is indistinguishable from a failing open in the
         * log.  Name the descriptors that matter so a read trace can be tied
         * back to a file.
         */
        {
            struct stat opened;
            long long size = -1;
            if (fstat(descriptor, &opened) == 0) {
                size = (long long)opened.st_size;
            }
            GuestLog("[guest] openat fd=%d size=%lld %s\n",
                     descriptor, size, guestPath);
        }
        return (uint64_t)descriptor;
    }
    case 61: { /* getdents64 */
        return GuestGetDents64((int)args[0], (void *)args[1], args[2]);
    }
    case 79: { /* newfstatat */
        const char *guestPath = (const char *)args[1];
        void *output = (void *)args[2];
        if (output == NULL) {
            return (uint64_t)(-EFAULT);
        }
        struct stat status;
        int result;
        if (guestPath == NULL || guestPath[0] == 0) {
            if ((int)args[0] < 0) {
                return (uint64_t)(-EBADF);
            }
            result = fstat((int)args[0], &status);
        } else {
            char hostPath[GUEST_ROOT_MAX];
            if (GuestTranslatePath((int)args[0],
                                   guestPath,
                                   hostPath,
                                   sizeof(hostPath)) == NULL) {
                return (uint64_t)(-ENOENT);
            }
            if (args[3] & 0x100) {
                result = lstat(hostPath, &status);
            } else {
                result = stat(hostPath, &status);
            }
        }
        if (result != 0) {
            return GuestErrno();
        }
        GuestFillStat(&status, output);
        return 0;
    }
    case 80: { /* fstat */
        struct stat status;
        if (fstat((int)args[0], &status) != 0) {
            return GuestErrno();
        }
        if (args[1] == 0) {
            return (uint64_t)(-EFAULT);
        }
        GuestFillStat(&status, (void *)args[1]);
        return 0;
    }
    case 43: { /* statfs */
        char hostPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath(GUEST_AT_FDCWD,
                               (const char *)args[0],
                               hostPath,
                               sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        if (args[1] == 0) {
            return (uint64_t)(-EFAULT);
        }
        struct statfs status;
        if (statfs(hostPath, &status) != 0) {
            return GuestErrno();
        }
        GuestFillStatfs(&status, (void *)args[1]);
        return 0;
    }
    case 44: { /* fstatfs */
        if (args[1] == 0) {
            return (uint64_t)(-EFAULT);
        }
        struct statfs status;
        if (fstatfs((int)args[0], &status) != 0) {
            return GuestErrno();
        }
        GuestFillStatfs(&status, (void *)args[1]);
        return 0;
    }
    case 32: /* flock */
        return flock((int)args[0], (int)args[1]) == 0 ? 0 : GuestErrno();
    case 52: /* fchmod */
        return fchmod((int)args[0], (mode_t)args[1]) == 0 ? 0 : GuestErrno();
    case 53: { /* fchmodat */
        char hostPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath((int)args[0],
                               (const char *)args[1],
                               hostPath,
                               sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        return chmod(hostPath, (mode_t)args[2]) == 0 ? 0 : GuestErrno();
    }
    case 54: /* fchownat */
    case 55: /* fchown */
        /*
         * The host process runs as the mobile user while the guest thinks it
         * is root, so a real chown would fail with EPERM and confuse apk.
         * Ownership is irrelevant for this single-user runtime.
         */
        return 0;
    case 166: /* umask */
        return (uint64_t)umask((mode_t)args[0]);
    case 23: { /* dup */
        int result = dup((int)args[0]);
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 24: { /* dup3 */
        int result = dup2((int)args[0], (int)args[1]);
        if (result >= 0 && (args[2] & 0x80000)) {
            fcntl(result, F_SETFD, fcntl(result, F_GETFD) | FD_CLOEXEC);
        }
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 25: { /* fcntl */
        int descriptor = (int)args[0];
        int command = (int)args[1];
        uint64_t argument = args[2];
        switch (command) {
        case 0: { /* F_DUPFD */
            int result = fcntl(descriptor, F_DUPFD, (int)argument);
            return result < 0 ? GuestErrno() : (uint64_t)result;
        }
        case 1: { /* F_GETFD */
            int result = fcntl(descriptor, F_GETFD);
            return result < 0 ? GuestErrno() : (uint64_t)result;
        }
        case 2: /* F_SETFD */
            return fcntl(descriptor, F_SETFD, (int)argument) < 0
                ? GuestErrno() : 0;
        case 3: { /* F_GETFL */
            int result = fcntl(descriptor, F_GETFL);
            return result < 0 ? GuestErrno() : GuestFromHostOpenFlags(result);
        }
        case 4: { /* F_SETFL */
            int hostFlags = GuestToHostOpenFlags(argument);
            int masked = hostFlags &
                (O_APPEND | O_NONBLOCK | O_ASYNC | O_DSYNC | O_SYNC);
            return fcntl(descriptor, F_SETFL, masked) < 0 ? GuestErrno() : 0;
        }
        case 1030: { /* F_DUPFD_CLOEXEC */
            int result = fcntl(descriptor, F_DUPFD_CLOEXEC, (int)argument);
            return result < 0 ? GuestErrno() : (uint64_t)result;
        }
        case 5: case 6: case 7: /* F_GETLK / F_SETLK / F_SETLKW */
            return 0;
        default:
            return (uint64_t)(-EINVAL);
        }
    }
    case 59: { /* pipe2 */
        int descriptors[2] = { -1, -1 };
        if (pipe(descriptors) != 0) {
            return GuestErrno();
        }
        if (args[1] & 0x80000) {
            fcntl(descriptors[0], F_SETFD, FD_CLOEXEC);
            fcntl(descriptors[1], F_SETFD, FD_CLOEXEC);
        }
        if (args[1] & 0x800) {
            fcntl(descriptors[0], F_SETFL, O_NONBLOCK);
            fcntl(descriptors[1], F_SETFL, O_NONBLOCK);
        }
        if (args[0] != 0) {
            ((int *)args[0])[0] = descriptors[0];
            ((int *)args[0])[1] = descriptors[1];
        }
        return 0;
    }
    case 67: { /* pread64 */
        ssize_t result = pread((int)args[0],
                               (void *)args[1],
                               (size_t)args[2],
                               (off_t)args[3]);
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 68: { /* pwrite64 */
        ssize_t result = pwrite((int)args[0],
                                (const void *)args[1],
                                (size_t)args[2],
                                (off_t)args[3]);
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 71: { /* sendfile: read/write loop, offset pointer is optional */
        int outDescriptor = (int)args[0];
        int inDescriptor = (int)args[1];
        uint64_t offsetPointer = args[2];
        size_t count = (size_t)args[3];
        BOOL haveOffset = offsetPointer != 0;
        uint64_t offset = haveOffset
            ? *(uint64_t *)(uintptr_t)offsetPointer : 0;
        size_t total = 0;
        char buffer[16384];
        while (total < count) {
            size_t chunk = count - total;
            if (chunk > sizeof(buffer)) {
                chunk = sizeof(buffer);
            }
            ssize_t got = haveOffset
                ? pread(inDescriptor,
                        buffer,
                        chunk,
                        (off_t)(offset + total))
                : read(inDescriptor, buffer, chunk);
            if (got < 0) {
                if (total != 0) {
                    break;
                }
                return GuestErrno();
            }
            if (got == 0) {
                break;
            }
            ssize_t written = write(outDescriptor, buffer, (size_t)got);
            if (written < 0) {
                if (total != 0) {
                    break;
                }
                return GuestErrno();
            }
            total += (size_t)written;
            if (written < got) {
                break;
            }
        }
        if (haveOffset) {
            *(uint64_t *)(uintptr_t)offsetPointer = offset + total;
        }
        return (uint64_t)total;
    }
    case 45: { /* truncate */
        char hostPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath(GUEST_AT_FDCWD,
                               (const char *)args[0],
                               hostPath,
                               sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        return truncate(hostPath, (off_t)args[1]) == 0 ? 0 : GuestErrno();
    }
    case 46: /* ftruncate */
        return ftruncate((int)args[0], (off_t)args[1]) == 0 ? 0 : GuestErrno();
    case 82: /* fsync */
        return fsync((int)args[0]) == 0 ? 0 : GuestErrno();
    case 83: /* fdatasync */
        return fsync((int)args[0]) == 0 ? 0 : GuestErrno();
    case 34: { /* mkdirat */
        char hostPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath((int)args[0],
                               (const char *)args[1],
                               hostPath,
                               sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        if (mkdir(hostPath, (mode_t)args[2]) != 0) {
            int error = errno;
            if (error != EEXIST) {
                GuestLogFileError("mkdirat",
                                  (const char *)args[1],
                                  hostPath,
                                  error);
            }
            return (uint64_t)(-(int64_t)error);
        }
        return 0;
    }
    case 35: { /* unlinkat */
        char hostPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath((int)args[0],
                               (const char *)args[1],
                               hostPath,
                               sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        int result = (args[2] & 0x200) ? rmdir(hostPath) : unlink(hostPath);
        if (result != 0) {
            int error = errno;
            if (error != ENOENT) {
                GuestLogFileError("unlinkat",
                                  (const char *)args[1],
                                  hostPath,
                                  error);
            }
            return (uint64_t)(-(int64_t)error);
        }
        return 0;
    }
    case 36: { /* symlinkat */
        char hostPath[GUEST_ROOT_MAX];
        char targetPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath((int)args[1],
                               (const char *)args[2],
                               hostPath,
                               sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        /*
         * An absolute target must be rewritten into the rootfs, otherwise the
         * host resolves the link against the real "/" and every open through
         * it fails (or, worse, hits a host file).  Relative targets already
         * resolve inside the same directory and are left untouched.
         */
        const char *target = (const char *)args[0];
        if (target != NULL && target[0] == '/') {
            if (GuestTranslatePath(GUEST_AT_FDCWD,
                                   target,
                                   targetPath,
                                   sizeof(targetPath)) != NULL) {
                target = targetPath;
            }
        }
        if (symlink(target, hostPath) != 0) {
            int error = errno;
            GuestLogFileError("symlinkat",
                              (const char *)args[2],
                              hostPath,
                              error);
            return (uint64_t)(-(int64_t)error);
        }
        return 0;
    }
    case 37: { /* linkat */
        char oldPath[GUEST_ROOT_MAX];
        char newPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath((int)args[0],
                               (const char *)args[1],
                               oldPath,
                               sizeof(oldPath)) == NULL ||
            GuestTranslatePath((int)args[2],
                               (const char *)args[3],
                               newPath,
                               sizeof(newPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        if (link(oldPath, newPath) != 0) {
            int error = errno;
            GuestLogFileError("linkat",
                              (const char *)args[3],
                              newPath,
                              error);
            return (uint64_t)(-(int64_t)error);
        }
        return 0;
    }
    case 38: { /* renameat */
        char oldPath[GUEST_ROOT_MAX];
        char newPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath((int)args[0],
                               (const char *)args[1],
                               oldPath,
                               sizeof(oldPath)) == NULL ||
            GuestTranslatePath((int)args[2],
                               (const char *)args[3],
                               newPath,
                               sizeof(newPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        if (rename(oldPath, newPath) != 0) {
            int error = errno;
            GuestLogFileError("renameat",
                              (const char *)args[3],
                              newPath,
                              error);
            return (uint64_t)(-(int64_t)error);
        }
        return 0;
    }
    case 47: { /* fallocate */
        int descriptor = (int)args[0];
        int mode = (int)args[1];
        off_t start = (off_t)args[2];
        off_t length = (off_t)args[3];
        if (mode != 0) {
            /* PUNCH_HOLE / COLLAPSE_RANGE / ZERO_RANGE are not emulated. */
            return GuestError(EOPNOTSUPP);
        }
        if (start < 0 || length <= 0) {
            return GuestError(EINVAL);
        }
        /*
         * apk reserves space for every file it is about to extract and treats
         * a failure as a hard I/O error -- that is what aborted `apk add musl'
         * with "Failed to create lib/ld-musl-aarch64.so.1: I/O error".
         * Reservation is a hint, so report success even when the host refuses.
         */
#ifdef F_PREALLOCATE
        struct fstore store;
        memset(&store, 0, sizeof(store));
        store.fst_flags = F_ALLOCATECONTIG;
        store.fst_posmode = F_PEOFPOSMODE;
        store.fst_offset = start;
        store.fst_length = length;
        (void)fcntl(descriptor, F_PREALLOCATE, &store);
#endif
        /*
         * Linux fallocate extends the file, and apk immediately mmaps the
         * result MAP_SHARED for the full size.  Without the extension that
         * mapping would run past EOF and the first write would SIGBUS.
         */
        struct stat status;
        if (fstat(descriptor, &status) == 0 &&
            status.st_size < start + length) {
            if (ftruncate(descriptor, start + length) != 0) {
                return GuestErrno();
            }
        }
        return 0;
    }
    case 48: { /* faccessat */
        char hostPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath((int)args[0],
                               (const char *)args[1],
                               hostPath,
                               sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        int mode = (int)args[2];
        int hostMode = 0;
        if (mode & 4) hostMode |= R_OK;
        if (mode & 2) hostMode |= W_OK;
        if (mode & 1) hostMode |= X_OK;
        return access(hostPath, hostMode) == 0 ? 0 : GuestErrno();
    }
    case 88: { /* utimensat */
        char hostPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath((int)args[0],
                               (const char *)args[1],
                               hostPath,
                               sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        struct timespec times[2];
        if (args[2] != 0) {
            const uint64_t *guestTimes = (const uint64_t *)args[2];
            times[0].tv_sec = (time_t)guestTimes[0];
            times[0].tv_nsec = (long)guestTimes[1];
            times[1].tv_sec = (time_t)guestTimes[2];
            times[1].tv_nsec = (long)guestTimes[3];
            return utimensat(AT_FDCWD,
                             hostPath,
                             times,
                             (int)args[3] & 0x100 ? AT_SYMLINK_NOFOLLOW : 0)
                == 0 ? 0 : GuestErrno();
        }
        return utimensat(AT_FDCWD, hostPath, NULL, 0) == 0 ? 0 : GuestErrno();
    }
    case 78: { /* readlinkat */
        const char *path = (const char *)args[1];
        char *output = (char *)args[2];
        size_t size = (size_t)args[3];
        if (path == NULL || output == NULL) {
            return (uint64_t)(-EFAULT);
        }
        if (strcmp(path, "/proc/self/exe") == 0) {
            size_t length = strlen(GuestElfPath);
            if (length > size) {
                length = size;
            }
            memcpy(output, GuestElfPath, length);
            return (uint64_t)length;
        }
        if (strncmp(path, "/proc/self/fd/", 14) == 0) {
            int descriptor = atoi(path + 14);
            char host[PATH_MAX];
            if (fcntl(descriptor, GUEST_F_GETPATH, host) != 0) {
                return GuestErrno();
            }
            size_t length = strlen(host);
            if (length > size) {
                length = size;
            }
            memcpy(output, host, length);
            return (uint64_t)length;
        }
        char hostPath[GUEST_ROOT_MAX];
        if (GuestTranslatePath((int)args[0], path, hostPath, sizeof(hostPath)) == NULL) {
            return (uint64_t)(-ENOENT);
        }
        ssize_t length = readlink(hostPath, output, size);
        return length < 0 ? GuestErrno() : (uint64_t)length;
    }
    case 220: { /* clone */
        uint64_t flags = args[0];
        if ((flags & 0x100) == 0) { /* no CLONE_VM: fork-like */
            /*
             * The host fork path is unusable here: a fork child cannot
             * execute any of our pages (see GuestForkWithSnapshot).  Spawn a
             * fresh runner and restore the guest into it instead.
             */
            return GuestForkWithSnapshot(args, returnAddress);
        }
        GuestLog(
                "[guest] clone with CLONE_VM unsupported flags=0x%llx\n",
                (unsigned long long)flags);
        return (uint64_t)(-ENOSYS);
    }
    case 221: /* execve */
        return GuestExecSyscall(args[0], args[1], args[2]);
    case 260: { /* wait4 */
        int status = 0;
        pid_t result = waitpid((pid_t)args[0], &status, (int)args[2]);
        if (result < 0) {
            return GuestErrno();
        }
        if (args[1] != 0) {
            *(int *)args[1] = status;
        }
        if (args[3] != 0) {
            memset((void *)args[3], 0, 144);
        }
        return (uint64_t)result;
    }
    case 129: /* kill */
        return kill((pid_t)args[0], (int)args[1]) == 0 ? 0 : GuestErrno();
    case 130: /* tkill */
        return kill(getpid(), (int)args[1]) == 0 ? 0 : GuestErrno();
    case 131: { /* tgkill */
        pid_t target = (pid_t)args[0];
        return kill(target, (int)args[2]) == 0 ? 0 : GuestErrno();
    }
    case 98: { /* futex */
        uint64_t operation = args[1] & 0x7F;
        if (operation == 0 || operation == 9) {
            /* No guest threads yet: report "value changed" so callers retry. */
            return GuestError(EAGAIN);
        }
        return 0;
    }
    case 124: /* sched_yield */
        sched_yield();
        return 0;
    case 122: /* sched_setaffinity */
    case 123: /* sched_getaffinity */
    case 132: /* sigaltstack */
    case 134: /* rt_sigaction */
    case 140: /* setpriority */
    case 143: /* setregid */
    case 144: /* setgid */
    case 145: /* setreuid */
    case 146: /* setuid */
    case 147: /* setresuid */
    case 149: /* setresgid */
    case 151: /* setfsuid */
    case 152: /* setfsgid */
    case 158: /* getgroups */
    case 159: /* setgroups */
    case 164: /* setrlimit */
    case 167: /* prctl */
    case 168: /* getcpu */
        return 0;
    case 178: /* gettid */
        return (uint64_t)getpid();
    case 101: { /* nanosleep */
        struct timespec request;
        request.tv_sec = (time_t)args[0];
        request.tv_nsec = (long)args[1];
        if (nanosleep(&request, NULL) != 0) {
            return GuestErrno();
        }
        return 0;
    }
    case 115: { /* clock_nanosleep */
        struct timespec request;
        request.tv_sec = (time_t)args[2];
        request.tv_nsec = (long)args[3];
        if (args[1] & 1) { /* TIMER_ABSTIME */
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            time_t seconds = request.tv_sec - now.tv_sec;
            long nanoseconds = request.tv_nsec - now.tv_nsec;
            if (nanoseconds < 0) {
                seconds -= 1;
                nanoseconds += 1000000000L;
            }
            if (seconds < 0) {
                return 0;
            }
            request.tv_sec = seconds;
            request.tv_nsec = nanoseconds;
        }
        if (nanosleep(&request, NULL) != 0) {
            return GuestErrno();
        }
        return 0;
    }
    case 163: { /* getrlimit */
        uint64_t *output = (uint64_t *)args[1];
        if (output == NULL) {
            return (uint64_t)(-EFAULT);
        }
        if ((int)args[0] == 3) { /* RLIMIT_STACK */
            output[0] = 8 * 1024 * 1024;
            output[1] = 64 * 1024 * 1024;
        } else {
            output[0] = 1024 * 1024;
            output[1] = 1024 * 1024;
        }
        return 0;
    }
    case 165: { /* getrusage */
        if (args[1] != 0) {
            memset((void *)args[1], 0, 144);
        }
        return 0;
    }
    case 153: { /* times */
        if (args[0] != 0) {
            memset((void *)args[0], 0, 32);
        }
        return 0;
    }
    case 114: { /* clock_getres */
        uint64_t *output = (uint64_t *)(uintptr_t)args[1];
        if (output != NULL) {
            output[0] = 0;
            output[1] = 1000000;
        }
        return 0;
    }
    /* ---------------- network ---------------- */
    case 198: { /* socket */
        static unsigned int socketTrace = 0;
        int family = GuestToHostSocketFamily((int)args[0]);
        if (family < 0) {
            GuestLog("[guest] socket: unsupported family %llu\n",
                     (unsigned long long)args[0]);
            return GuestError(EAFNOSUPPORT);
        }
        int type = (int)args[1];
        int typeFlags = type & (GUEST_SOCK_CLOEXEC | GUEST_SOCK_NONBLOCK);
        type &= ~(GUEST_SOCK_CLOEXEC | GUEST_SOCK_NONBLOCK);
        int descriptor = socket(family, type, (int)args[2]);
        if (descriptor < 0) {
            return GuestErrno();
        }
        GuestConfigureSocket(descriptor, typeFlags);
        GuestTrackSocket(descriptor);
        if (socketTrace < 12) {
            socketTrace++;
            GuestLog("[guest] socket family=%llu type=0x%llx -> %d\n",
                     (unsigned long long)args[0],
                     (unsigned long long)args[1],
                     descriptor);
        }
        return (uint64_t)descriptor;
    }
    case 199: { /* socketpair */
        int family = GuestToHostSocketFamily((int)args[0]);
        if (family < 0) {
            return GuestError(EAFNOSUPPORT);
        }
        int type = (int)args[1];
        int typeFlags = type & (GUEST_SOCK_CLOEXEC | GUEST_SOCK_NONBLOCK);
        type &= ~(GUEST_SOCK_CLOEXEC | GUEST_SOCK_NONBLOCK);
        int descriptors[2] = { -1, -1 };
        if (socketpair(family, type, (int)args[2], descriptors) != 0) {
            return GuestErrno();
        }
        GuestConfigureSocket(descriptors[0], typeFlags);
        GuestConfigureSocket(descriptors[1], typeFlags);
        GuestTrackSocket(descriptors[0]);
        GuestTrackSocket(descriptors[1]);
        if (args[3] != 0) {
            ((int *)(uintptr_t)args[3])[0] = descriptors[0];
            ((int *)(uintptr_t)args[3])[1] = descriptors[1];
        }
        return 0;
    }
    case 200: { /* bind */
        struct sockaddr_storage address;
        socklen_t length = 0;
        int status = GuestToHostSockaddr((const void *)(uintptr_t)args[1],
                                         (uint32_t)args[2],
                                         &address,
                                         &length);
        if (status < 0) {
            return (uint64_t)status;
        }
        return bind((int)args[0], (struct sockaddr *)&address, length) == 0
            ? 0 : GuestErrno();
    }
    case 201: /* listen */
        return listen((int)args[0], (int)args[1]) == 0 ? 0 : GuestErrno();
    case 202: { /* accept */
        struct sockaddr_storage address;
        socklen_t length = (socklen_t)sizeof(address);
        int descriptor = accept((int)args[0],
                                (struct sockaddr *)&address,
                                &length);
        if (descriptor < 0) {
            return GuestErrno();
        }
        GuestConfigureSocket(descriptor, 0);
        GuestTrackSocket(descriptor);
        if (args[1] != 0 && args[2] != 0) {
            uint32_t capacity = *(uint32_t *)(uintptr_t)args[2];
            *(uint32_t *)(uintptr_t)args[2] =
                GuestFromHostSockaddr((struct sockaddr *)&address,
                                      length,
                                      (void *)(uintptr_t)args[1],
                                      capacity);
        }
        return (uint64_t)descriptor;
    }
    case 242: { /* accept4 */
        struct sockaddr_storage address;
        socklen_t length = (socklen_t)sizeof(address);
        int descriptor = accept((int)args[0],
                                (struct sockaddr *)&address,
                                &length);
        if (descriptor < 0) {
            return GuestErrno();
        }
        GuestConfigureSocket(descriptor, (int)args[3]);
        GuestTrackSocket(descriptor);
        if (args[1] != 0 && args[2] != 0) {
            uint32_t capacity = *(uint32_t *)(uintptr_t)args[2];
            *(uint32_t *)(uintptr_t)args[2] =
                GuestFromHostSockaddr((struct sockaddr *)&address,
                                      length,
                                      (void *)(uintptr_t)args[1],
                                      capacity);
        }
        return (uint64_t)descriptor;
    }
    case 203: { /* connect */
        struct sockaddr_storage address;
        socklen_t length = 0;
        int status = GuestToHostSockaddr((const void *)(uintptr_t)args[1],
                                         (uint32_t)args[2],
                                         &address,
                                         &length);
        if (status < 0) {
            return (uint64_t)status;
        }
        static unsigned int connectTrace = 0;
        int result = connect((int)args[0],
                             (struct sockaddr *)&address,
                             length);
        int hostFamily = ((struct sockaddr *)&address)->sa_family;
        if (result != 0) {
            int error = errno;
            if (connectTrace < 8) {
                connectTrace++;
                GuestLog("[guest] connect fd=%d family=%d errno=%d\n",
                         (int)args[0],
                         hostFamily,
                         error);
            }
            errno = error;
            return GuestErrno();
        }
        if (connectTrace < 8) {
            connectTrace++;
            GuestLog("[guest] connect fd=%d family=%d ok\n",
                     (int)args[0],
                     hostFamily);
        }
        return 0;
    }
    case 204: /* getsockname */
    case 205: { /* getpeername */
        struct sockaddr_storage address;
        socklen_t length = (socklen_t)sizeof(address);
        int result = number == 204
            ? getsockname((int)args[0], (struct sockaddr *)&address, &length)
            : getpeername((int)args[0], (struct sockaddr *)&address, &length);
        if (result != 0) {
            return GuestErrno();
        }
        if (args[1] != 0 && args[2] != 0) {
            uint32_t capacity = *(uint32_t *)(uintptr_t)args[2];
            *(uint32_t *)(uintptr_t)args[2] =
                GuestFromHostSockaddr((struct sockaddr *)&address,
                                      length,
                                      (void *)(uintptr_t)args[1],
                                      capacity);
        }
        return 0;
    }
    case 206: { /* sendto */
        struct sockaddr_storage address;
        socklen_t length = 0;
        const struct sockaddr *target = NULL;
        if (args[4] != 0 && args[5] != 0) {
            int status = GuestToHostSockaddr((const void *)(uintptr_t)args[4],
                                             (uint32_t)args[5],
                                             &address,
                                             &length);
            if (status < 0) {
                return (uint64_t)status;
            }
            target = (const struct sockaddr *)&address;
        }
        ssize_t result = sendto((int)args[0],
                                (const void *)(uintptr_t)args[1],
                                (size_t)args[2],
                                GuestToHostMessageFlags((int)args[3]),
                                target,
                                length);
        if (result < 0) {
            return GuestErrno();
        }
        GuestAccountSocket((int)args[0], result, YES);
        return (uint64_t)result;
    }
    case 207: { /* recvfrom */
        struct sockaddr_storage address;
        socklen_t length = (socklen_t)sizeof(address);
        ssize_t result = recvfrom((int)args[0],
                                  (void *)(uintptr_t)args[1],
                                  (size_t)args[2],
                                  GuestToHostMessageFlags((int)args[3]),
                                  (struct sockaddr *)&address,
                                  &length);
        if (result < 0) {
            int error = errno;
            GuestLog("[guest] recvfrom fd=%d error=%d\n", (int)args[0], error);
            errno = error;
            return GuestErrno();
        }
        GuestAccountSocket((int)args[0], result, NO);
        if (args[4] != 0 && args[5] != 0) {
            uint32_t capacity = *(uint32_t *)(uintptr_t)args[5];
            *(uint32_t *)(uintptr_t)args[5] =
                GuestFromHostSockaddr((struct sockaddr *)&address,
                                      length,
                                      (void *)(uintptr_t)args[4],
                                      capacity);
        }
        return (uint64_t)result;
    }
    case 208: { /* setsockopt */
        int level = (int)args[1];
        int option = (int)args[2];
        int hostLevel = level == GUEST_SOL_SOCKET ? SOL_SOCKET : level;
        int hostOption = GuestToHostSocketOption(level, option);
        if (hostOption < 0) {
            /* SO_BINDTODEVICE and other Linux-only knobs: accept silently. */
            return 0;
        }
        if (level == GUEST_SOL_SOCKET && (option == 20 || option == 21)) {
            if (args[3] == 0 || args[4] < 16) {
                return (uint64_t)(-EINVAL);
            }
            const uint64_t *input = (const uint64_t *)(uintptr_t)args[3];
            struct timeval value;
            value.tv_sec = (time_t)input[0];
            value.tv_usec = (suseconds_t)input[1];
            if (setsockopt((int)args[0],
                           hostLevel,
                           hostOption,
                           &value,
                           (socklen_t)sizeof(value)) != 0) {
                int error = errno;
                GuestLog("[guest] setsockopt fd=%d level=%d opt=%d "
                         "hostLevel=%d hostOpt=%d error=%d\n",
                         (int)args[0], level, option,
                         hostLevel, hostOption, error);
                errno = error;
                return GuestErrno();
            }
            return 0;
        }
        if (setsockopt((int)args[0],
                       hostLevel,
                       hostOption,
                       (const void *)(uintptr_t)args[3],
                       (socklen_t)args[4]) != 0) {
            int error = errno;
            GuestLog("[guest] setsockopt fd=%d level=%d opt=%d "
                     "hostLevel=%d hostOpt=%d error=%d\n",
                     (int)args[0], level, option,
                     hostLevel, hostOption, error);
            errno = error;
            return GuestErrno();
        }
        return 0;
    }
    case 209: { /* getsockopt */
        int level = (int)args[1];
        int option = (int)args[2];
        int hostLevel = level == GUEST_SOL_SOCKET ? SOL_SOCKET : level;
        int hostOption = GuestToHostSocketOption(level, option);
        if (args[4] == 0) {
            return (uint64_t)(-EFAULT);
        }
        socklen_t *lengthPointer = (socklen_t *)(uintptr_t)args[4];
        if (hostOption < 0) {
            *lengthPointer = 0;
            return 0;
        }
        if (level == GUEST_SOL_SOCKET && (option == 20 || option == 21)) {
            struct timeval value;
            socklen_t size = (socklen_t)sizeof(value);
            if (getsockopt((int)args[0],
                           hostLevel,
                           hostOption,
                           &value,
                           &size) != 0) {
                return GuestErrno();
            }
            if (args[3] != 0 && *lengthPointer >= 16) {
                uint64_t *output = (uint64_t *)(uintptr_t)args[3];
                output[0] = (uint64_t)value.tv_sec;
                output[1] = (uint64_t)value.tv_usec;
            }
            *lengthPointer = 16;
            return 0;
        }
        socklen_t size = *lengthPointer;
        if (getsockopt((int)args[0],
                       hostLevel,
                       hostOption,
                       (void *)(uintptr_t)args[3],
                       &size) != 0) {
            return GuestErrno();
        }
        *lengthPointer = size;
        return 0;
    }
    case 210: /* shutdown */
        return shutdown((int)args[0], (int)args[1]) == 0 ? 0 : GuestErrno();
    case 211: { /* sendmsg */
        GuestMessageHeader *guest =
            (GuestMessageHeader *)(uintptr_t)args[1];
        if (guest == NULL) {
            return (uint64_t)(-EFAULT);
        }
        struct msghdr message;
        memset(&message, 0, sizeof(message));
        struct sockaddr_storage address;
        socklen_t length = 0;
        if (guest->name != NULL && guest->nameLength != 0) {
            int status = GuestToHostSockaddr(guest->name,
                                             guest->nameLength,
                                             &address,
                                             &length);
            if (status < 0) {
                return (uint64_t)status;
            }
            message.msg_name = &address;
            message.msg_namelen = length;
        }
        message.msg_iov = (struct iovec *)guest->iov;
        message.msg_iovlen = (int)guest->iovLength;
        if (guest->control != NULL && guest->controlLength != 0) {
            static unsigned int controlTrace = 0;
            if (controlTrace < 4) {
                controlTrace++;
                GuestLog("[guest] sendmsg control data ignored\n");
            }
        }
        ssize_t result = sendmsg((int)args[0],
                                 &message,
                                 GuestToHostMessageFlags((int)args[2]));
        if (result < 0) {
            return GuestErrno();
        }
        GuestAccountSocket((int)args[0], result, YES);
        return (uint64_t)result;
    }
    case 212: { /* recvmsg */
        GuestMessageHeader *guest =
            (GuestMessageHeader *)(uintptr_t)args[1];
        if (guest == NULL) {
            return (uint64_t)(-EFAULT);
        }
        struct msghdr message;
        memset(&message, 0, sizeof(message));
        struct sockaddr_storage address;
        message.msg_name = &address;
        message.msg_namelen = (socklen_t)sizeof(address);
        message.msg_iov = (struct iovec *)guest->iov;
        message.msg_iovlen = (int)guest->iovLength;
        ssize_t result = recvmsg((int)args[0],
                                 &message,
                                 GuestToHostMessageFlags((int)args[2]));
        if (result < 0) {
            int error = errno;
            GuestLog("[guest] recvmsg fd=%d error=%d\n", (int)args[0], error);
            errno = error;
            return GuestErrno();
        }
        GuestAccountSocket((int)args[0], result, NO);
        if (guest->name != NULL) {
            guest->nameLength =
                GuestFromHostSockaddr((struct sockaddr *)&address,
                                      message.msg_namelen,
                                      guest->name,
                                      guest->nameLength);
        }
        guest->flags = GuestFromHostMessageFlags(message.msg_flags);
        if (guest->control != NULL) {
            guest->controlLength = 0;
        }
        return (uint64_t)result;
    }
    case 72: { /* pselect6: Darwin has no pselect, emulate with select */
        struct timeval value;
        struct timeval *timeout = NULL;
        if (args[4] != 0) {
            const struct timespec *request =
                (const struct timespec *)(uintptr_t)args[4];
            value.tv_sec = (time_t)request->tv_sec;
            value.tv_usec = (suseconds_t)(request->tv_nsec / 1000);
            timeout = &value;
        }
        int result = select((int)args[0],
                            (fd_set *)(uintptr_t)args[1],
                            (fd_set *)(uintptr_t)args[2],
                            (fd_set *)(uintptr_t)args[3],
                            timeout);
        return result < 0 ? GuestErrno() : (uint64_t)result;
    }
    case 73: { /* ppoll */
        int milliseconds = -1;
        if (args[2] != 0) {
            milliseconds = GuestTimeoutToMilliseconds(
                (const struct timespec *)(uintptr_t)args[2]);
        }
        return GuestHandlePoll(args[0], args[1], milliseconds);
    }
    case 214: { /* brk */
        static unsigned int brkTrace = 0;
        if (args[0] == 0) {
            if (brkTrace < 4) {
                brkTrace++;
                GuestLog( "[guest] brk(0) -> 0x%lx\n",
                        (unsigned long)GuestBrkCurrent);
            }
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
            if (brkTrace < 4) {
                brkTrace++;
                GuestLog( "[guest] brk(0x%lx) -> 0x%lx\n",
                        (unsigned long)requested,
                        (unsigned long)GuestBrkCurrent);
            }
            return GuestBrkCurrent;
        }
        return GuestBrkCurrent;
    }
    case 222: { /* mmap */
        return GuestHandleMmap(args[0],
                               args[1],
                               (int)args[2],
                               args[3],
                               (int)args[4],
                               args[5]);
    }
    case 215: { /* munmap */
        return GuestHandleMunmap((uintptr_t)args[0], (size_t)args[1]);
    }
    case 216: { /* mremap */
        return GuestHandleMremap((uintptr_t)args[0],
                                 (size_t)args[1],
                                 (size_t)args[2],
                                 args[3],
                                 (uintptr_t)args[4]);
    }
    case 226: { /* mprotect */
        return GuestHandleMprotect((uintptr_t)args[0],
                                   (size_t)args[1],
                                   (int)args[2]);
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
        GuestLog( "[guest] unsupported syscall %llu\n",
                (unsigned long long)number);
        return (uint64_t)(-ENOSYS);
    }
}

uint64_t GuestSyscallDispatch(uint64_t *args,
                              uint64_t number,
                              uint64_t returnAddress)
{
    uint64_t result =
        GuestSyscallDispatchInner(args, number, returnAddress);
    if (number < 512) {
        GuestSyscallCounts[number]++;
        if ((int64_t)result < 0 && (int64_t)result >= -4095) {
            GuestSyscallErrorCounts[number]++;
            GuestSyscallLastErrors[number] = (int64_t)result;
        }
    }
    return result;
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
            GuestLog(
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
    /* Restore mode: the snapshot's absolute addresses must be reproduced. */
    if (GuestForcedBase != 0 &&
        GuestRangeFree(GuestForcedBase, (size_t)imageSize)) {
        return GuestForcedBase;
    }

    /*
     * A restored child can have the snapshot buffer, the 64MB guest heap,
     * the guest stack and the island occupying the positive offsets, which
     * used to leave "no free address range near trampoline".  Scan both
     * directions in 16MB steps; stay within 64MB so the island (image
     * +/-32MB) is still reachable from the shared trampoline.
     */
    const int64_t offsets[] = {
        0x04000000, 0x03000000, 0x02000000, 0x01000000,
        -0x01000000, -0x02000000, -0x03000000, -0x04000000,
    };

    for (size_t index = 0; index < sizeof(offsets) / sizeof(offsets[0]);
         index++) {
        uintptr_t candidate =
            (uintptr_t)((int64_t)trampoline + offsets[index]) & ~0x3FFFULL;
        if (candidate < 0x100000000ULL) {
            continue;
        }
        int64_t distance = (int64_t)candidate - (int64_t)trampoline;
        if (distance < -(1LL << 26) || distance > (1LL << 26)) {
            continue;
        }
        if (candidate + imageSize > trampoline + 0x06800000ULL) {
            continue;
        }
        if (GuestRangeFree(candidate, (size_t)imageSize)) {
            return candidate;
        }
    }

    return 0;
}

/*
 * Place the PT_INTERP image inside the same +/-120MB window as the main
 * image so every patched site can reach the shared island page with a
 * single "b" instruction.
 */
static uintptr_t GuestChooseInterpBase(uintptr_t mainStart,
                                       uint64_t mainSize,
                                       uint64_t interpSize,
                                       uintptr_t trampoline)
{
    (void)mainSize;
    const int64_t offsets[] = {
        0x02000000, 0x04000000, -0x02000000, 0x06000000, -0x04000000,
    };
    for (size_t index = 0; index < sizeof(offsets) / sizeof(offsets[0]);
         index++) {
        uintptr_t candidate = (uintptr_t)((int64_t)mainStart + offsets[index]);
        candidate &= ~0x3FFFULL;
        int64_t distance = (int64_t)candidate - (int64_t)trampoline;
        if (distance < -(1LL << 26) || distance > 0x07000000LL) {
            continue;
        }
        if (GuestRangeFree(candidate, (size_t)interpSize)) {
            return candidate;
        }
    }
    return 0;
}

static void GuestJump(uint64_t entry, uint64_t stack)
{
    /*
     * Enter exactly like the Linux kernel does: only sp/pc are meaningful.
     * In particular x3 must be zero - glibc's _start copies it into
     * rtld_fini and __libc_start_main registers it with __cxa_atexit.
     * Leaving a stray 1 there makes exit() call address 1 (PC alignment
     * fault at pc=1).
     */
    __asm__ volatile("mov sp, %0\n"
                     "mov x8, %1\n"
                     "mov x0, #0\n"
                     "mov x1, #0\n"
                     "mov x2, #0\n"
                     "mov x3, #0\n"
                     "mov x4, #0\n"
                     "mov x5, #0\n"
                     "mov x6, #0\n"
                     "mov x29, #0\n"
                     "mov x30, #0\n"
                     "br x8\n"
                     :: "r"(stack), "r"(entry)
                     : "x8", "x0", "x1", "x2", "x3", "x4", "x5", "x6",
                       "x29", "x30", "memory");
}

static void GuestDumpForkChild(const char *tag);

/*
 * The watchdog is a SIGALRM timer rather than a pthread.  A second thread
 * makes fork() risky (the child inherits any libc lock that thread held at
 * fork time), and the shell's first fork hung exactly there.
 */
static volatile int GuestWatchdogStage = 0;

static void GuestAlarmHandler(int signalNumber,
                              siginfo_t *information,
                              void *context)
{
    (void)signalNumber;
    (void)information;
    GuestWatchdogStage++;

    ucontext_t *state = (ucontext_t *)context;
    uint64_t pc = 0;
    uint64_t lr = 0;
    uint64_t sp = 0;
    if (state != NULL) {
        pc = (uint64_t)state->uc_mcontext->__ss.__pc;
        lr = (uint64_t)state->uc_mcontext->__ss.__lr;
        sp = (uint64_t)state->uc_mcontext->__ss.__sp;
    }
    GuestLog("[guest] alarm%d pc=0x%llx lr=0x%llx sp=0x%llx\n",
             GuestWatchdogStage,
             (unsigned long long)pc,
             (unsigned long long)lr,
             (unsigned long long)sp);
    GuestDumpForkChild("alarm");

    if (GuestWatchdogStage >= 12) {
        GuestLog("[guest] watchdog: guest still running, aborting\n");
        _exit(4);
    }
    alarm(30);
}

static void GuestDumpWords(mach_port_t task,
                           uint64_t address,
                           int count,
                           const char *label)
{
    char line[320];
    for (int base = 0; base < count; base += 8) {
        int length = snprintf(line,
                              sizeof(line),
                              "[guest] %s 0x%llx:",
                              label,
                              (unsigned long long)(address +
                                                   (uint64_t)base * 8));
        for (int index = 0; index < 8 && base + index < count; index++) {
            uint64_t value = 0;
            vm_size_t size = 0;
            if (vm_read_overwrite(task,
                                  (vm_address_t)(address +
                                                 (uint64_t)(base + index) * 8),
                                  sizeof(value),
                                  (vm_address_t)&value,
                                  &size) != KERN_SUCCESS) {
                value = 0;
            }
            length += snprintf(line + length,
                               sizeof(line) - (size_t)length,
                               " %016llx",
                               (unsigned long long)value);
            if (length >= (int)sizeof(line) - 24) {
                break;
            }
        }
        GuestWriteAll(STDOUT_FILENO, line, strlen(line));
        GuestWriteAll(STDOUT_FILENO, "\n", 1);
    }
}

/*
 * The faulting child sits at the entry of GuestSignalHandler, with
 * x0 = signal, x1 = siginfo_t*, x2 = ucontext_t*.  Read both out of the
 * child and print the state that actually faulted, plus FAR/ESR.
 */
static void GuestDumpChildFaultContext(mach_port_t task,
                                       uint64_t infoAddress,
                                       uint64_t contextAddress)
{
    vm_size_t size = 0;
    if (infoAddress != 0) {
        /* Darwin siginfo_t: signo, errno, code, pad, then si_addr. */
        uint64_t faultAddress = 0;
        int32_t fields[3] = { 0, 0, 0 };
        if (vm_read_overwrite(task,
                              (vm_address_t)infoAddress,
                              sizeof(fields),
                              (vm_address_t)fields,
                              &size) == KERN_SUCCESS) {
            GuestLog("[guest] child siginfo signo=%d errno=%d code=%d\n",
                     fields[0], fields[1], fields[2]);
        }
        if (vm_read_overwrite(task,
                              (vm_address_t)(infoAddress + 16),
                              sizeof(faultAddress),
                              (vm_address_t)&faultAddress,
                              &size) == KERN_SUCCESS) {
            GuestLog("[guest] child siginfo addr=0x%llx\n",
                     (unsigned long long)faultAddress);
        }
    }
    if (contextAddress == 0) {
        return;
    }
    uint64_t mcontext = 0;
    if (vm_read_overwrite(task,
                          (vm_address_t)(contextAddress +
                                         offsetof(ucontext_t, uc_mcontext)),
                          sizeof(mcontext),
                          (vm_address_t)&mcontext,
                          &size) != KERN_SUCCESS ||
        mcontext == 0) {
        GuestLog("[guest] child context 0x%llx unreadable\n",
                 (unsigned long long)contextAddress);
        return;
    }

    GuestThreadState64 state;
    if (vm_read_overwrite(task,
                          (vm_address_t)mcontext,
                          sizeof(state),
                          (vm_address_t)&state,
                          &size) != KERN_SUCCESS) {
        GuestLog("[guest] child mcontext 0x%llx unreadable\n",
                 (unsigned long long)mcontext);
        return;
    }

    GuestLog("[guest] child fault pc=0x%llx lr=0x%llx sp=0x%llx "
             "x0=0x%llx x1=0x%llx x2=0x%llx x3=0x%llx "
             "x4=0x%llx x5=0x%llx x6=0x%llx x7=0x%llx\n",
             (unsigned long long)state.pc,
             (unsigned long long)state.lr,
             (unsigned long long)state.sp,
             (unsigned long long)state.x[0],
             (unsigned long long)state.x[1],
             (unsigned long long)state.x[2],
             (unsigned long long)state.x[3],
             (unsigned long long)state.x[4],
             (unsigned long long)state.x[5],
             (unsigned long long)state.x[6],
             (unsigned long long)state.x[7]);

    uint64_t exception[2] = { 0, 0 };
    if (vm_read_overwrite(task,
                          (vm_address_t)(mcontext + sizeof(GuestThreadState64)),
                          sizeof(exception),
                          (vm_address_t)exception,
                          &size) == KERN_SUCCESS) {
        uint32_t esr = (uint32_t)(exception[1] & 0xFFFFFFFFU);
        GuestLog("[guest] child fault far=0x%llx esr=0x%x ec=0x%x\n",
                 (unsigned long long)exception[0],
                 esr,
                 esr >> 26);
    }

    if (GuestWatchdogStage <= 1) {
        GuestDumpWords(task, contextAddress, 16, "ucontext");
        GuestDumpWords(task, mcontext, 40, "mcontext");
    }

    if (state.pc >= 16) {
        uint8_t code[32];
        vm_size_t codeSize = 0;
        if (vm_read_overwrite(task,
                              (vm_address_t)(state.pc - 16),
                              sizeof(code),
                              (vm_address_t)code,
                              &codeSize) == KERN_SUCCESS) {
            const uint32_t *words = (const uint32_t *)code;
            GuestLog("[guest] child fault code: %08x %08x %08x %08x "
                     "%08x %08x %08x %08x\n",
                     words[0], words[1], words[2], words[3],
                     words[4], words[5], words[6], words[7]);
        }
    }
}

/*
 * Fork children of a raw syscall(SYS_fork) sometimes take an instruction
 * abort on the very instruction after the syscall returns, i.e. on this
 * binary's own __TEXT.  Print what the child's page table says about that
 * page so we know whether the mapping is missing, read-only, or fine.
 */
static void GuestProbeRegion(mach_port_t task,
                             uint64_t address,
                             const char *label)
{
    vm_address_t region = (vm_address_t)address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    memset(&info, 0, sizeof(info));
    kern_return_t result = vm_region_64(task,
                                        &region,
                                        &size,
                                        VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info,
                                        &count,
                                        &objectName);
    if (result != KERN_SUCCESS) {
        GuestLog("[guest] region %s 0x%llx: vm_region=%d\n",
                 label,
                 (unsigned long long)address,
                 result);
        return;
    }
    GuestLog("[guest] region %s 0x%llx -> 0x%llx size=0x%llx "
             "prot=%d max=%d shared=%d\n",
             label,
             (unsigned long long)address,
             (unsigned long long)region,
             (unsigned long long)size,
             (int)info.protection,
             (int)info.max_protection,
             (int)info.shared);
    if (objectName != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), objectName);
    }
}

/*
 * When the guest blocks in wait4 after a fork, find out what the child is
 * actually doing: is it stopped/suspended, and where is its program counter?
 */
static void GuestDumpForkChild(const char *tag)
{
    pid_t child = GuestLastForkChild;
    if (child <= 0) {
        return;
    }

    siginfo_t information;
    memset(&information, 0, sizeof(information));
    errno = 0;
    int waitResult = waitid(P_PID,
                            (id_t)child,
                            &information,
                            WEXITED | WSTOPPED | WNOHANG | WNOWAIT);
    int waitError = errno;
    GuestLog("[guest] %s child %d waitid=%d errno=%d code=%d status=%d\n",
             tag,
             child,
             waitResult,
             waitError,
             (int)information.si_code,
             (int)information.si_status);
#ifdef CLD_STOPPED
    if (waitResult == 0 && information.si_code == CLD_STOPPED) {
        kill(child, SIGCONT);
        GuestLog("[guest] %s child %d stopped by signal %d, sent SIGCONT\n",
                 tag,
                 child,
                 (int)information.si_status);
    }
#endif

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t result = task_for_pid(mach_task_self(), child, &task);
    if (result != KERN_SUCCESS) {
        GuestLog("[guest] %s child %d task_for_pid=%d\n", tag, child, result);
        return;
    }

    /*
     * Fork children only get the main executable's __TEXT as read-only, so
     * a stuck child usually means it fell out of the anonymous stub page.
     * Print both mappings; the stub page must stay r-x.
     */
    GuestProbeRegion(task,
                     (uint64_t)(uintptr_t)&GuestSyscallDispatch & ~(uint64_t)0x3FFF,
                     "child code");
    if (GuestForkStub != 0) {
        GuestProbeRegion(task,
                         (uint64_t)(uintptr_t)GuestForkStub & ~(uint64_t)0x3FFF,
                         "child stub");
    }

    struct task_basic_info basic;
    mach_msg_type_number_t basicCount = TASK_BASIC_INFO_COUNT;
    if (task_info(task,
                  TASK_BASIC_INFO,
                  (task_info_t)&basic,
                  &basicCount) == KERN_SUCCESS) {
        GuestLog("[guest] %s child %d suspend=%d resident=%llu\n",
                 tag,
                 child,
                 basic.suspend_count,
                 (unsigned long long)basic.resident_size);
    }

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(task, &threads, &threadCount) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), task);
        return;
    }
    for (mach_msg_type_number_t index = 0;
         index < threadCount && index < 3;
         index++) {
        GuestThreadState64 state;
        mach_msg_type_number_t count = GUEST_ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(threads[index],
                             GUEST_ARM_THREAD_STATE64,
                             (thread_state_t)&state,
                             &count) != KERN_SUCCESS) {
            continue;
        }
        GuestLog("[guest] %s child %d thread %u pc=0x%llx lr=0x%llx "
                 "sp=0x%llx x0=0x%llx x1=0x%llx x2=0x%llx x8=0x%llx\n",
                 tag,
                 child,
                 (unsigned)index,
                 (unsigned long long)state.pc,
                 (unsigned long long)state.lr,
                 (unsigned long long)state.sp,
                 (unsigned long long)state.x[0],
                 (unsigned long long)state.x[1],
                 (unsigned long long)state.x[2],
                 (unsigned long long)state.x[8]);
        if (index == 0) {
            GuestDumpChildFaultContext(task, state.x[1], state.x[2]);
        }
        struct thread_basic_info basicInfo;
        mach_msg_type_number_t infoCount = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[index],
                        THREAD_BASIC_INFO,
                        (thread_info_t)&basicInfo,
                        &infoCount) == KERN_SUCCESS) {
            GuestLog("[guest] %s child %d thread %u run_state=%d "
                     "sleep_time=%d\n",
                     tag,
                     child,
                     (unsigned)index,
                     (int)basicInfo.run_state,
                     (int)basicInfo.sleep_time);
        }
        if (state.pc >= 16) {
            uint8_t code[32];
            vm_size_t codeSize = 0;
            if (vm_read_overwrite(task,
                                  (vm_address_t)(state.pc - 16),
                                  sizeof(code),
                                  (vm_address_t)code,
                                  &codeSize) == KERN_SUCCESS) {
                const uint32_t *words = (const uint32_t *)code;
                GuestLog("[guest] %s child %d code: %08x %08x %08x %08x "
                         "%08x %08x %08x %08x\n",
                         tag,
                         child,
                         words[0], words[1], words[2], words[3],
                         words[4], words[5], words[6], words[7]);
            }
        }
    }
    for (mach_msg_type_number_t index = 0; index < threadCount; index++) {
        mach_port_deallocate(mach_task_self(), threads[index]);
    }
    vm_deallocate(mach_task_self(),
                  (vm_address_t)threads,
                  threadCount * sizeof(thread_act_t));
    mach_port_deallocate(mach_task_self(), task);
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
                                int environmentCount,
                                char *environment[],
                                uintptr_t imageStart,
                                const GuestElfHeader *header,
                                uint64_t entry,
                                uint64_t atBase,
                                uint64_t atEntry,
                                const char *execPath)
{
    (void)entry;
    if (count > 48) {
        count = 48;
    }
    if (environmentCount > 48) {
        environmentCount = 48;
    }

    uint64_t cursor = stackTop & ~0xFULL;
    uint64_t pointers[48];
    for (int index = count - 1; index >= 0; index--) {
        size_t length = strlen(items[index]) + 1;
        cursor = (cursor - length) & ~0xFULL;
        memcpy((void *)cursor, items[index], length);
        pointers[index] = cursor;
    }

    uint64_t environmentPointers[48];
    for (int index = environmentCount - 1; index >= 0; index--) {
        size_t length = strlen(environment[index]) + 1;
        cursor = (cursor - length) & ~0xFULL;
        memcpy((void *)cursor, environment[index], length);
        environmentPointers[index] = cursor;
    }

    size_t execLength = strlen(execPath) + 1;
    cursor = (cursor - execLength) & ~0xFULL;
    memcpy((void *)cursor, execPath, execLength);
    uint64_t execString = cursor;

    cursor = (cursor - 16) & ~0xFULL;
    uint64_t randomAddress = cursor;
    arc4random_buf((void *)randomAddress, 16);

    uint64_t values[][2] = {
        { GUEST_AT_PHDR, (uint64_t)(imageStart + header->e_phoff) },
        { GUEST_AT_PHENT, (uint64_t)header->e_phentsize },
        { GUEST_AT_PHNUM, (uint64_t)header->e_phnum },
        { GUEST_AT_PAGESZ, (uint64_t)GUEST_TARGET_PAGE_SIZE },
        { GUEST_AT_BASE, atBase },
        { GUEST_AT_FLAGS, 0 },
        { GUEST_AT_ENTRY, atEntry },
        { GUEST_AT_UID, (uint64_t)getuid() },
        { GUEST_AT_EUID, (uint64_t)geteuid() },
        { GUEST_AT_GID, (uint64_t)getgid() },
        { GUEST_AT_EGID, (uint64_t)getegid() },
        { GUEST_AT_HWCAP, 0 },
        { GUEST_AT_CLKTCK, 100 },
        { GUEST_AT_SECURE, 0 },
        { GUEST_AT_RANDOM, randomAddress },
        { GUEST_AT_EXECFN, execString },
        { GUEST_AT_NULL, 0 },
    };
    size_t valueCount = sizeof(values) / sizeof(values[0]);

    size_t words = 1 + (size_t)count + 1 + (size_t)environmentCount + 1 +
                   valueCount * 2;
    cursor = (cursor - words * sizeof(uint64_t)) & ~0xFULL;

    uint64_t *table = (uint64_t *)cursor;
    *table++ = (uint64_t)count;
    for (int index = 0; index < count; index++) {
        *table++ = pointers[index];
    }
    *table++ = 0; /* argv terminator */
    for (int index = 0; index < environmentCount; index++) {
        *table++ = environmentPointers[index];
    }
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

static uint8_t *GuestStubPage = NULL;
static BOOL GuestStubSealed = NO;
static uint8_t *GuestTlsIslandCursor = NULL;
static uint8_t *GuestTlsIslandEnd = NULL;
static unsigned long GuestIslandSiteCount = 0;

static uint32_t GuestEncodeAdrp(uint32_t rd, uintptr_t from, uintptr_t to);
static uint32_t GuestEncodeStpPre(uint32_t rt, uint32_t rt2);
static uint32_t GuestEncodeLdpPost(uint32_t rt, uint32_t rt2);

/*
 * svc sites also need their own non-linking island: replacing svc with bl
 * leaves x30 = site+4, and syscall wrappers such as glibc's mprotect() are
 * leaf functions that "ret" through x30 without saving it first.  The
 * island saves the real x30/x16/x17, hands the guest return address to the
 * shared trampoline in x16, then restores everything and jumps back.
 *
 *   site:      b island
 *   island:    stp x16, x17, [sp, #-16]!
 *              str x30, [sp, #-16]!
 *              adrp x16, site+4 page
 *              add  x16, x16, #low12
 *              bl   GuestSyscallTrampoline
 *              ldr  x30, [sp], #16
 *              ldp  x16, x17, [sp], #16
 *              b    site+4
 */
static uintptr_t GuestEmitSvcIsland(uintptr_t site)
{
    if (GuestTlsIslandCursor == NULL ||
        GuestTlsIslandCursor + 32 > GuestTlsIslandEnd) {
        return 0;
    }

    uint8_t *island = GuestTlsIslandCursor;
    uint32_t *code = (uint32_t *)island;
    uintptr_t resume = site + 4;
    uintptr_t trampoline = (uintptr_t)&GuestSyscallTrampoline;

    code[0] = GuestEncodeStpPre(16, 17);
    code[1] = 0xF81F0FFEU; /* str x30, [sp, #-16]! */
    code[2] = GuestEncodeAdrp(16, (uintptr_t)island, resume & ~0xFFFULL);
    code[3] = 0x91000210U | ((resume & 0xFFF) << 10); /* add x16, x16, #imm */
    {
        int64_t delta = (int64_t)(trampoline - (uintptr_t)(island + 16));
        code[4] = 0x94000000U | ((uint32_t)(delta >> 2) & 0x03FFFFFFU);
    }
    code[5] = 0xF84107FEU; /* ldr x30, [sp], #16 */
    code[6] = GuestEncodeLdpPost(16, 17);
    {
        int64_t back = (int64_t)(resume - (uintptr_t)(island + 28));
        code[7] = 0x14000000U | ((uint32_t)(back >> 2) & 0x03FFFFFFU);
    }

    GuestTlsIslandCursor += 32;
    GuestIslandSiteCount++;
    return (uintptr_t)island;
}

/*
 * mrs/msr patches must not use "bl": a bl clobbers x30, and glibc's
 * __ctype_init reads TPIDR_EL0 *before* it saves x30 in its prologue.
 * The function then returns to 0x...ec (our bl's return address) and
 * re-executes its own body with stale registers.  Each mrs site therefore
 * gets its own non-linking island:
 *
 *   site:      b island          (x30 untouched)
 *   island:    adrp xN, shadow
 *              ldr  xN, [xN, #off]
 *              b site+4
 */
static uintptr_t GuestEmitTlsReadIsland(uint32_t rt, uintptr_t site)
{
    if (GuestTlsIslandCursor == NULL ||
        GuestTlsIslandCursor + 16 > GuestTlsIslandEnd) {
        return 0;
    }

    uint8_t *island = GuestTlsIslandCursor;
    uint32_t *code = (uint32_t *)island;
    uintptr_t shadow = (uintptr_t)&GuestTlsPointer;
    uint32_t shadowOffset = (uint32_t)(shadow & 0xFFF);

    code[0] = GuestEncodeAdrp(rt, (uintptr_t)island, shadow);
    code[1] = 0xF9400000U | ((shadowOffset / 8) << 10) | (rt << 5) | rt;

    int64_t delta = (int64_t)((site + 4) - (uintptr_t)(island + 8));
    code[2] = 0x14000000U | ((uint32_t)(delta >> 2) & 0x03FFFFFFU);

    GuestTlsIslandCursor += 16;
    GuestIslandSiteCount++;
    return (uintptr_t)island;
}

/*
 * msr tpidr_el0 is a leaf instruction: a "bl" would set x30 = site+4 and
 * musl's __set_thread_area ends with "ret", looping forever.  The island
 * must therefore branch (not link), preserve x30, and use x16 as scratch
 * (saved/restored around the shadow store).
 *
 *   site:   b island
 *   island: str x16, [sp, #-16]!
 *           adrp x16, shadow
 *           str x<rt>, [x16, #off]
 *           ldr x16, [sp], #16
 *           b   site+4
 */
static uintptr_t GuestEmitTlsWriteIsland(uint32_t rt, uintptr_t site)
{
    if (GuestTlsIslandCursor == NULL ||
        GuestTlsIslandCursor + 32 > GuestTlsIslandEnd) {
        return 0;
    }

    uint8_t *island = GuestTlsIslandCursor;
    uint32_t *code = (uint32_t *)island;
    uintptr_t shadow = (uintptr_t)&GuestTlsPointer;
    uint32_t shadowOffset = (uint32_t)(shadow & 0xFFF);

    code[0] = 0xF81F0FF0U; /* str x16, [sp, #-16]! */
    code[1] = GuestEncodeAdrp(16, (uintptr_t)island, shadow);
    code[2] = 0xF9000000U | ((shadowOffset / 8) << 10) | (16U << 5) | rt;
    code[3] = 0xF84107F0U; /* ldr x16, [sp], #16 */
    {
        int64_t delta = (int64_t)((site + 4) - (uintptr_t)(island + 16));
        code[4] = 0x14000000U | ((uint32_t)(delta >> 2) & 0x03FFFFFFU);
    }

    GuestTlsIslandCursor += 32;
    GuestIslandSiteCount++;
    return (uintptr_t)island;
}

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

void GuestTlsWriteLog(uint64_t value,
                      uint64_t returnAddress,
                      uint64_t block,
                      uint64_t x21,
                      uint64_t x26)
{
    uint64_t imageWord = 0;
    uint64_t tlsWord = 0;
    uint64_t irelValue = 0;
    if (GuestTlsInitImage != 0 && GuestTlsInitSize >= 8) {
        imageWord = *(volatile uint64_t *)GuestTlsInitImage;
    }
    if (value >= GuestImageBase &&
        value + 0x20 <= GuestImageBase + GuestImageSize) {
        tlsWord = *(volatile uint64_t *)(value + 0x10);
    } else if (GuestHeapBase != 0 && value >= GuestHeapBase &&
               value + 0x20 <= GuestHeapEnd) {
        tlsWord = *(volatile uint64_t *)(value + 0x10);
    }
    if (GuestIrelSlot != 0) {
        irelValue = *(volatile uint64_t *)GuestIrelSlot;
    }

    GuestTlsPointer = value;
    GuestLog(
            "[guest] tls write value=0x%llx site=0x%llx dst=0x%llx "
            "src=0x%llx irel=0x%llx addend=0x%llx "
            "x3=0x%llx x21=0x%llx x26=0x%llx\n",
            (unsigned long long)value,
            (unsigned long long)(returnAddress - 4),
            (unsigned long long)tlsWord,
            (unsigned long long)imageWord,
            (unsigned long long)irelValue,
            (unsigned long long)GuestIrelAddend,
            (unsigned long long)block,
            (unsigned long long)x21,
            (unsigned long long)x26);
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
static uint64_t GuestSafeRead64(uint64_t address, kern_return_t *status)
{
    uint64_t value = 0;
    vm_size_t size = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(),
                                             (vm_address_t)address,
                                             sizeof(value),
                                             (vm_address_t)&value,
                                             &size);
    if (status != NULL) {
        *status = result;
    }
    return result == KERN_SUCCESS ? value : 0;
}

void GuestTlsReadLog(uint64_t value, uint64_t returnAddress)
{
    static uint64_t lastValue = 0;
    static unsigned int count = 0;
    if (count < 24 || value != lastValue) {
        count++;
        lastValue = value;

        kern_return_t slotStatus = KERN_FAILURE;
        kern_return_t localeStatus = KERN_FAILURE;
        kern_return_t localesStatus = KERN_FAILURE;
        uint64_t slot = GuestSafeRead64(value + 0x10, &slotStatus);
        uint64_t locale = slotStatus == KERN_SUCCESS
            ? GuestSafeRead64(slot, &localeStatus) : 0;
        uint64_t locales0 = localeStatus == KERN_SUCCESS
            ? GuestSafeRead64(locale, &localesStatus) : 0;
        uint64_t source = 0;
        if (GuestTlsInitImage != 0 && GuestTlsInitSize >= 8) {
            source = *(volatile uint64_t *)GuestTlsInitImage;
        }

        GuestLog(
                "[guest] tls read value=0x%llx site=0x%llx shadow=0x%llx "
                "slot=0x%llx locale=0x%llx locales0=0x%llx src=0x%llx "
                "(%d/%d/%d)\n",
                (unsigned long long)value,
                (unsigned long long)(returnAddress - 4),
                (unsigned long long)GuestTlsPointer,
                (unsigned long long)slot,
                (unsigned long long)locale,
                (unsigned long long)locales0,
                (unsigned long long)source,
                (int)slotStatus,
                (int)localeStatus,
                (int)localesStatus);
    }
}

static void GuestEmitTlsReadStub(uint8_t *stub, uint32_t rt, BOOL log)
{
    uintptr_t shadow = (uintptr_t)&GuestTlsPointer;
    uint32_t shadowOffset = (uint32_t)(shadow & 0xFFF);
    uint32_t *code = (uint32_t *)stub;

    if (!log) {
        code[0] = 0xF81F0FFEU; /* str x30, [sp, #-16]! */
        code[1] = GuestEncodeAdrp(30, (uintptr_t)stub, shadow);
        code[2] = 0xF9400000U | ((shadowOffset / 8) << 10) | (30U << 5) | rt;
        code[3] = 0xF84107FEU; /* ldr x30, [sp], #16 */
        code[4] = 0xD65F03C0U; /* ret */
        return;
    }

    size_t index = 0;
    code[index++] = 0xF81F0FFEU; /* str x30, [sp, #-16]! */
    for (uint32_t pair = 28; pair >= 2; pair -= 2) {
        code[index++] = GuestEncodeStpPre(pair, pair + 1);
    }
    code[index++] = GuestEncodeStpPre(0, 1);
    code[index++] = 0xD53B4209U; /* mrs x9, nzcv */
    code[index++] = 0xF81F0FE9U; /* str x9, [sp, #-16]! */

    code[index++] = 0xAA1E03E1U; /* mov x1, x30 */
    code[index++] = GuestEncodeAdrp(0, (uintptr_t)stub, shadow);
    code[index++] = 0xF9400000U | ((shadowOffset / 8) << 10) | (0U << 5) | 0;
    code[index++] = GuestEncodeAdrp(16, (uintptr_t)stub,
                                    (uintptr_t)&GuestTlsReadLog);
    code[index++] = 0x91000210U |
                    (((uintptr_t)&GuestTlsReadLog & 0xFFF) << 10);
    code[index++] = 0xD63F0200U; /* blr x16 */

    code[index++] = 0xF84107E9U; /* ldr x9, [sp], #16 */
    code[index++] = 0xD51B4209U; /* msr nzcv, x9 */
    code[index++] = GuestEncodeLdpPost(0, 1);
    for (uint32_t pair = 2; pair <= 28; pair += 2) {
        code[index++] = GuestEncodeLdpPost(pair, pair + 1);
    }
    code[index++] = 0xF84107FEU; /* ldr x30, [sp], #16 */
    code[index++] = GuestEncodeAdrp(rt, (uintptr_t)stub, shadow);
    code[index++] = 0xF9400000U | ((shadowOffset / 8) << 10) | (rt << 5) | rt;
    code[index++] = 0xD65F03C0U; /* ret */
}

static void GuestEmitTlsWriteStub(uint8_t *stub, uint32_t rt)
{
    uint32_t *code = (uint32_t *)stub;
    size_t index = 0;

    code[index++] = 0xF81F0FFEU; /* str x30, [sp, #-16]! */
    for (uint32_t pair = 28; pair >= 2; pair -= 2) {
        code[index++] = GuestEncodeStpPre(pair, pair + 1);
    }
    code[index++] = GuestEncodeStpPre(0, 1);
    code[index++] = 0xD53B4209U; /* mrs x9, nzcv */
    code[index++] = 0xF81F0FE9U; /* str x9, [sp, #-16]! */

    code[index++] = 0xAA1E03E1U; /* mov x1, x30 */
    code[index++] = 0xAA0003E0U | (rt << 16); /* mov x0, x<rt> */
    code[index++] = 0xAA0303E2U; /* mov x2, x3 */
    code[index++] = 0xAA1503E3U; /* mov x3, x21 */
    code[index++] = 0xAA1A03E4U; /* mov x4, x26 */
    code[index++] = GuestEncodeAdrp(16, (uintptr_t)stub,
                                    (uintptr_t)&GuestTlsWriteLog);
    code[index++] = 0x91000210U |
                    (((uintptr_t)&GuestTlsWriteLog & 0xFFF) << 10);
    code[index++] = 0xD63F0200U; /* blr x16 */

    code[index++] = 0xF84107E9U; /* ldr x9, [sp], #16 */
    code[index++] = 0xD51B4209U; /* msr nzcv, x9 */
    code[index++] = GuestEncodeLdpPost(0, 1);
    for (uint32_t pair = 2; pair <= 28; pair += 2) {
        code[index++] = GuestEncodeLdpPost(pair, pair + 1);
    }
    code[index++] = 0xF84107FEU; /* ldr x30, [sp], #16 */
    code[index++] = 0xD65F03C0U; /* ret */
}

#define GUEST_STUB_PAGE_SIZE 0x100000
#define GUEST_FORK_EPILOGUE_OFFSET 0x300
#define GUEST_FORK_STUB_OFFSET 0x340
#define GUEST_FORK_MESSAGE_OFFSET 0x3A0

/*
 * A fork child cannot execute this binary's __TEXT (iOS maps it read-only
 * with max_protection read-only in the child), so it must return to the
 * guest through anonymous code only.  Two pieces live in the stub page:
 *
 *   +0x300  a copy of GuestSyscallTrampoline's epilogue (0x4048..0x4080),
 *           which restores x1..x17/x29/x30 from the frame on sp, leaves x0
 *           alone (that is the syscall result), and returns to the island.
 *   +0x340  the fork stub called from GuestSyscallDispatch:
 *             save x29/x30, x19-x22 (the parent path returns to C)
 *             x16 = 2; svc #0x80
 *             carry  -> neg x0, returns -errno to the dispatcher
 *             x0 == 0 -> child: raw-write the marker, x0 = 0, sp = frame,
 *                        branch to the epilogue -> island -> site+4
 *             x0 > 0  -> parent: restore, ret (dispatcher logs the child)
 */
static void GuestEmitForkSupport(uint8_t *base)
{
    uint32_t *epilogue = (uint32_t *)(base + GUEST_FORK_EPILOGUE_OFFSET);
    uint32_t index = 0;
    epilogue[index++] = 0xA9402BE9U; /* ldp x9, x10, [sp] */
    epilogue[index++] = 0xD51BD049U; /* msr tpidr_el0, x9 */
    epilogue[index++] = 0xD51B420AU; /* msr nzcv, x10 */
    epilogue[index++] = 0x910043FFU; /* add sp, sp, #0x10 */
    epilogue[index++] = 0xA8C107E9U; /* ldp x9, x1, [sp], #0x10 */
    epilogue[index++] = 0xA8C10FE2U; /* ldp x2, x3, [sp], #0x10 */
    epilogue[index++] = 0xA8C117E4U; /* ldp x4, x5, [sp], #0x10 */
    epilogue[index++] = 0xA8C11FE6U; /* ldp x6, x7, [sp], #0x10 */
    epilogue[index++] = 0xA8C127E8U; /* ldp x8, x9, [sp], #0x10 */
    epilogue[index++] = 0xA8C12FEAU; /* ldp x10, x11, [sp], #0x10 */
    epilogue[index++] = 0xA8C137ECU; /* ldp x12, x13, [sp], #0x10 */
    epilogue[index++] = 0xA8C13FEEU; /* ldp x14, x15, [sp], #0x10 */
    epilogue[index++] = 0xA8C147F0U; /* ldp x16, x17, [sp], #0x10 */
    epilogue[index++] = 0xA8C17BFDU; /* ldp x29, x30, [sp], #0x10 */
    epilogue[index++] = 0xD65F03C0U; /* ret */

    uint8_t *stub = base + GUEST_FORK_STUB_OFFSET;
    uint32_t *code = (uint32_t *)stub;
    code[0] = 0xA9BF7BFDU;  /* stp x29, x30, [sp, #-16]! */
    code[1] = 0xA9BF53F3U;  /* stp x19, x20, [sp, #-16]! */
    code[2] = 0xA9BF5BF5U;  /* stp x21, x22, [sp, #-16]! */
    code[3] = 0xAA0003F3U;  /* mov x19, x0        ; frame */
    code[4] = 0xAA0103F4U;  /* mov x20, x1        ; resume */
    code[5] = 0xD2800050U;  /* mov x16, #2        ; SYS_fork */
    code[6] = 0xD4001001U;  /* svc #0x80 */
    code[7] = 0x54000043U;  /* b.cc 9 */
    code[8] = 0xCB0003E0U;  /* neg x0, x0         ; carry: errno -> -errno */
    code[9] = 0xB40000A0U;  /* cbz x0, 14         ; child */
    code[10] = 0xA8C15BF5U; /* ldp x21, x22, [sp], #16 */
    code[11] = 0xA8C153F3U; /* ldp x19, x20, [sp], #16 */
    code[12] = 0xA8C17BFDU; /* ldp x29, x30, [sp], #16 */
    code[13] = 0xD65F03C0U; /* ret */
    code[14] = 0xD2800020U; /* mov x0, #1 */
    code[15] = GuestEncodeAdrp(1, (uintptr_t)(stub + 15 * 4), (uintptr_t)base);
    code[16] = 0x91000021U |
               ((uint32_t)GUEST_FORK_MESSAGE_OFFSET << 10); /* add x1 */
    code[17] = 0xD28001E2U; /* mov x2, #15 */
    code[18] = 0xD2800090U; /* mov x16, #4        ; SYS_write */
    code[19] = 0xD4001001U; /* svc #0x80 */
    code[20] = 0xD2800000U; /* mov x0, #0 */
    code[21] = 0x9100027FU; /* mov sp, x19 */
    {
        int64_t delta = (int64_t)((uintptr_t)(base + GUEST_FORK_EPILOGUE_OFFSET) -
                                  (uintptr_t)(stub + 22 * 4));
        code[22] = 0x14000000U | ((uint32_t)(delta >> 2) & 0x03FFFFFFU);
    }

    static const char message[] = "[F] fork child\n";
    memcpy(base + GUEST_FORK_MESSAGE_OFFSET, message, sizeof(message) - 1);
}

#pragma mark - Guest mmap / mprotect for the dynamic linker

#define GUEST_HOST_PAGE_SIZE 0x4000ULL
#define GUEST_MMAP_RECORDS 4096

static struct {
    uintptr_t address;
    size_t length;
} GuestMmapRecords[GUEST_MMAP_RECORDS];
static int GuestMmapRecordCount = 0;

static inline uintptr_t GuestAlignDown(uintptr_t value)
{
    return value & ~(uintptr_t)(GUEST_HOST_PAGE_SIZE - 1);
}

static inline uintptr_t GuestAlignUp(uintptr_t value)
{
    return (value + GUEST_HOST_PAGE_SIZE - 1) &
           ~(uintptr_t)(GUEST_HOST_PAGE_SIZE - 1);
}

static int GuestHostPageProtection(uintptr_t address, int *protection)
{
    vm_address_t region = (vm_address_t)address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    memset(&info, 0, sizeof(info));
    kern_return_t result = vm_region_64(mach_task_self(),
                                        &region,
                                        &size,
                                        VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info,
                                        &count,
                                        &objectName);
    if (objectName != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), objectName);
    }
    if (result != KERN_SUCCESS ||
        (uintptr_t)region > address ||
        (uintptr_t)region + size <= address) {
        return -1;
    }
    *protection = info.protection;
    return 0;
}

/*
 * Host pages are 16KB while the guest thinks in 4KB pages, so a guest
 * mprotect often covers only part of a host page.  Applying the request to
 * the whole 16KB page would silently change the permissions of the
 * neighbouring guest pages; RELRO at a segment boundary used to clear
 * PROT_EXEC from the tail of .text that shared the page.  Fully covered
 * host pages get the exact request, partial edge pages only gain bits.
 */
static int GuestProtectPartialPage(uintptr_t page, int prot)
{
    int current = 0;
    if (GuestHostPageProtection(page, &current) != 0) {
        return -1;
    }
    int merged = current | prot;
    if (merged == current) {
        return 0;
    }
    return mprotect((void *)page, (size_t)GUEST_HOST_PAGE_SIZE, merged);
}

static int GuestProtectRange(uintptr_t address, size_t length, int prot)
{
    if (length == 0) {
        return 0;
    }
    uintptr_t end = address + length;
    if (end < address) {
        return -1;
    }
    /*
     * firstFull/lastFull are the host-page boundaries contained in the guest
     * range.  The previous code started the exact range at
     * "headPage + PAGE", which silently skipped the first page whenever the
     * guest address was already 16KB aligned: whole-file library maps left
     * their first page RW (not executable) and the first call into that page
     * took an instruction-abort permission fault.
     */
    uintptr_t firstFull = GuestAlignUp(address);
    uintptr_t lastFull = GuestAlignDown(end);
    int status = 0;

    if (address < firstFull) {
        status = GuestProtectPartialPage(GuestAlignDown(address), prot);
    }
    if (status == 0 && firstFull < lastFull) {
        status = mprotect((void *)firstFull,
                          (size_t)(lastFull - firstFull),
                          prot);
    }
    if (status == 0 && end > lastFull && lastFull > address) {
        status = GuestProtectPartialPage(lastFull, prot);
    }

    if (status == 0 && (prot & PROT_EXEC) != 0) {
        sys_icache_invalidate((void *)address, length);
    }
    return status;
}

static BOOL GuestRangeOverlapsRuntime(uintptr_t address, size_t length)
{
    if (length == 0) {
        return NO;
    }
    uintptr_t end = address + length;
    if (end < address) {
        return YES;
    }
    struct {
        uintptr_t start;
        size_t length;
    } ranges[] = {
        { GuestImageBase, (size_t)GuestImageSize },
        { GuestInterpBase, (size_t)GuestInterpSize },
        { (uintptr_t)GuestStubPage, GUEST_STUB_PAGE_SIZE },
        { GuestHeapBase, (size_t)(GuestHeapEnd - GuestHeapBase) },
        { (uintptr_t)GuestStackBase, (size_t)GuestStackSize },
    };
    for (size_t index = 0; index < sizeof(ranges) / sizeof(ranges[0]);
         index++) {
        if (ranges[index].start == 0 || ranges[index].length == 0) {
            continue;
        }
        uintptr_t rangeEnd = ranges[index].start + ranges[index].length;
        if (address < rangeEnd && ranges[index].start < end) {
            return YES;
        }
    }
    return NO;
}

/*
 * Ask the kernel whether a range we are about to hand to the guest is really
 * mapped.  A fault landing in "no guest mapping" (0.40.9) means either the
 * address was never backed or it was released while still owned, and both are
 * invisible from our own record table.  Checking at birth turns that into a
 * line in the log naming the size and the caller.
 */
static BOOL GuestRangeIsMapped(uintptr_t address, size_t length)
{
    vm_address_t cursor = (vm_address_t)address;
    vm_address_t end = cursor + (vm_address_t)length;

    while (cursor < end) {
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t result = vm_region_64(mach_task_self(),
                                            &cursor,
                                            &size,
                                            VM_REGION_BASIC_INFO_64,
                                            (vm_region_info_t)&info,
                                            &count,
                                            &object);
        if (result != KERN_SUCCESS || size == 0) {
            return NO;
        }
        cursor += size;
    }
    return YES;
}

static void GuestVerifyMapping(uintptr_t address, size_t length,
                               const char *what)
{
    if (address == 0 || length == 0) {
        return;
    }
    GuestMappingChecks++;
    if (!GuestRangeIsMapped(address, length)) {
        GuestMappingUnbacked++;
        GuestLog("[guest] mapping not backed: 0x%lx len=0x%lx (%s)\n",
                 (unsigned long)address,
                 (unsigned long)length,
                 what);
    }
}

static void GuestRememberMmap(uintptr_t address, size_t length)
{
    if (GuestMmapRecordCount >= GUEST_MMAP_RECORDS) {
        GuestLog("[guest] mmap records full, leaking 0x%lx..0x%lx\n",
                 (unsigned long)address,
                 (unsigned long)(address + length));
        return;
    }
    GuestMmapRecords[GuestMmapRecordCount].address = address;
    GuestMmapRecords[GuestMmapRecordCount].length = length;
    GuestMmapRecordCount++;
}

static void GuestReleaseMmaps(void)
{
    for (int index = 0; index < GuestMmapRecordCount; index++) {
        munmap((void *)GuestMmapRecords[index].address,
               GuestMmapRecords[index].length);
    }
    GuestMmapRecordCount = 0;
}

/*
 * Guest munmap must also free the address for reuse.  Without this, every
 * mmap/munmap cycle burned a fresh 16KB slot out of the 112MB window and a
 * long-running program (apk reading an index over TLS) ran out of space.
 */
static void GuestDescribeAddress(uintptr_t address,
                                 char *buffer,
                                 size_t size)
{
    for (int index = 0; index < GuestMmapRecordCount; index++) {
        uintptr_t start = GuestMmapRecords[index].address;
        uintptr_t end = start + GuestMmapRecords[index].length;
        if (address >= start && address < end) {
            snprintf(buffer, size, "0x%lx+0x%lx (len 0x%lx records=%d)",
                     (unsigned long)start,
                     (unsigned long)(address - start),
                     (unsigned long)GuestMmapRecords[index].length,
                     GuestMmapRecordCount);
            return;
        }
    }
    snprintf(buffer, size, "no guest mapping (records=%d)",
             GuestMmapRecordCount);
}

static void GuestForgetMmap(uintptr_t address, size_t length)
{
    uintptr_t end = address + length;
    for (int index = 0; index < GuestMmapRecordCount; index++) {
        uintptr_t recordStart = GuestMmapRecords[index].address;
        uintptr_t recordEnd = recordStart + GuestMmapRecords[index].length;
        if (recordEnd <= address || recordStart >= end) {
            continue;
        }
        if (recordStart >= address && recordEnd <= end) {
            GuestMmapRecords[index] =
                GuestMmapRecords[GuestMmapRecordCount - 1];
            GuestMmapRecordCount--;
            index--;
            continue;
        }
        if (recordStart < address && recordEnd > end) {
            GuestMmapRecords[index].length = address - recordStart;
            if (GuestMmapRecordCount < GUEST_MMAP_RECORDS) {
                GuestMmapRecords[GuestMmapRecordCount].address = end;
                GuestMmapRecords[GuestMmapRecordCount].length =
                    recordEnd - end;
                GuestMmapRecordCount++;
            }
            continue;
        }
        if (recordStart < address) {
            GuestMmapRecords[index].length = address - recordStart;
        } else {
            GuestMmapRecords[index].address = end;
            GuestMmapRecords[index].length = recordEnd - end;
        }
    }
    if (GuestMmapCursor > address) {
        GuestMmapCursor = GuestAlignDown(address);
    }
}

/*
 * 0.40.13: print the record table at fault time.  "no guest mapping" only
 * says the address is not in the table; the table itself says whether the
 * 64KB block around the fault address was ever recorded, and at what
 * granularity.
 */
static void GuestDumpMmapRecords(void)
{
    char line[192];
    int total = GuestMmapRecordCount;
    int written = snprintf(line, sizeof(line),
                           "[guest] records=%d\n", total);
    if (written > 0) {
        GuestWriteAll(STDOUT_FILENO, line, (size_t)written);
    }
    for (int index = 0; index < total && index < 48; index++) {
        uintptr_t start = GuestMmapRecords[index].address;
        uintptr_t length = GuestMmapRecords[index].length;
        written = snprintf(line, sizeof(line),
                           "[guest] rec[%d] 0x%lx..0x%lx len=0x%lx\n",
                           index,
                           (unsigned long)start,
                           (unsigned long)(start + length),
                           (unsigned long)length);
        if (written > 0) {
            GuestWriteAll(STDOUT_FILENO, line, (size_t)written);
        }
    }
}

static uintptr_t GuestMmapConflictEnd(uintptr_t address, size_t length)
{
    uintptr_t end = address + length;
    uintptr_t conflictEnd = 0;

    uintptr_t runtimeAddresses[] = {
        GuestImageBase,
        GuestInterpBase,
        (uintptr_t)GuestStubPage,
        GuestHeapBase,
        (uintptr_t)GuestStackBase,
    };
    size_t runtimeLengths[] = {
        (size_t)GuestImageSize,
        (size_t)GuestInterpSize,
        GUEST_STUB_PAGE_SIZE,
        (size_t)(GuestHeapEnd - GuestHeapBase),
        (size_t)GuestStackSize,
    };
    for (size_t index = 0;
         index < sizeof(runtimeAddresses) / sizeof(runtimeAddresses[0]);
         index++) {
        if (runtimeAddresses[index] == 0 || runtimeLengths[index] == 0) {
            continue;
        }
        uintptr_t rangeEnd = runtimeAddresses[index] + runtimeLengths[index];
        if (runtimeAddresses[index] < end && address < rangeEnd) {
            if (rangeEnd > conflictEnd) {
                conflictEnd = rangeEnd;
            }
        }
    }

    for (int index = 0; index < GuestMmapRecordCount; index++) {
        uintptr_t recordStart = GuestMmapRecords[index].address;
        uintptr_t recordEnd = recordStart + GuestMmapRecords[index].length;
        if (recordStart < end && address < recordEnd) {
            if (recordEnd > conflictEnd) {
                conflictEnd = recordEnd;
            }
        }
    }
    return conflictEnd;
}

static uintptr_t GuestFindMmapGap(uintptr_t start,
                                  uintptr_t limit,
                                  size_t length)
{
    uintptr_t candidate = GuestAlignUp(start);
    while (candidate + length > candidate && candidate + length <= limit) {
        uintptr_t conflictEnd = GuestMmapConflictEnd(candidate, length);
        if (conflictEnd == 0) {
            /*
             * Records only cover our own guest mappings.  Also ask the host
             * so we never MAP_FIXED over the runner's own __TEXT, dylibs or
             * malloc arenas.
             */
            if (GuestRangeFree(candidate, length)) {
                return candidate;
            }
            conflictEnd = candidate + GUEST_HOST_PAGE_SIZE;
        }
        if (conflictEnd <= candidate) {
            conflictEnd = candidate + GUEST_HOST_PAGE_SIZE;
        }
        candidate = GuestAlignUp(conflictEnd);
    }
    return 0;
}

/*
 * Guest mmaps must stay within branch range of the island page.  Anonymous
 * mappings are also placed here so a later MAP_FIXED (e.g. musl's BSS tail)
 * does not land somewhere unpredictable.
 */
static uintptr_t GuestAllocateMmapAddress(size_t length,
                                          uintptr_t hint,
                                          BOOL fixed)
{
    length = GuestAlignUp(length);
    if (length == 0) {
        return 0;
    }
    if (fixed) {
        return hint;
    }
    if (hint != 0 &&
        (hint & (GUEST_HOST_PAGE_SIZE - 1)) == 0 &&
        !GuestRangeOverlapsRuntime(hint, length) &&
        GuestRangeFree(hint, length)) {
        return hint;
    }

    uintptr_t windowStart = GuestAlignUp(GuestImageBase + GuestImageSize);
    if (GuestStubPage != NULL) {
        uintptr_t stubEnd = (uintptr_t)GuestStubPage + GUEST_STUB_PAGE_SIZE;
        if (stubEnd > windowStart) {
            windowStart = stubEnd;
        }
    }
    uintptr_t limit = GuestStubPage != NULL
        ? (uintptr_t)GuestStubPage + 0x07000000ULL
        : windowStart + 0x07000000ULL;

    uintptr_t start = GuestMmapCursor;
    if (start < windowStart) {
        start = windowStart;
    }
    uintptr_t candidate = GuestFindMmapGap(start, limit, length);
    if (candidate == 0 && start > windowStart) {
        /* Wrap: freed holes below the cursor are reusable too. */
        candidate = GuestFindMmapGap(windowStart, start + length, length);
    }
    if (candidate == 0) {
        GuestLog("[guest] mmap: no free guest address near stub"
                 " (len=0x%lx cursor=0x%lx window=0x%lx..0x%lx records=%d)\n",
                 (unsigned long)length,
                 (unsigned long)GuestMmapCursor,
                 (unsigned long)windowStart,
                 (unsigned long)limit,
                 GuestMmapRecordCount);
        return 0;
    }
    GuestMmapCursor = candidate + length;
    return candidate;
}

static ssize_t GuestCopyFromFile(int descriptor,
                                 void *buffer,
                                 size_t length,
                                 off_t offset)
{
    uint8_t *bytes = (uint8_t *)buffer;
    size_t done = 0;
    while (done < length) {
        ssize_t got = pread(descriptor,
                            bytes + done,
                            length - done,
                            offset + (off_t)done);
        if (got <= 0) {
            break;
        }
        done += (size_t)got;
    }
    return (ssize_t)done;
}

/*
 * Rewrite svc / mrs tpidr_el0 / msr tpidr_el0 inside one executable range.
 * The island page is sealed RX for normal execution; temporarily reopen it
 * while new sites are emitted (this happens when ld.so maps a library).
 */
static int GuestPatchCodeRange(uintptr_t start,
                               uint64_t length,
                               uint32_t *patched,
                               uint32_t *tlsReads,
                               uint32_t *tlsWrites)
{
    BOOL wasSealed = GuestStubSealed;
    if (wasSealed) {
        GuestUnsealStubPage();
    }

    int status = 0;
    for (uint64_t offset = 0; offset + 4 <= length; offset += 4) {
        uint32_t instruction = *(uint32_t *)(start + offset);
        uintptr_t destination = 0;
        BOOL linked = YES;

        if (instruction == 0xD4000001) {
            destination = GuestEmitSvcIsland(start + offset);
            if (destination == 0) {
                GuestLog("[guest] svc island space exhausted\n");
                status = -1;
                break;
            }
            linked = NO;
            (*patched)++;
        } else if ((instruction & 0xFFFFFFE0U) == 0xD53BD040U) {
            uint32_t rt = instruction & 0x1F;
            if (rt >= GUEST_TLS_STUB_COUNT) {
                GuestLog("[guest] mrs tpidr_el0, x%u is unsupported\n", rt);
                status = -1;
                break;
            }
            destination = GuestEmitTlsReadIsland(rt, start + offset);
            if (destination == 0) {
                GuestLog("[guest] tls island space exhausted\n");
                status = -1;
                break;
            }
            linked = NO;
            (*tlsReads)++;
        } else if ((instruction & 0xFFFFFFE0U) == 0xD51BD040U) {
            uint32_t rt = instruction & 0x1F;
            if (rt >= GUEST_TLS_STUB_COUNT) {
                GuestLog("[guest] msr tpidr_el0, x%u is unsupported\n", rt);
                status = -1;
                break;
            }
            /*
             * Non-linking island: the shared write stub is entered with bl,
             * which already clobbers x30; musl's __set_thread_area is a leaf
             * ending in ret and would loop on site+4.
             */
            destination = GuestEmitTlsWriteIsland(rt, start + offset);
            if (destination == 0) {
                GuestLog("[guest] tls write island space exhausted\n");
                status = -1;
                break;
            }
            linked = NO;
            (*tlsWrites)++;
        } else {
            continue;
        }

        int64_t delta = (int64_t)(destination - (uintptr_t)(start + offset));
        if (delta < -(1LL << 27) || delta >= (1LL << 27)) {
            GuestLog("[guest] patch site=0x%lx out of branch range\n",
                     (unsigned long)(start + offset));
            status = -1;
            break;
        }
        uint32_t immediate = ((uint32_t)(delta >> 2)) & 0x03FFFFFFU;
        *(uint32_t *)(start + offset) =
            (linked ? 0x94000000U : 0x14000000U) | immediate;
    }

    if (wasSealed) {
        GuestSealStubPage();
    }
    return status;
}

/*
 * Patch the executable parts of an ELF file that was just copied into guest
 * memory.  The mapping starts at "mapAddress" and holds file bytes starting
 * at "fileOffset"; ld.so maps the whole library first and later re-maps each
 * PT_LOAD, so both whole-file and segment-sized mappings are handled.
 */
static int GuestPatchMappedElf(int descriptor,
                               uint64_t fileOffset,
                               uintptr_t mapAddress,
                               size_t mapLength,
                               uint32_t *patched,
                               uint32_t *tlsReads,
                               uint32_t *tlsWrites)
{
    GuestElfHeader header;
    if (pread(descriptor, &header, sizeof(header), 0) !=
        (ssize_t)sizeof(header)) {
        return 0;
    }
    if (memcmp(header.e_ident, "\x7f""ELF", 4) != 0 ||
        header.e_ident[4] != 2 ||
        header.e_machine != ELF_EM_AARCH64 ||
        header.e_phentsize != sizeof(GuestElfProgramHeader) ||
        header.e_phnum == 0 ||
        header.e_phnum > 32) {
        return 0;
    }

    GuestElfProgramHeader programs[32];
    size_t programBytes =
        (size_t)header.e_phnum * sizeof(GuestElfProgramHeader);
    if (pread(descriptor,
              programs,
              programBytes,
              (off_t)header.e_phoff) != (ssize_t)programBytes) {
        return 0;
    }

    uint64_t mapStart = fileOffset;
    uint64_t mapEnd = fileOffset + mapLength;
    for (uint16_t index = 0; index < header.e_phnum; index++) {
        const GuestElfProgramHeader *program = &programs[index];
        if (program->p_type != ELF_PT_LOAD ||
            (program->p_flags & ELF_PF_X) == 0 ||
            program->p_filesz < 4) {
            continue;
        }
        uint64_t segmentStart = program->p_offset;
        uint64_t segmentEnd = program->p_offset + program->p_filesz;
        uint64_t from = segmentStart > mapStart ? segmentStart : mapStart;
        uint64_t to = segmentEnd < mapEnd ? segmentEnd : mapEnd;
        if (to <= from || to - from < 4) {
            continue;
        }
        uintptr_t start = mapAddress + (uintptr_t)(from - mapStart);
        if (GuestPatchCodeRange(start,
                                to - from,
                                patched,
                                tlsReads,
                                tlsWrites) != 0) {
            return -1;
        }
    }
    return 0;
}

/*
 * Make [address, address+length) writable at host page granularity without
 * replacing pages that already exist: a 4KB guest range may share its 16KB
 * host page with a neighbouring guest mapping whose bytes and permissions
 * must survive.  Only genuinely unmapped host pages are created.
 */
static int GuestEnsureWritable(uintptr_t address, size_t length)
{
    static unsigned createdPages = 0;
    uintptr_t end = address + length;
    for (uintptr_t page = GuestAlignDown(address);
         page < end;
         page += GUEST_HOST_PAGE_SIZE) {
        int current = 0;
        if (GuestHostPageProtection(page, &current) != 0) {
            void *map = mmap((void *)page,
                             (size_t)GUEST_HOST_PAGE_SIZE,
                             PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANON | MAP_FIXED,
                             -1,
                             0);
            if (map == MAP_FAILED) {
                return -1;
            }
            /*
             * 0.40.13: this is the only place that creates a mapping without
             * going through GuestHandleMmap, so it is the only candidate for
             * a range that exists in the kernel but in no record.
             */
            if (createdPages < 20) {
                createdPages++;
                GuestLog("[guest] ensure-writable created page 0x%lx\n",
                         (unsigned long)page);
            }
            continue;
        }
        if ((current & PROT_WRITE) == 0 &&
            mprotect((void *)page,
                     (size_t)GUEST_HOST_PAGE_SIZE,
                     current | PROT_WRITE) != 0) {
            return -1;
        }
    }
    return 0;
}

static uint64_t GuestHandleFixedAnon(uintptr_t address,
                                     size_t length,
                                     int prot)
{
    if (GuestEnsureWritable(address, length) != 0) {
        return GuestErrno();
    }
    /*
     * 0.40.12: this path used to change permissions and memset without ever
     * telling the record table.  Everything downstream then treated the range
     * as unowned -- GuestReleaseGuestPages() would unmap it on the next
     * munmap, and the fault reporter printed "no guest mapping" for a range
     * that was in active use.  Record it before touching the bytes.
     */
    GuestRememberMmap(address, length);
    GuestVerifyMapping(address, length, "fixed anon");
    if (address >= GuestHeapBase && address < GuestBrkCurrent) {
        /*
         * The guest is replacing pages it already handed out to itself.  On
         * Linux that is legal (MAP_FIXED replaces), but if this ever lands on
         * live heap our memset below silently destroys it, so make it visible.
         */
        GuestMmapFixedBelowBrk++;
        GuestLog("[guest] fixed anon below brk addr=0x%lx len=0x%lx"
                 " brk=0x%lx\n",
                 (unsigned long)address,
                 (unsigned long)length,
                 (unsigned long)GuestBrkCurrent);
    }
    memset((void *)address, 0, length);
    if (GuestProtectRange(address, length, prot) != 0) {
        return GuestErrno();
    }
    GuestLog("[guest] mmap anon fixed 0x%lx..0x%lx in host page 0x%lx\n",
             (unsigned long)address,
             (unsigned long)(address + length),
             (unsigned long)GuestAlignDown(address));
    return (uint64_t)address;
}

static uint64_t GuestHandleFileMap(int descriptor,
                                   uint64_t fileOffset,
                                   uintptr_t address,
                                   size_t length,
                                   int prot,
                                   BOOL remember)
{
    /*
     * address == 0 means "the island window is full, let the host choose".
     * Such a mapping can still hold data files (they contain no svc sites);
     * if the file does need patching, GuestPatchCodeRange rejects it because
     * the island is out of branch range, and we report -ENOEXEC as before.
     */
    void *map = NULL;
    if (address == 0) {
        map = mmap(NULL,
                   length,
                   PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON,
                   -1,
                   0);
        if (map != MAP_FAILED) {
            address = (uintptr_t)map;
        }
    } else {
        map = mmap((void *)address,
                   length,
                   PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON | MAP_FIXED,
                   -1,
                   0);
    }
    if (map == MAP_FAILED) {
        return GuestErrno();
    }

    GuestCopyFromFile(descriptor, map, length, (off_t)fileOffset);

    uint32_t patched = 0;
    uint32_t tlsReads = 0;
    uint32_t tlsWrites = 0;
    if (GuestPatchMappedElf(descriptor,
                            fileOffset,
                            address,
                            length,
                            &patched,
                            &tlsReads,
                            &tlsWrites) != 0) {
        munmap(map, length);
        return (uint64_t)(-ENOEXEC);
    }
    if (patched != 0 || tlsReads != 0 || tlsWrites != 0) {
        sys_icache_invalidate((void *)address, length);
        GuestLog("[guest] mmap elf off=0x%llx addr=0x%lx len=0x%lx "
                 "patched=%u mrs=%u msr=%u\n",
                 (unsigned long long)fileOffset,
                 (unsigned long)address,
                 (unsigned long)length,
                 patched,
                 tlsReads,
                 tlsWrites);
    }

    if (GuestProtectRange(address, length, prot) != 0) {
        int error = errno;
        munmap(map, length);
        return (uint64_t)(-error);
    }
    if (remember) {
        GuestVerifyMapping(address, length, "file map");
        GuestRememberMmap(address, length);
    }
    return (uint64_t)address;
}

static uint64_t GuestHandleFixedFileMap(int descriptor,
                                        uint64_t fileOffset,
                                        uintptr_t address,
                                        size_t length,
                                        int prot)
{
    /*
     * ld.so already mapped the whole file, so this MAP_FIXED only needs to
     * overlay the segment and make it writable.  The guest range can start
     * or end in the middle of a 16KB host page; remapping the rounded range
     * used to hit unmapped pages (ENOMEM) and also discarded the
     * neighbouring segment's bytes and permissions.
     */
    if (GuestEnsureWritable(address, length) != 0) {
        return GuestErrno();
    }

    memset((void *)address, 0, length);
    GuestCopyFromFile(descriptor, (void *)address, length, (off_t)fileOffset);

    uint32_t patched = 0;
    uint32_t tlsReads = 0;
    uint32_t tlsWrites = 0;
    if (GuestPatchMappedElf(descriptor,
                            fileOffset,
                            address,
                            length,
                            &patched,
                            &tlsReads,
                            &tlsWrites) != 0) {
        return (uint64_t)(-ENOEXEC);
    }
    if (patched != 0 || tlsReads != 0 || tlsWrites != 0) {
        sys_icache_invalidate((void *)address, length);
        GuestLog("[guest] mmap elf fixed off=0x%llx addr=0x%lx len=0x%lx "
                 "patched=%u mrs=%u msr=%u\n",
                 (unsigned long long)fileOffset,
                 (unsigned long)address,
                 (unsigned long)length,
                 patched,
                 tlsReads,
                 tlsWrites);
    }

    if (GuestProtectRange(address, length, prot) != 0) {
        return GuestErrno();
    }
    return (uint64_t)address;
}

static uint64_t GuestHandleMmap(uint64_t hint,
                                uint64_t length,
                                int prot,
                                uint64_t guestFlags,
                                int descriptor,
                                uint64_t offset)
{
    static unsigned int mmapTrace = 0;
    size_t requested = (size_t)length;
    size_t mapLength = GuestAlignUp(requested);
    if (requested == 0 || mapLength < requested) {
        return (uint64_t)(-EINVAL);
    }

    BOOL anonymous = (guestFlags & 0x20) != 0;
    BOOL fixed = (guestFlags & 0x10) != 0;
    uint64_t result = 0;

    if (anonymous) {
        int flags = 0;
        if (guestFlags & 0x01) {
            flags |= MAP_SHARED;
        }
        if (guestFlags & 0x02) {
            flags |= MAP_PRIVATE;
        }
        if ((flags & (MAP_SHARED | MAP_PRIVATE)) == 0) {
            flags |= MAP_PRIVATE;
        }
        flags |= MAP_ANON;
        if (guestFlags & 0x4000) {
            flags |= MAP_NORESERVE;
        }

        uintptr_t target = (uintptr_t)hint;
        if (fixed) {
            if (GuestRangeOverlapsRuntime(target, mapLength)) {
                /*
                 * Linux honours MAP_FIXED unconditionally; we refuse anything
                 * that collides with the runtime image, island, heap or
                 * stack.  musl asks for a 4KB PROT_NONE meta area at brk on
                 * every run, so record the exact request plus the heap state
                 * to tell "unused tail" from "already used heap".
                 */
                GuestMmapFixedRejected++;
                GuestLog("[guest] mmap fixed overlaps runtime: 0x%lx"
                         " len=0x%lx prot=0x%x flags=0x%llx"
                         " brk=0x%lx heap=0x%lx..0x%lx\n",
                         (unsigned long)target,
                         (unsigned long)requested,
                         prot,
                         (unsigned long long)guestFlags,
                         (unsigned long)GuestBrkCurrent,
                         (unsigned long)GuestHeapBase,
                         (unsigned long)GuestHeapEnd);
                return (uint64_t)(-EINVAL);
            }
            result = GuestHandleFixedAnon(target, requested, prot);
            goto trace;
        }
        /*
         * Anonymous data mappings never contain rewritten code, so they do
         * not need to live within branch range of the island.  Let the host
         * choose the address instead: apk keeps tens of megabytes of index
         * data live at once and the 112MB island window also has to hold the
         * 64MB heap, the 8MB stack and the dynamic linker.
         *
         * One extra PROT_NONE host page is appended after every mapping.  The
         * remaining inflate() data errors happen with byte-exact input and on
         * both zlib versions, so the working theory is a write just past some
         * heap mapping; the guard turns that into an immediate SIGSEGV with a
         * precise pc instead of silently corrupting a neighbour.  The guard is
         * intentionally not recorded: munmap() releases only the guest's
         * pages and the guard page stays behind (16KB of leaked address space
         * per mapping, acceptable for one apk run).
         */
        void *map = mmap(NULL,
                         mapLength + GUEST_HOST_PAGE_SIZE,
                         PROT_READ | PROT_WRITE,
                         flags,
                         -1,
                         0);
        if (map == MAP_FAILED) {
            return GuestErrno();
        }
        target = (uintptr_t)map;
        if (GuestProtectRange(target, mapLength, prot) != 0 ||
            mprotect((void *)(target + mapLength),
                     (size_t)GUEST_HOST_PAGE_SIZE,
                     PROT_NONE) != 0) {
            int error = errno;
            munmap(map, mapLength + GUEST_HOST_PAGE_SIZE);
            return (uint64_t)(-error);
        }
        GuestVerifyMapping(target, mapLength, "anon map");
        GuestRememberMmap(target, mapLength);
        GuestCanaryPlace(target, requested, mapLength);
        GuestRecordMmapSize(requested);
        result = (uint64_t)target;
    } else {
        if (descriptor < 0) {
            return (uint64_t)(-EBADF);
        }
        if (fixed) {
            if (GuestRangeOverlapsRuntime((uintptr_t)hint, mapLength)) {
                GuestMmapFixedRejected++;
                GuestLog("[guest] mmap fixed overlaps runtime: 0x%lx"
                         " len=0x%lx prot=0x%x flags=0x%llx fd=%d off=0x%llx\n",
                         (unsigned long)hint,
                         (unsigned long)requested,
                         prot,
                         (unsigned long long)guestFlags,
                         descriptor,
                         (unsigned long long)offset);
                return (uint64_t)(-EINVAL);
            }
            result = GuestHandleFixedFileMap(descriptor,
                                             offset,
                                             (uintptr_t)hint,
                                             requested,
                                             prot);
        } else if ((prot & PROT_EXEC) == 0 &&
                   (offset & (GUEST_HOST_PAGE_SIZE - 1)) == 0 &&
                   !GuestFileIsElf(descriptor)) {
            /*
             * apk extracts every file larger than 128KB by mapping the
             * *destination* file MAP_SHARED and writing straight into it
             * (src/io.c: apk_istream_splice).  Emulating that with an
             * anonymous copy loses the writes, so data mappings with a
             * host-page-aligned offset are passed to Darwin verbatim; the
             * kernel then flushes them back to the file on munmap.
             */
            int hostProt = prot & (PROT_READ | PROT_WRITE);
            int hostFlags = (guestFlags & 0x01) ? MAP_SHARED : MAP_PRIVATE;
            void *direct = mmap(NULL,
                                mapLength,
                                hostProt,
                                hostFlags,
                                descriptor,
                                (off_t)offset);
            if (direct != MAP_FAILED) {
                GuestRememberMmap((uintptr_t)direct, mapLength);
                result = (uint64_t)(uintptr_t)direct;
                goto trace;
            }
            GuestLog("[guest] direct file mmap failed fd=%d off=0x%llx"
                     " len=0x%lx errno=%d\n",
                     descriptor,
                     (unsigned long long)offset,
                     (unsigned long)mapLength,
                     errno);
            uintptr_t target = GuestAllocateMmapAddress(mapLength,
                                                        (uintptr_t)hint,
                                                        NO);
            if (target == 0) {
                /*
                 * The window is fragmented.  Data files do not need to be
                 * within branch range of the island, so let the host place
                 * them; anything that turns out to need patching is rejected
                 * by the range check inside GuestPatchCodeRange.
                 */
                GuestLog("[guest] file map outside window len=0x%lx\n",
                         (unsigned long)mapLength);
                result = GuestHandleFileMap(descriptor,
                                            offset,
                                            0,
                                            mapLength,
                                            prot,
                                            YES);
            } else {
                result = GuestHandleFileMap(descriptor,
                                            offset,
                                            target,
                                            mapLength,
                                            prot,
                                            YES);
            }
        } else {
            uintptr_t target = GuestAllocateMmapAddress(mapLength,
                                                        (uintptr_t)hint,
                                                        NO);
            if (target == 0) {
                GuestLog("[guest] file map outside window len=0x%lx\n",
                         (unsigned long)mapLength);
                result = GuestHandleFileMap(descriptor,
                                            offset,
                                            0,
                                            mapLength,
                                            prot,
                                            YES);
            } else {
                result = GuestHandleFileMap(descriptor,
                                            offset,
                                            target,
                                            mapLength,
                                            prot,
                                            YES);
            }
        }
    }

trace:
    if (mmapTrace < 12) {
        mmapTrace++;
        GuestLog("[guest] mmap addr=0x%llx len=0x%llx prot=0x%x "
                 "flags=0x%llx fd=%d off=0x%llx -> 0x%llx\n",
                 (unsigned long long)hint,
                 (unsigned long long)length,
                 prot,
                 (unsigned long long)guestFlags,
                 descriptor,
                 (unsigned long long)offset,
                 (unsigned long long)result);
    }
    return result;
}

static BOOL GuestPageIsRuntime(uintptr_t page)
{
    uintptr_t pageEnd = page + GUEST_HOST_PAGE_SIZE;
    struct {
        uintptr_t start;
        size_t length;
    } ranges[] = {
        { GuestImageBase, (size_t)GuestImageSize },
        { GuestInterpBase, (size_t)GuestInterpSize },
        { (uintptr_t)GuestStubPage, GUEST_STUB_PAGE_SIZE },
        { GuestHeapBase, (size_t)(GuestHeapEnd - GuestHeapBase) },
        { (uintptr_t)GuestStackBase, (size_t)GuestStackSize },
    };
    for (size_t index = 0; index < sizeof(ranges) / sizeof(ranges[0]);
         index++) {
        if (ranges[index].start == 0 || ranges[index].length == 0) {
            continue;
        }
        if (pageEnd > ranges[index].start &&
            page < ranges[index].start + ranges[index].length) {
            return YES;
        }
    }
    return NO;
}

/*
 * A page may only be released when the guest's request covers it completely
 * AND every record touching that page lies entirely inside the request.
 *
 * 0.40.12: the order used to be "forget the records first, then unmap every
 * page that has no record left".  A 4KB free inside a 64KB allocation
 * therefore trimmed the record down to the remaining 16KB pages, left the
 * first page unowned by construction, and unmapped it -- while the rest of
 * that allocation (zlib's inflate_state and its 32KB window) stayed live and
 * kept writing.  The fault reporter then printed "no guest mapping" for a
 * page that had been in active use.  Inspect the records against the request
 * before touching either.
 */
static BOOL GuestPageRecordsFitRequest(uintptr_t page,
                                       uintptr_t requestStart,
                                       uintptr_t requestEnd)
{
    uintptr_t pageEnd = page + GUEST_HOST_PAGE_SIZE;
    BOOL found = NO;

    for (int index = 0; index < GuestMmapRecordCount; index++) {
        uintptr_t start = GuestMmapRecords[index].address;
        uintptr_t end = start + GuestMmapRecords[index].length;
        if (end <= page || start >= pageEnd) {
            continue;
        }
        found = YES;
        if (start < requestStart || end > requestEnd) {
            return NO;
        }
    }
    /*
     * No record at all means we cannot prove the page is ours.  Keeping it
     * leaks one page; releasing it risks somebody else's live buffer, and the
     * guard page appended to every anonymous mapping lands in exactly this
     * category.
     */
    return found;
}

static void GuestReleaseGuestPages(uintptr_t address, size_t length)
{
    if (length == 0) {
        return;
    }
    uintptr_t scanStart = GuestAlignDown(address);
    uintptr_t scanEnd = GuestAlignUp(address + length);
    uintptr_t requestStart = GuestAlignUp(address);
    uintptr_t requestEnd = GuestAlignDown(address + length);

    if (scanEnd <= scanStart) {
        return;
    }
    GuestRememberFreed(scanStart, scanEnd - scanStart);

    for (uintptr_t page = scanStart; page < scanEnd;
         page += GUEST_HOST_PAGE_SIZE) {
        BOOL covered = requestStart <= page &&
                       page + GUEST_HOST_PAGE_SIZE <= requestEnd;
        if (!covered || GuestPageIsRuntime(page) ||
            !GuestPageRecordsFitRequest(page, requestStart, requestEnd)) {
            GuestMunmapKeptPages++;
            continue;
        }
        if (munmap((void *)page, GUEST_HOST_PAGE_SIZE) == 0) {
            GuestMunmapReleasedPages++;
            GuestForgetMmap(page, GUEST_HOST_PAGE_SIZE);
        } else {
            GuestMunmapKeptPages++;
        }
    }
}

static uint64_t GuestHandleMunmap(uintptr_t address, size_t length)
{
    if (length == 0) {
        return (uint64_t)(-EINVAL);
    }
    GuestCanaryCheck(address);
    GuestReleaseGuestPages(address, length);
    return 0;
}

/*
 * musl's mallocng grows mmap-backed allocations with
 * mremap(MREMAP_MAYMOVE) -- apk's package index arrays hit this while
 * parsing APKINDEX.  Darwin has no mremap, so emulate it by copying into a
 * fresh anonymous mapping.  Only anonymous data is remapped here, so the
 * new mapping does not need to live within branch range of the island.
 */
static uint64_t GuestHandleMremap(uintptr_t oldAddress,
                                  size_t oldLength,
                                  size_t newLength,
                                  uint64_t flags,
                                  uintptr_t newAddress)
{
    (void)newAddress;
    if (oldAddress == 0 || oldLength == 0 || newLength == 0) {
        return (uint64_t)(-EINVAL);
    }
    if ((oldAddress & 0xFFF) != 0) {
        return (uint64_t)(-EINVAL);
    }
    if ((flags & 0x2) != 0) {
        /* MREMAP_FIXED: musl does not use it; refuse instead of corrupting. */
        return (uint64_t)(-EINVAL);
    }
    size_t oldMapLength = GuestAlignUp(oldLength);
    size_t newMapLength = GuestAlignUp(newLength);
    if (newMapLength < newLength) {
        return (uint64_t)(-EINVAL);
    }
    if (newLength <= oldLength && (flags & 0x1) == 0) {
        return (uint64_t)oldAddress;
    }

    void *map = mmap(NULL,
                     newMapLength + GUEST_HOST_PAGE_SIZE,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANON,
                     -1,
                     0);
    if (map == MAP_FAILED) {
        return GuestErrno();
    }
    if (mprotect((void *)((uintptr_t)map + newMapLength),
                 (size_t)GUEST_HOST_PAGE_SIZE,
                 PROT_NONE) != 0) {
        int error = errno;
        munmap(map, newMapLength + GUEST_HOST_PAGE_SIZE);
        return (uint64_t)(-error);
    }
    size_t copyLength = oldLength < newLength ? oldLength : newLength;
    memcpy(map, (void *)oldAddress, copyLength);
    GuestCanaryCheck(oldAddress);
    /*
     * 0.40.12: this used to call the host munmap() directly with the rounded
     * old length, bypassing the page-aware release that 0.40.6 added for
     * munmap().  A mremap that moved a sub-page range could therefore tear
     * down a 16KB host page another live allocation still shared.  The new
     * mapping is already in place, so a page we decline to release only leaks
     * address space.
     */
    GuestReleaseGuestPages(oldAddress, oldMapLength);
    GuestVerifyMapping((uintptr_t)map, newMapLength, "mremap");
    GuestRememberMmap((uintptr_t)map, newMapLength);
    GuestCanaryPlace((uintptr_t)map, newLength, newMapLength);
    return (uint64_t)(uintptr_t)map;
}

static uint64_t GuestHandleMprotect(uintptr_t address,
                                    size_t length,
                                    int prot)
{
    if (length == 0) {
        return 0;
    }
    if ((address & (GUEST_HOST_PAGE_SIZE - 1)) == 0 &&
        (length & (GUEST_HOST_PAGE_SIZE - 1)) == 0) {
        if (mprotect((void *)address, length, prot) == 0) {
            if ((prot & PROT_EXEC) != 0) {
                sys_icache_invalidate((void *)address, length);
            }
            return 0;
        }
    }
    if (GuestProtectRange(address, length, prot) == 0) {
        GuestLog("[guest] mprotect 0x%lx..0x%lx host pages from 0x%lx\n",
                 (unsigned long)address,
                 (unsigned long)(address + length),
                 (unsigned long)GuestAlignDown(address));
        return 0;
    }
    return GuestErrno();
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
        if (!GuestRangeFree(candidate, GUEST_STUB_PAGE_SIZE)) {
            continue;
        }

        uint8_t *page = mmap((void *)candidate,
                             GUEST_STUB_PAGE_SIZE,
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
            uint8_t *readStub = page + 0x400 + rt * 0xC0;
            uint8_t *writeStub = page + 0x1A00 + rt * 0xC0;
            GuestEmitTlsReadStub(readStub, rt, rt == 0 ? YES : NO);
            GuestEmitTlsWriteStub(writeStub, rt);
            GuestTlsReadStubs[rt] = (uintptr_t)readStub;
            GuestTlsWriteStubs[rt] = (uintptr_t)writeStub;
        }

        GuestEmitForkSupport(page);
        GuestForkStub = (uintptr_t)(page + GUEST_FORK_STUB_OFFSET);

        /*
         * Keep the page writable: per-site mrs islands are emitted while
         * the image is being patched, then sealed by GuestSealStubPage().
         */
        GuestStubPage = page;
        GuestStubSealed = NO;
        GuestTlsIslandCursor = page + 0x4000;
        GuestTlsIslandEnd = page + GUEST_STUB_PAGE_SIZE;
        GuestIslandSiteCount = 0;
        GuestMmapCursor = 0;

        const uint32_t *readStub =
            (const uint32_t *)GuestTlsReadStubs[0];
        const uint32_t *writeStub =
            (const uint32_t *)GuestTlsWriteStubs[19];
        GuestLog(
                "[guest] fork stub=0x%lx epilogue=0x%lx\n",
                (unsigned long)GuestForkStub,
                (unsigned long)(page + GUEST_FORK_EPILOGUE_OFFSET));
        GuestLog(
                "[guest] tls stubs: read0=0x%lx code=%08x %08x %08x %08x %08x\n",
                (unsigned long)GuestTlsReadStubs[0],
                readStub[0],
                readStub[1],
                readStub[2],
                readStub[3],
                readStub[4]);
        GuestLog(
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

static void GuestSealStubPage(void)
{
    if (GuestStubPage == NULL) {
        return;
    }
    sys_icache_invalidate(GuestStubPage, GUEST_STUB_PAGE_SIZE);
    mprotect(GuestStubPage, GUEST_STUB_PAGE_SIZE, PROT_READ | PROT_EXEC);
    GuestStubSealed = YES;
}

static void GuestUnsealStubPage(void)
{
    if (GuestStubPage == NULL) {
        return;
    }
    if (mprotect(GuestStubPage,
                 GUEST_STUB_PAGE_SIZE,
                 PROT_READ | PROT_WRITE) != 0) {
        GuestLog("[guest] stub page unseal failed: %s\n", strerror(errno));
        return;
    }
    GuestStubSealed = NO;
}

#pragma mark - Fork via checkpoint and restore

static int GuestReadForkSnapshot(GuestForkSnapshot *header)
{
    if (GuestRestorePath == NULL) {
        return -1;
    }
    int descriptor = open(GuestRestorePath, O_RDONLY);
    if (descriptor < 0) {
        return -1;
    }
    ssize_t got = read(descriptor, header, sizeof(*header));
    close(descriptor);
    if (got != (ssize_t)sizeof(*header) ||
        header->magic != GUEST_FORK_MAGIC ||
        header->version != 1) {
        return -1;
    }
    return 0;
}

static ssize_t GuestPreadAll(int descriptor,
                             void *buffer,
                             size_t length,
                             off_t offset)
{
    uint8_t *bytes = (uint8_t *)buffer;
    size_t done = 0;
    while (done < length) {
        ssize_t got = pread(descriptor,
                            bytes + done,
                            length - done,
                            offset + (off_t)done);
        if (got <= 0) {
            return got < 0 ? got : (ssize_t)done;
        }
        done += (size_t)got;
    }
    return (ssize_t)done;
}

/* Restore the patched image while the mapping is still writable. */
static void GuestRestoreImage(void)
{
    GuestForkSnapshot header;
    if (GuestReadForkSnapshot(&header) != 0) {
        GuestLog("[guest] restore: bad snapshot header\n");
        _exit(72);
    }
    if (header.imageBase != (uint64_t)GuestImageBase ||
        header.imageSize != GuestImageSize) {
        GuestLog("[guest] restore: image mismatch 0x%llx/0x%llx vs 0x%llx/0x%llx\n",
                 (unsigned long long)header.imageBase,
                 (unsigned long long)header.imageSize,
                 (unsigned long long)GuestImageBase,
                 (unsigned long long)GuestImageSize);
        _exit(73);
    }

    int descriptor = open(GuestRestorePath, O_RDONLY);
    if (descriptor < 0) {
        GuestLog("[guest] restore: open failed: %s\n", strerror(errno));
        _exit(74);
    }
    ssize_t got = GuestPreadAll(descriptor,
                                (void *)GuestImageBase,
                                (size_t)header.imageSize,
                                (off_t)header.imageOffset);
    close(descriptor);
    if (got != (ssize_t)header.imageSize) {
        GuestLog("[guest] restore: short image %ld\n", (long)got);
        _exit(75);
    }
    GuestLog("[guest] restore image base=0x%llx size=0x%llx\n",
             (unsigned long long)GuestImageBase,
             (unsigned long long)GuestImageSize);
}

__attribute__((naked)) static void GuestRestoreJump(void)
{
    __asm__ volatile("mov sp, x0\n\tbr x1\n\t");
}

static void GuestRestoreStackAndJump(void)
{
    GuestForkSnapshot header;
    if (GuestReadForkSnapshot(&header) != 0) {
        GuestLog("[guest] restore: bad snapshot header\n");
        _exit(76);
    }
    if (header.heapBase != (uint64_t)GuestHeapBase ||
        header.stackBase != (uint64_t)GuestStackBase) {
        GuestLog("[guest] restore: heap/stack mismatch\n");
        _exit(77);
    }

    int descriptor = open(GuestRestorePath, O_RDONLY);
    if (descriptor < 0) {
        GuestLog("[guest] restore: open failed: %s\n", strerror(errno));
        _exit(78);
    }
    uint64_t heapBytes = header.brkCurrent - header.heapBase;
    if (heapBytes != 0 &&
        GuestPreadAll(descriptor,
                      (void *)GuestHeapBase,
                      (size_t)heapBytes,
                      (off_t)header.heapOffset) != (ssize_t)heapBytes) {
        GuestLog("[guest] restore: short heap\n");
        _exit(79);
    }
    uint64_t stackBytes = header.stackTop - header.stackPage;
    if (stackBytes != 0 &&
        GuestPreadAll(descriptor,
                      (void *)(uintptr_t)header.stackPage,
                      (size_t)stackBytes,
                      (off_t)header.stackOffset) != (ssize_t)stackBytes) {
        GuestLog("[guest] restore: short stack\n");
        _exit(80);
    }
    close(descriptor);
    unlink(GuestRestorePath);

    /*
     * The restore is done.  A later execve() in this process goes through the
     * normal loader and must not try to read the (already deleted) snapshot.
     */
    GuestRestorePath = NULL;
    GuestForcedBase = 0;
    GuestForcedHeap = 0;
    GuestForcedStack = 0;

    GuestBrkCurrent = (uintptr_t)header.brkCurrent;
    GuestTlsPointer = header.tlsPointer;
    strncpy(GuestCwd, header.cwd, sizeof(GuestCwd) - 1);
    GuestCwd[sizeof(GuestCwd) - 1] = '\0';
    GuestStackTop = header.stackTop;

    /* x0 is the clone() return value seen by the child. */
    *(uint64_t *)(uintptr_t)(header.frame + 0x10) = 0;

    GuestLog("[guest] restored pid=%d frame=0x%llx resume=0x%llx "
             "brk=0x%llx tls=0x%llx\n",
             getpid(),
             (unsigned long long)header.frame,
             (unsigned long long)header.resume,
             (unsigned long long)header.brkCurrent,
             (unsigned long long)header.tlsPointer);

    alarm(30);
    {
        /*
         * Resume exactly like the trampoline epilogue would: sp = the saved
         * register frame, entry = ldp x9,x10,[sp] (TPIDR/NZCV restore).
         * x0 already holds 0, which the epilogue leaves untouched.
         */
        uint64_t framePointer = header.frame;
        uint64_t resumeAddress =
            (uint64_t)(uintptr_t)&GuestSyscallTrampoline + 0x48;
        __asm__ volatile("mov sp, %0\n\tbr %1\n\t"
                         :: "r"(framePointer), "r"(resumeAddress)
                         : "memory");
    }
    _exit(81);
}

/*
 * Guest clone(): write the address space out, spawn a fresh runner and let it
 * restore at the same addresses with x0 = 0.  The child is traced by us (it
 * calls PT_TRACE_ME for CS_DEBUGGED), so wait for its stop and detach it.
 */
static uint64_t GuestForkWithSnapshot(uint64_t *args, uint64_t resume)
{
    if (GuestInterpBase != 0) {
        /*
         * A dynamic process also has ld.so and its libraries at runtime;
         * snapshotting them is the next step (apk install / shell pipelines).
         */
        GuestLog("[guest] fork: dynamic image snapshots not supported yet\n");
        return (uint64_t)(-ENOSYS);
    }
    if (GuestElfHostPath[0] == '\0') {
        GuestLog("[guest] fork: no ELF path\n");
        return (uint64_t)(-ENOSYS);
    }

    uint64_t frame = (uint64_t)(uintptr_t)(args - 2);
    uint64_t stackPage = frame & ~(uint64_t)0x3FFF;
    if (stackPage < GuestStackBase) {
        stackPage = GuestStackBase;
    }

    GuestForkSnapshot header;
    memset(&header, 0, sizeof(header));
    header.magic = GUEST_FORK_MAGIC;
    header.version = 1;
    header.imageBase = GuestImageBase;
    header.imageSize = GuestImageSize;
    header.heapBase = GuestHeapBase;
    header.heapSize = GuestHeapEnd - GuestHeapBase;
    header.brkCurrent = GuestBrkCurrent;
    header.stackBase = GuestStackBase;
    header.stackSize = GuestStackSize;
    header.stackTop = GuestStackTop;
    header.stackPage = stackPage;
    header.frame = frame;
    header.resume = resume;
    header.tlsPointer = GuestTlsPointer;
    strncpy(header.cwd, GuestCwd, sizeof(header.cwd) - 1);
    header.imageOffset = sizeof(header);
    header.heapOffset = header.imageOffset + header.imageSize;
    header.stackOffset = header.heapOffset + (header.brkCurrent - header.heapBase);

    const char *temporary = getenv("TMPDIR");
    if (temporary == NULL || temporary[0] == '\0') {
        temporary = "/tmp";
    }
    static unsigned int sequence = 0;
    char path[PATH_MAX];
    snprintf(path,
             sizeof(path),
             "%s/lkfork-%d-%u.snap",
             temporary,
             getpid(),
             ++sequence);

    int descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (descriptor < 0) {
        GuestLog("[guest] fork: snapshot open failed: %s\n", strerror(errno));
        return (uint64_t)(-errno);
    }
    GuestWriteAll(descriptor, (const char *)&header, sizeof(header));
    GuestWriteAll(descriptor,
                  (const char *)(uintptr_t)header.imageBase,
                  (size_t)header.imageSize);
    GuestWriteAll(descriptor,
                  (const char *)(uintptr_t)header.heapBase,
                  (size_t)(header.brkCurrent - header.heapBase));
    GuestWriteAll(descriptor,
                  (const char *)(uintptr_t)header.stackPage,
                  (size_t)(header.stackTop - header.stackPage));
    close(descriptor);

    char executable[PATH_MAX];
    uint32_t executableSize = sizeof(executable);
    if (_NSGetExecutablePath(executable, &executableSize) != 0) {
        unlink(path);
        GuestLog("[guest] fork: cannot resolve own path\n");
        return (uint64_t)(-ENOENT);
    }

    char *childArgv[] = {
        executable,
        (char *)"--restore",
        path,
        GuestElfHostPath,
        NULL,
    };
    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid,
                                  executable,
                                  NULL,
                                  NULL,
                                  childArgv,
                                  environ);
    if (spawnResult != 0) {
        unlink(path);
        GuestLog("[guest] fork: posix_spawn failed: %d\n", spawnResult);
        return (uint64_t)(-(int64_t)spawnResult);
    }

    int status = 0;
    pid_t waited = waitpid(pid, &status, WUNTRACED);
    if (waited == pid && WIFSTOPPED(status)) {
        errno = 0;
        int detachResult = ptrace(GUEST_PT_DETACH, pid, NULL, SIGCONT);
        int detachErrno = errno;
        /*
         * PT_DETACH with data=SIGCONT is not enough on its own: the child
         * stays stopped until a separate SIGCONT lands.  Without this it only
         * resumed when the watchdog fired 20s later.
         */
        for (int attempt = 0; attempt < 3; attempt++) {
            kill(pid, SIGCONT);
            usleep(10 * 1000);
        }
        GuestLog("[guest] fork child=%d detach rc=%d errno=%d\n",
                 pid,
                 detachResult,
                 detachErrno);
    } else if (waited == pid) {
        GuestLog("[guest] fork child=%d ended early status=0x%x\n", pid, status);
    } else {
        GuestLog("[guest] fork child=%d waitpid=%d errno=%d\n",
                 pid,
                 waited,
                 errno);
    }

    GuestLastForkChild = pid;
    GuestLog("[guest] fork spawn pid=%d snap=%s\n", pid, path);
    return (uint64_t)pid;
}

static uint8_t *GuestReadHostFile(const char *path, size_t *length)
{
    int descriptor = open(path, O_RDONLY);
    if (descriptor < 0) {
        return NULL;
    }
    struct stat status;
    if (fstat(descriptor, &status) != 0 || status.st_size <= 0 ||
        status.st_size > (off_t)(512 * 1024 * 1024)) {
        close(descriptor);
        return NULL;
    }
    size_t size = (size_t)status.st_size;
    uint8_t *buffer = (uint8_t *)malloc(size);
    if (buffer == NULL) {
        close(descriptor);
        return NULL;
    }
    size_t total = 0;
    while (total < size) {
        ssize_t count = read(descriptor, buffer + total, size - total);
        if (count <= 0) {
            break;
        }
        total += (size_t)count;
    }
    close(descriptor);
    if (total != size) {
        free(buffer);
        return NULL;
    }
    *length = size;
    return buffer;
}

static void GuestDropAllDirCaches(void)
{
    for (size_t index = 0; index < 8; index++) {
        if (!GuestDirCaches[index].valid) {
            continue;
        }
        closedir(GuestDirCaches[index].directory);
        memset(&GuestDirCaches[index], 0, sizeof(GuestDirCaches[index]));
    }
}

/*
 * execve maps a brand new image into the same process.  We cannot unmap the
 * generation we are currently running on (the C code handling the syscall
 * itself runs on the guest stack), so each generation is retired one exec
 * later: at most two generations are alive at any time.
 */
static uintptr_t GuestRetiredImageBase = 0;
static uint64_t GuestRetiredImageSize = 0;
static uintptr_t GuestRetiredInterpBase = 0;
static uint64_t GuestRetiredInterpSize = 0;
static uintptr_t GuestRetiredHeapBase = 0;
static uint64_t GuestRetiredHeapSize = 0;
static uint64_t GuestRetiredStackBase = 0;
static uint64_t GuestRetiredStackSize = 0;
static uint8_t *GuestRetiredStubPage = NULL;

static void GuestFreeRetired(void)
{
    if (GuestRetiredImageBase != 0) {
        munmap((void *)GuestRetiredImageBase, (size_t)GuestRetiredImageSize);
    }
    if (GuestRetiredInterpBase != 0) {
        munmap((void *)GuestRetiredInterpBase,
               (size_t)GuestRetiredInterpSize);
    }
    if (GuestRetiredHeapBase != 0) {
        munmap((void *)GuestRetiredHeapBase, (size_t)GuestRetiredHeapSize);
    }
    if (GuestRetiredStackBase != 0) {
        munmap((void *)(uintptr_t)GuestRetiredStackBase,
               (size_t)GuestRetiredStackSize);
    }
    if (GuestRetiredStubPage != NULL) {
        munmap(GuestRetiredStubPage, GUEST_STUB_PAGE_SIZE);
    }
    GuestRetiredImageBase = 0;
    GuestRetiredImageSize = 0;
    GuestRetiredInterpBase = 0;
    GuestRetiredInterpSize = 0;
    GuestRetiredHeapBase = 0;
    GuestRetiredHeapSize = 0;
    GuestRetiredStackBase = 0;
    GuestRetiredStackSize = 0;
    GuestRetiredStubPage = NULL;
}

static void GuestRetireCurrent(void)
{
    GuestRetiredImageBase = GuestImageBase;
    GuestRetiredImageSize = GuestImageSize;
    GuestRetiredInterpBase = GuestInterpBase;
    GuestRetiredInterpSize = GuestInterpSize;
    GuestRetiredHeapBase = GuestHeapBase;
    GuestRetiredHeapSize = GuestHeapEnd - GuestHeapBase;
    GuestRetiredStackBase = GuestStackBase;
    GuestRetiredStackSize = GuestStackSize;
    GuestRetiredStubPage = GuestStubPage;

    /* ld.so / malloc mappings from the old generation are dead after exec. */
    GuestReleaseMmaps();

    GuestImageBase = 0;
    GuestImageSize = 0;
    GuestInterpBase = 0;
    GuestInterpSize = 0;
    GuestInterpPath[0] = '\0';
    GuestMmapCursor = 0;
    GuestTlsPointer = 0;
    GuestTlsInitImage = 0;
    GuestTlsInitSize = 0;
    GuestIrelSlot = 0;
    GuestIrelAddend = 0;
    GuestHeapBase = 0;
    GuestHeapEnd = 0;
    GuestBrkCurrent = 0;
    GuestStackBase = 0;
    GuestStackSize = 0;
    GuestStackTop = 0;
    GuestStubPage = NULL;
    GuestStubSealed = NO;
    GuestForkStub = 0;
    GuestTlsIslandCursor = NULL;
    GuestTlsIslandEnd = NULL;
    GuestIslandSiteCount = 0;
    memset(GuestTlsReadStubs, 0, sizeof(GuestTlsReadStubs));
    memset(GuestTlsWriteStubs, 0, sizeof(GuestTlsWriteStubs));
}

static uint64_t GuestExecSyscall(uint64_t pathAddress,
                                 uint64_t argvAddress,
                                 uint64_t envpAddress)
{
    const char *guestPath = (const char *)pathAddress;
    if (guestPath == NULL) {
        return (uint64_t)(-EFAULT);
    }
    char hostPath[GUEST_ROOT_MAX];
    if (GuestTranslatePath(GUEST_AT_FDCWD,
                           guestPath,
                           hostPath,
                           sizeof(hostPath)) == NULL) {
        return (uint64_t)(-ENOENT);
    }

    char *guestArgv[49];
    int guestArgc = 0;
    if (argvAddress != 0) {
        char **source = (char **)argvAddress;
        while (guestArgc < 48 && source[guestArgc] != NULL) {
            guestArgv[guestArgc] = source[guestArgc];
            guestArgc++;
        }
    }
    guestArgv[guestArgc] = NULL;
    if (guestArgc == 0) {
        guestArgv[0] = (char *)guestPath;
        guestArgv[1] = NULL;
        guestArgc = 1;
    }

    char *guestEnvironment[49];
    int environmentCount = 0;
    if (envpAddress != 0) {
        char **source = (char **)envpAddress;
        while (environmentCount < 48 &&
               source[environmentCount] != NULL) {
            guestEnvironment[environmentCount] = source[environmentCount];
            environmentCount++;
        }
    }
    guestEnvironment[environmentCount] = NULL;

    GuestLog(
            "[guest] execve %s -> %s argc=%d env=%d\n",
            guestPath,
            hostPath,
            guestArgc,
            environmentCount);

    for (int descriptor = 3; descriptor < 1024; descriptor++) {
        int flags = fcntl(descriptor, F_GETFD);
        if (flags > 0 && (flags & FD_CLOEXEC)) {
            close(descriptor);
        }
    }
    GuestDropAllDirCaches();

    int result = GuestLoadAndRunInternal(guestPath,
                                         hostPath,
                                         guestArgc,
                                         guestArgv,
                                         environmentCount,
                                         guestEnvironment,
                                         NO);
    GuestLog( "[guest] execve failed rc=%d\n", result);
    return (uint64_t)(-ENOEXEC);
}

static int GuestLoadAndRunInternal(const char *guestPath,
                                   const char *hostPath,
                                   int guestArgc,
                                   char *guestArgv[],
                                   int environmentCount,
                                   char *environment[],
                                   BOOL initial)
{
    GuestFreeRetired();

    snprintf(GuestElfPath, sizeof(GuestElfPath), "%s", guestPath);
    snprintf(GuestElfHostPath, sizeof(GuestElfHostPath), "%s", hostPath);
    size_t fileLength = 0;
    uint8_t *file = GuestReadHostFile(hostPath, &fileLength);
    if (file == NULL || fileLength < sizeof(GuestElfHeader)) {
        GuestLog( "[guest] cannot read %s\n", hostPath);
        free(file);
        return -2;
    }
    const GuestElfHeader *header = (const GuestElfHeader *)file;
    if (memcmp(header->e_ident, "\x7f""ELF", 4) != 0 ||
        header->e_ident[4] != 2 ||
        header->e_machine != ELF_EM_AARCH64) {
        GuestLog( "[guest] not an aarch64 ELF64\n");
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
        GuestLog( "[guest] no loadable segments\n");
        return 1;
    }

    uint64_t imageSize = (maxAddress - minAddress + 0x3FFF) & ~0x3FFFULL;
    uintptr_t trampoline = (uintptr_t)&GuestSyscallTrampoline;

    if (!initial) {
        /* The new image is known to be valid; retire the old generation. */
        GuestRetireCurrent();
    }

    uintptr_t base = 0;
    if (header->e_type == ELF_ET_DYN) {
        base = GuestChooseBase(imageSize, trampoline);
        if (base == 0) {
            GuestLog( "[guest] no free address range near trampoline\n");
            return 1;
        }
    } else if (!GuestRangeFree((uintptr_t)minAddress, (size_t)imageSize)) {
        GuestLog( "[guest] fixed ELF range is occupied\n");
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
        GuestLog( "[guest] mmap image failed: %s\n", strerror(errno));
        return 1;
    }

    for (uint16_t index = 0; index < header->e_phnum; index++) {
        const GuestElfProgramHeader *program = &programs[index];
        if (program->p_type != ELF_PT_LOAD) {
            continue;
        }

        uint8_t *destination =
            (uint8_t *)image + (program->p_vaddr - minAddress);
        if (program->p_offset + program->p_filesz > fileLength) {
            GuestLog( "[guest] segment outside file\n");
            return 1;
        }
        memcpy(destination, file + program->p_offset, (size_t)program->p_filesz);
        if (program->p_memsz > program->p_filesz) {
            memset(destination + program->p_filesz,
                   0,
                   (size_t)(program->p_memsz - program->p_filesz));
        }
    }

    /*
     * Map the shared island page before the interpreter: its base search
     * must see the reserved range so the two images never overlap.
     */
    uintptr_t island = GuestMapStub(imageStart,
                                    imageSize,
                                    (uintptr_t)&GuestSyscallTrampoline);
    if (island == 0) {
        GuestLog( "[guest] no trampoline island near image\n");
        return 1;
    }
    GuestLog( "[guest] island=0x%lx\n", (unsigned long)island);

    /*
     * PT_INTERP: dynamically linked main executable.  Load the interpreter
     * (musl/glibc ld.so) at its own base and jump to it; AT_BASE points at
     * the interpreter, AT_ENTRY at the main image.
     */
    uint8_t *interpFile = NULL;
    size_t interpFileLength = 0;
    GuestElfHeader *interpHeader = NULL;
    const GuestElfProgramHeader *interpPrograms = NULL;
    uint64_t interpMinAddress = 0;
    uint64_t interpImageSize = 0;
    char interpGuestPath[GUEST_ROOT_MAX];
    char interpHostPath[GUEST_ROOT_MAX];
    interpGuestPath[0] = '\0';
    interpHostPath[0] = '\0';

    if (header->e_type == ELF_ET_DYN) {
        for (uint16_t index = 0; index < header->e_phnum; index++) {
            const GuestElfProgramHeader *program = &programs[index];
            if (program->p_type != ELF_PT_INTERP ||
                program->p_filesz == 0 ||
                program->p_filesz >= sizeof(interpGuestPath) ||
                program->p_offset + program->p_filesz > fileLength) {
                continue;
            }
            memcpy(interpGuestPath,
                   file + program->p_offset,
                   (size_t)program->p_filesz);
            interpGuestPath[program->p_filesz] = '\0';
            break;
        }
    }

    if (interpGuestPath[0] != '\0') {
        if (GuestTranslatePath(GUEST_AT_FDCWD,
                               interpGuestPath,
                               interpHostPath,
                               sizeof(interpHostPath)) == NULL) {
            GuestLog( "[guest] interp path too long: %s\n", interpGuestPath);
            return 1;
        }
        interpFile = GuestReadHostFile(interpHostPath, &interpFileLength);
        if (interpFile == NULL ||
            interpFileLength < sizeof(GuestElfHeader)) {
            GuestLog( "[guest] cannot read interp %s (%s)\n",
                    interpGuestPath,
                    interpHostPath);
            free(interpFile);
            return 1;
        }
        interpHeader = (GuestElfHeader *)interpFile;
        if (memcmp(interpHeader->e_ident, "\x7f""ELF", 4) != 0 ||
            interpHeader->e_ident[4] != 2 ||
            interpHeader->e_machine != ELF_EM_AARCH64 ||
            interpHeader->e_type != ELF_ET_DYN) {
            GuestLog( "[guest] interp is not aarch64 ET_DYN: %s\n",
                    interpGuestPath);
            free(interpFile);
            return 1;
        }
        interpPrograms = (const GuestElfProgramHeader *)(interpFile +
                                                        interpHeader->e_phoff);

        uint64_t interpMin = UINT64_MAX;
        uint64_t interpMax = 0;
        for (uint16_t index = 0; index < interpHeader->e_phnum; index++) {
            if (interpPrograms[index].p_type != ELF_PT_LOAD) {
                continue;
            }
            interpMin = MIN(interpMin, interpPrograms[index].p_vaddr);
            interpMax = MAX(interpMax,
                            interpPrograms[index].p_vaddr +
                            interpPrograms[index].p_memsz);
        }
        if (interpMax <= interpMin) {
            GuestLog( "[guest] interp has no loadable segments\n");
            free(interpFile);
            return 1;
        }
        interpMinAddress = interpMin;
        interpImageSize = (interpMax - interpMin + 0x3FFF) & ~0x3FFFULL;

        uintptr_t interpBase = GuestChooseInterpBase(imageStart,
                                                     imageSize,
                                                     interpImageSize,
                                                     trampoline);
        if (interpBase == 0) {
            GuestLog( "[guest] no free address for interpreter\n");
            free(interpFile);
            return 1;
        }
        uintptr_t interpStart = interpBase + (uintptr_t)interpMinAddress;
        void *interpImage = mmap((void *)interpStart,
                                 (size_t)interpImageSize,
                                 PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANON | MAP_FIXED,
                                 -1,
                                 0);
        if (interpImage == MAP_FAILED) {
            GuestLog( "[guest] interp mmap failed: %s\n", strerror(errno));
            free(interpFile);
            return 1;
        }
        for (uint16_t index = 0; index < interpHeader->e_phnum; index++) {
            const GuestElfProgramHeader *program = &interpPrograms[index];
            if (program->p_type != ELF_PT_LOAD) {
                continue;
            }
            uint8_t *destination =
                (uint8_t *)interpImage +
                (program->p_vaddr - interpMinAddress);
            if (program->p_offset + program->p_filesz > interpFileLength) {
                GuestLog( "[guest] interp segment outside file\n");
                free(interpFile);
                return 1;
            }
            memcpy(destination,
                   interpFile + program->p_offset,
                   (size_t)program->p_filesz);
            if (program->p_memsz > program->p_filesz) {
                memset(destination + program->p_filesz,
                       0,
                       (size_t)(program->p_memsz - program->p_filesz));
            }
        }

        GuestInterpBase = interpStart;
        GuestInterpSize = interpImageSize;
        snprintf(GuestInterpPath,
                 sizeof(GuestInterpPath),
                 "%s",
                 interpGuestPath);
        GuestLog( "[guest] interp %s host=%s base=0x%lx size=0x%llx\n",
                interpGuestPath,
                interpHostPath,
                (unsigned long)GuestInterpBase,
                (unsigned long long)GuestInterpSize);
    }

    uint32_t patched = 0;
    uint32_t tlsReads = 0;
    uint32_t tlsWrites = 0;

    /* Locate PT_TLS and the first IRELATIVE (IFUNC) GOT slot. */
    for (uint16_t index = 0; index < header->e_phnum; index++) {
        const GuestElfProgramHeader *program = &programs[index];
        uint8_t *segment = (uint8_t *)image + (program->p_vaddr - minAddress);

        if (program->p_type == 7) { /* PT_TLS */
            GuestTlsInitImage = (uintptr_t)segment;
            GuestTlsInitSize = program->p_filesz;
        } else if (program->p_type == 2 && program->p_filesz >= 16) {
            const uint64_t *entries = (const uint64_t *)segment;
            uint64_t rela = 0;
            uint64_t relasz = 0;
            uint64_t relaent = 24;
            uint64_t jmprel = 0;
            uint64_t pltrelsz = 0;
            for (uint64_t cursor = 0;
                 cursor + 16 <= program->p_filesz;
                 cursor += 16) {
                uint64_t tag = entries[cursor / 8];
                uint64_t value = entries[cursor / 8 + 1];
                if (tag == 0) {
                    break;
                }
                if (tag == 7) {
                    rela = value;
                } else if (tag == 8) {
                    relasz = value;
                } else if (tag == 9) {
                    relaent = value;
                } else if (tag == 23) {
                    jmprel = value;
                } else if (tag == 2) {
                    pltrelsz = value;
                }
            }

            uint64_t tables[2][2] = { { rela, relasz }, { jmprel, pltrelsz } };
            for (int table = 0; table < 2 && GuestIrelSlot == 0; table++) {
                uint64_t address = tables[table][0];
                uint64_t size = tables[table][1];
                if (address == 0 || size < 24 || relaent < 24) {
                    continue;
                }
                if (address < minAddress ||
                    address - minAddress + size > imageSize) {
                    continue;
                }
                const uint64_t *relocs =
                    (const uint64_t *)(imageStart + (uintptr_t)(address - minAddress));
                uint64_t count = size / relaent;
                for (uint64_t entry = 0; entry < count; entry++) {
                    uint64_t offset = relocs[entry * 3];
                    uint64_t info = relocs[entry * 3 + 1];
                    uint64_t addend = relocs[entry * 3 + 2];
                    if ((info & 0xFFFFFFFFULL) != 1032) {
                        continue;
                    }
                    if (offset < minAddress ||
                        offset - minAddress + 8 > imageSize) {
                        continue;
                    }
                    GuestIrelSlot =
                        imageStart + (uintptr_t)(offset - minAddress);
                    GuestIrelAddend = addend;
                    break;
                }
            }
        }
    }
    GuestLog(
            "[guest] tls image=0x%lx size=0x%llx irel_slot=0x%lx "
            "irel_addend=0x%llx\n",
            (unsigned long)GuestTlsInitImage,
            (unsigned long long)GuestTlsInitSize,
            (unsigned long)GuestIrelSlot,
            (unsigned long long)GuestIrelAddend);

    for (uint16_t index = 0; index < header->e_phnum; index++) {
        const GuestElfProgramHeader *program = &programs[index];
        if (program->p_type != ELF_PT_LOAD ||
            !(program->p_flags & ELF_PF_X)) {
            continue;
        }
        uint8_t *start = (uint8_t *)image + (program->p_vaddr - minAddress);
        if (GuestPatchCodeRange((uintptr_t)start,
                                program->p_filesz,
                                &patched,
                                &tlsReads,
                                &tlsWrites) != 0) {
            free(interpFile);
            return 1;
        }
    }
    if (GuestInterpBase != 0 && interpHeader != NULL) {
        for (uint16_t index = 0; index < interpHeader->e_phnum; index++) {
            const GuestElfProgramHeader *program = &interpPrograms[index];
            if (program->p_type != ELF_PT_LOAD ||
                !(program->p_flags & ELF_PF_X)) {
                continue;
            }
            uint8_t *start = (uint8_t *)GuestInterpBase +
                             (program->p_vaddr - interpMinAddress);
            if (GuestPatchCodeRange((uintptr_t)start,
                                    program->p_filesz,
                                    &patched,
                                    &tlsReads,
                                    &tlsWrites) != 0) {
                free(interpFile);
                return 1;
            }
        }
    }
    GuestSealStubPage();
    sys_icache_invalidate((void *)imageStart, (size_t)imageSize);
    if (GuestInterpBase != 0) {
        sys_icache_invalidate((void *)GuestInterpBase,
                              (size_t)GuestInterpSize);
    }
    GuestLog(
            "[guest] loaded %s base=0x%lx size=0x%llx patched=%u "
            "tls_mrs=%u tls_msr=%u sites=%lu interp=0x%lx\n",
            hostPath,
            (unsigned long)base,
            (unsigned long long)imageSize,
            patched,
            tlsReads,
            tlsWrites,
            (unsigned long)GuestIslandSiteCount,
            (unsigned long)GuestInterpBase);

    if (GuestRestorePath != NULL) {
        if (GuestInterpBase != 0) {
            GuestLog("[guest] restore of a dynamic image is not supported\n");
            _exit(83);
        }
        /* Still writable here, before the per-segment protections go on. */
        GuestRestoreImage();
    }

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
            GuestLog( "[guest] mprotect failed: %s\n", strerror(errno));
            return 1;
        }
    }
    sys_icache_invalidate((void *)imageStart, (size_t)imageSize);

    if (GuestInterpBase != 0 && interpHeader != NULL) {
        for (uint16_t index = 0; index < interpHeader->e_phnum; index++) {
            const GuestElfProgramHeader *program = &interpPrograms[index];
            if (program->p_type != ELF_PT_LOAD || program->p_memsz == 0) {
                continue;
            }

            uintptr_t segmentBase = GuestInterpBase +
                                    (program->p_vaddr - interpMinAddress);
            uintptr_t segmentStart = segmentBase & ~0x3FFFULL;
            uintptr_t segmentEnd =
                (segmentBase + program->p_memsz + 0x3FFF) & ~0x3FFFULL;
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
                GuestLog( "[guest] interp mprotect failed: %s\n",
                        strerror(errno));
                return 1;
            }
        }
        sys_icache_invalidate((void *)GuestInterpBase,
                              (size_t)GuestInterpSize);
    }

    size_t heapSize = 64 * 1024 * 1024;
    int heapFlags = MAP_PRIVATE | MAP_ANON;
    void *heapAddress = NULL;
    if (GuestForcedHeap != 0) {
        heapAddress = (void *)GuestForcedHeap;
        heapFlags |= MAP_FIXED;
    }
    GuestHeapBase = (uintptr_t)mmap(heapAddress,
                                    heapSize,
                                    PROT_READ | PROT_WRITE,
                                    heapFlags,
                                    -1,
                                    0);
    if (GuestHeapBase == (uintptr_t)MAP_FAILED) {
        GuestLog( "[guest] heap mmap failed\n");
        return 1;
    }
    GuestHeapEnd = GuestHeapBase + heapSize;
    GuestBrkCurrent = GuestHeapBase;
    GuestLog(
            "[guest] heap=0x%lx..0x%lx pagesz=0x%llx\n",
            (unsigned long)GuestHeapBase,
            (unsigned long)GuestHeapEnd,
            (unsigned long long)GUEST_TARGET_PAGE_SIZE);

    size_t stackSize = 8 * 1024 * 1024;
    /*
     * Keep the guest stack right above the heap.  An mmap(NULL) stack is
     * ASLR-placed and can overlap the main executable in the process that
     * restores a snapshot, where MAP_FIXED then fails.
     */
    uintptr_t stackBase = GuestForcedStack != 0
        ? GuestForcedStack
        : (GuestHeapEnd + 0x3FFF) & ~(uintptr_t)0x3FFF;
    void *stack = mmap((void *)stackBase,
                       stackSize,
                       PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON | MAP_FIXED,
                       -1,
                       0);
    if (stack == MAP_FAILED) {
        GuestLog( "[guest] stack mmap failed\n");
        return -2;
    }
    GuestStackBase = (uint64_t)(uintptr_t)stack;
    GuestStackSize = stackSize;
    GuestStackTop = GuestStackBase + stackSize;

    if (GuestRestorePath != NULL) {
        /*
         * We are traced by the runner that spawned us (PT_TRACE_ME above),
         * and XNU only lets a tracer detach a stopped tracee.  Stop here, let
         * it detach us, then finish restoring and resume the guest.
         */
        GuestLog("[guest] restore ready for detach\n");
        raise(SIGSTOP);
        GuestRestoreStackAndJump(); /* never returns */
    }

    uint64_t mainEntry = base + header->e_entry;
    uint64_t entry = GuestInterpBase != 0 && interpHeader != NULL
        ? GuestInterpBase + interpHeader->e_entry
        : mainEntry;
    uint64_t stackPointer = GuestBuildStack(GuestStackTop,
                                            guestArgc,
                                            guestArgv,
                                            environmentCount,
                                            environment,
                                            imageStart,
                                            header,
                                            entry,
                                            GuestInterpBase,
                                            mainEntry,
                                            guestArgv[0]);

    const uint32_t *entryWords = GuestInterpBase != 0 && interpHeader != NULL
        ? (const uint32_t *)(GuestInterpBase +
                             (interpHeader->e_entry - interpMinAddress))
        : (const uint32_t *)(imageStart + (header->e_entry - minAddress));
    GuestLog(
            "[guest] entry=0x%llx at_base=0x%llx at_entry=0x%llx "
            "stack=0x%llx aligned=%d argc=%d argv0=%s "
            "env=%d words=%08x %08x %08x %08x %08x\n",
            (unsigned long long)entry,
            (unsigned long long)GuestInterpBase,
            (unsigned long long)mainEntry,
            (unsigned long long)stackPointer,
            (stackPointer & 0xF) == 0 ? 1 : 0,
            guestArgc,
            guestArgv[0],
            environmentCount,
            entryWords[0],
            entryWords[1],
            entryWords[2],
            entryWords[3],
            entryWords[4]);

    if (initial) {
        /* Single-threaded watchdog: see GuestAlarmHandler. */
        alarm(30);

#if !TARGET_OS_OSX && !TARGET_OS_SIMULATOR
        /*
         * All code patching is finished, so CS_DEBUGGED is no longer needed.
         * iOS does not let a process detach itself (PT_DETACH returns EPERM),
         * and the tracer may only detach a *stopped* tracee (otherwise EBUSY).
         * So stop ourselves and let the App, which is the tracer because of
         * PT_TRACE_ME, detach us from its waitpid loop and send SIGCONT.
         * Once detached, a guest fault runs our own sigaction handler instead
         * of freezing the whole task in P_LTRACED.
         */
        GuestLog( "[guest] ready for detach\n");
        raise(SIGSTOP);
#endif
    }

    GuestLog( "[guest] jump\n");

    free(interpFile);
    free(file);
    GuestJump(entry, stackPointer);
    GuestLog( "[guest] jump returned\n");
    return 0;
}

static char *GuestDefaultEnvironment[] = {
    "PATH=/bin:/sbin:/usr/bin:/usr/sbin",
    "HOME=/root",
    "SHELL=/bin/sh",
    "TERM=dumb",
    "LANG=C",
    "USER=root",
    "LOGNAME=root",
    NULL,
};

static int GuestLoadAndRun(int argc, char *argv[])
{
    int guestArgc = argc > 2 ? argc - 2 : 1;
    char *fallbackArgv[] = { (char *)"guest" };
    char **guestArgv = argc > 2 ? argv + 2 : fallbackArgv;
    int environmentCount = 0;
    while (GuestDefaultEnvironment[environmentCount] != NULL) {
        environmentCount++;
    }
    return GuestLoadAndRunInternal(argv[1],
                                   argv[1],
                                   guestArgc,
                                   guestArgv,
                                   environmentCount,
                                   GuestDefaultEnvironment,
                                   YES);
}

static void GuestHostExit(void)
{
    GuestLog( "[guest] host exit handler\n");
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
        atexit(GuestHostExit);

        GuestLog( "[guest] runner pid=%d\n", getpid());
        if (argc < 2) {
            GuestLog( "[guest] usage: guest-runner <elf>\n");
            return 2;
        }
        GuestLogCodeSignState("before");
        if (!GuestEnableJIT()) {
            GuestLog( "[guest] JIT unavailable\n");
            return 3;
        }
        GuestLogCodeSignState("after");
        GuestLog( "[guest] jit enabled\n");
        GuestLog( "[guest] code dispatch=0x%llx handler=0x%llx alarm=0x%llx\n",
                 (unsigned long long)(uintptr_t)&GuestSyscallDispatch,
                 (unsigned long long)(uintptr_t)&GuestSignalHandler,
                 (unsigned long long)(uintptr_t)&GuestAlarmHandler);

        /*
         * Restore mode: guest-runner --restore <snapshot> <elf>
         * The runner that forked us wrote the guest address space out; read
         * the header now so the loader reproduces the exact same addresses.
         */
        if (argc >= 4 && strcmp(argv[1], "--restore") == 0) {
            GuestRestorePath = argv[2];
            GuestForkSnapshot snapshot;
            if (GuestReadForkSnapshot(&snapshot) != 0) {
                GuestLog("[guest] restore: cannot read snapshot %s\n", argv[2]);
                return 6;
            }
            GuestForcedBase = (uintptr_t)snapshot.imageBase;
            GuestForcedHeap = (uintptr_t)snapshot.heapBase;
            GuestForcedStack = (uintptr_t)snapshot.stackBase;
            GuestLog("[guest] restore mode base=0x%lx heap=0x%lx "
                     "stack=0x%lx brk=0x%llx\n",
                     (unsigned long)GuestForcedBase,
                     (unsigned long)GuestForcedHeap,
                     (unsigned long)GuestForcedStack,
                     (unsigned long long)snapshot.brkCurrent);
        }

        uint32_t selfTest = GuestJITSelfTest();
        GuestLog( "[guest] selftest=%u\n", selfTest);
        if (selfTest != 42) {
            GuestLog( "[guest] self-test failed, aborting\n");
            return 5;
        }

        GuestProbeTpidr();

        GuestBootstrapRootfs();

        int result;
        if (GuestRestorePath != NULL) {
            char *restoreArgv[] = { argv[3], NULL };
            result = GuestLoadAndRunInternal(argv[3],
                                            argv[3],
                                            1,
                                            restoreArgv,
                                            0,
                                            NULL,
                                            NO);
        } else {
            result = GuestLoadAndRun(argc, argv);
        }
        GuestLog( "[guest] host main rc=%d\n", result);
        return result;
    }
}
