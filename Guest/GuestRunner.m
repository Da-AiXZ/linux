#import <Foundation/Foundation.h>

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach/vm_region.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
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
extern boolean_t exc_server(mach_msg_header_t *request,
                            mach_msg_header_t *reply);

#define GUEST_PT_TRACE_ME 0
#define GUEST_PT_SIGEXC 12

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
static uint64_t GuestStackTop = 0;

#pragma mark - JIT

kern_return_t catch_exception_raise(mach_port_t exception_port,
                                    mach_port_t thread,
                                    mach_port_t task,
                                    exception_type_t exception,
                                    exception_data_t code,
                                    mach_msg_type_number_t code_count)
{
    return KERN_FAILURE;
}

static void *GuestExceptionThread(void *argument)
{
    mach_port_t port = *(mach_port_t *)argument;
    mach_msg_server(exc_server, 2048, port, 0);
    return NULL;
}

static BOOL GuestEnableJIT(void)
{
    if (ptrace(GUEST_PT_TRACE_ME, 0, NULL, 0) < 0) {
        fprintf(stderr, "[guest] ptrace(PT_TRACE_ME) failed: %s\n",
                strerror(errno));
        return NO;
    }

    ptrace(GUEST_PT_SIGEXC, 0, NULL, 0);

    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(),
                           MACH_PORT_RIGHT_RECEIVE,
                           &port) != KERN_SUCCESS) {
        return NO;
    }

    mach_port_insert_right(mach_task_self(),
                           port,
                           port,
                           MACH_MSG_TYPE_MAKE_SEND);
    task_set_exception_ports(mach_task_self(),
                             EXC_MASK_SOFTWARE,
                             port,
                             EXCEPTION_DEFAULT,
                             THREAD_STATE_NONE);

    pthread_t thread;
    if (pthread_create(&thread, NULL, GuestExceptionThread, &port) != 0) {
        return NO;
    }

    return YES;
}

#pragma mark - Syscall trampoline

uint64_t GuestSyscallDispatch(uint64_t *args, uint64_t number)
    __attribute__((used));

__attribute__((naked, noinline, used))
static void GuestSyscallTrampoline(void)
{
    __asm__ volatile(
        "stp x4, x5, [sp, #-16]!\n"
        "stp x2, x3, [sp, #-16]!\n"
        "stp x0, x1, [sp, #-16]!\n"
        "mov x0, sp\n"
        "mov x1, x8\n"
        "bl _GuestSyscallDispatch\n"
        "ldp x9, x1, [sp], #16\n"
        "ldp x2, x3, [sp], #16\n"
        "ldp x4, x5, [sp], #16\n"
        "ldp x29, x30, [sp], #16\n"
        "ret\n");
}

static uint64_t GuestErrno(void)
{
    return (uint64_t)(-(int64_t)errno);
}

#pragma mark - Syscalls

uint64_t GuestSyscallDispatch(uint64_t *args, uint64_t number)
{
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
    case 233: /* madvise */
        return 0;
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
    case 214: { /* brk */
        if (args[0] == 0) {
            return GuestHeapEnd;
        }
        if (args[0] >= GuestHeapBase && args[0] <= GuestHeapEnd) {
            return args[0];
        }
        return GuestHeapEnd;
    }
    case 222: { /* mmap */
        void *result = mmap((void *)args[0],
                            (size_t)args[1],
                            (int)args[2],
                            (int)args[3],
                            (int)args[4],
                            (off_t)args[5]);
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
    default:
        fprintf(stderr, "[guest] unsupported syscall %llu\n",
                (unsigned long long)number);
        return (uint64_t)(-ENOSYS);
    }
}

#pragma mark - Loader

static BOOL GuestRangeFree(uintptr_t address, size_t size)
{
    mach_vm_address_t region = (mach_vm_address_t)address;
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;

    kern_return_t result = mach_vm_region(mach_task_self(),
                                          &region,
                                          &regionSize,
                                          VM_REGION_BASIC_INFO_64,
                                          (vm_region_info_t)&info,
                                          &count,
                                          &object);
    if (object != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), object);
    }
    if (result != KERN_SUCCESS) {
        return YES;
    }

    return !(address >= region && address < region + regionSize);
}

static uintptr_t GuestChooseBase(uint64_t imageSize, uintptr_t trampoline)
{
    const uintptr_t offsets[] = {
        0x04000000, 0x06000000, 0x02000000, 0x07000000,
    };

    for (size_t index = 0; index < sizeof(offsets) / sizeof(offsets[0]);
         index++) {
        uintptr_t candidate = (trampoline + offsets[index]) & ~0xFFFULL;
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

static int GuestLoadAndRun(const char *path)
{
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

    uint64_t imageSize = (maxAddress - minAddress + 0xFFF) & ~0xFFFULL;
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
    for (uint16_t index = 0; index < header->e_phnum; index++) {
        const GuestElfProgramHeader *program = &programs[index];
        if (program->p_type != ELF_PT_LOAD ||
            !(program->p_flags & ELF_PF_X)) {
            continue;
        }

        uint8_t *start = (uint8_t *)image + (program->p_vaddr - minAddress);
        for (uint64_t offset = 0; offset + 4 <= program->p_filesz; offset += 4) {
            uint32_t instruction = *(uint32_t *)(start + offset);
            if (instruction != 0xD4000001) {
                continue;
            }

            int64_t delta = (int64_t)((uintptr_t)&GuestSyscallTrampoline -
                                      (uintptr_t)(start + offset));
            if (delta < -(1LL << 27) || delta >= (1LL << 27)) {
                fprintf(stderr, "[guest] svc site out of bl range\n");
                return 1;
            }
            uint32_t immediate = ((uint32_t)(delta >> 2)) & 0x03FFFFFF;
            *(uint32_t *)(start + offset) = 0x94000000 | immediate;
            patched++;
        }
    }
    fprintf(stdout, "[guest] loaded %s base=0x%lx size=0x%llx patched=%u\n",
            path,
            (unsigned long)base,
            (unsigned long long)imageSize,
            patched);

    for (uint16_t index = 0; index < header->e_phnum; index++) {
        const GuestElfProgramHeader *program = &programs[index];
        if (program->p_type != ELF_PT_LOAD || program->p_memsz == 0) {
            continue;
        }

        uintptr_t segmentStart =
            (imageStart + program->p_vaddr) & ~0xFFFULL;
        uintptr_t segmentEnd =
            (imageStart + program->p_vaddr + program->p_memsz + 0xFFF) & ~0xFFFULL;
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

    uint64_t stackPointer = (GuestStackTop - 16) & ~0xFULL;
    uint64_t *cursor = (uint64_t *)stackPointer;
    *--cursor = 0;  /* auxv AT_NULL value */
    *--cursor = 0;  /* auxv AT_NULL type */
    *--cursor = 0;  /* envp NULL */
    *--cursor = 0;  /* argv[0] */
    *--cursor = 1;  /* argc */
    stackPointer = (uint64_t)cursor;

    uint64_t entry = base + header->e_entry;
    fprintf(stdout, "[guest] entry=0x%llx stack=0x%llx\n",
            (unsigned long long)entry,
            (unsigned long long)stackPointer);
    fflush(stdout);

    GuestJump(entry, stackPointer);
    return 0;
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);

        fprintf(stdout, "[guest] runner pid=%d\n", getpid());
        if (argc < 2) {
            fprintf(stderr, "[guest] usage: guest-runner <elf>\n");
            return 2;
        }
        if (!GuestEnableJIT()) {
            fprintf(stderr, "[guest] JIT unavailable\n");
            return 3;
        }
        fprintf(stdout, "[guest] jit enabled\n");

        return GuestLoadAndRun(argv[1]);
    }
}
