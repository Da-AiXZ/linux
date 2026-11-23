/*
 * v2/runner.c -- the host process that becomes the guest.
 *
 * Order matters and is asserted at every step:
 *
 *   reserve -> load RW -> patch -> per-page protect -> seal islands -> run
 *
 * Nothing is ever both writable and executable, so the runner does not need
 * RWX pages.  On iOS it still needs CS_DEBUGGED for anonymous PROT_EXEC; that
 * is the only reason ptrace(PT_TRACE_ME) stays in the picture.
 */
#if defined(__APPLE__) && defined(__aarch64__)

#include <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <unistd.h>

#include "v2/cpu.h"
#include "v2/elf.h"
#include "v2/host_darwin.h"
#include "v2/patch.h"
#include "v2/proc.h"
#include "v2/stack.h"
#include "v2/vspace.h"

/*
 * The iOS SDK does not ship <sys/ptrace.h>; the declaration below is the one
 * v1 used and the one every jailbreak tool uses.  Request 0 is PT_TRACE_ME.
 */
#if TARGET_OS_IPHONE
extern int ptrace(int request, int pid, void *address, int data);
#define V2_PT_TRACE_ME 0
#endif

#define V2_SPACE_SIZE  (1024u * 1024u * 1024u)
/*
 * One trampoline island per 128 MiB zone.  `b` reaches +/-128 MiB, so a site
 * is never more than 64 MiB from an island, and a single mapping can be up to
 * ~128 MiB -- enough for the heap and for apk's index buffers.  A 16 MiB
 * stride (the first attempt) fragmented the space so badly that a 64 MiB heap
 * could not be placed at all.
 */
#define V2_ISLAND_STRIDE (128u * 1024u * 1024u)
#define V2_ISLAND_SIZE (64u * 1024u)
#define V2_HEAP_SIZE (64u * 1024u * 1024u)
#define V2_STACK_SIZE (8u * 1024u * 1024u)

static void die(const char *what, const char *detail)
{
    fprintf(stderr, "guest-runner: %s%s%s\n", what,
            detail != NULL ? ": " : "", detail != NULL ? detail : "");
    exit(1);
}

/* ------------------------------------------------------------- faults */

static uint64_t image_base;
static uint64_t image_end;
static uint64_t space_base;
static uint64_t space_end;

/*
 * The guest runs inside this process, so a guest fault *is* a host fault.
 * Without a handler, a SIGSEGV in a megabyte of third-party code says
 * "somewhere"; with one, the report names the guest pc, the address it
 * touched and the syscalls it made just before.
 */
static void v2_fault(int number, siginfo_t *info, void *context)
{
    ucontext_t *state = (ucontext_t *)context;
    uint64_t pc = 0;
    uint64_t address = (uint64_t)(uintptr_t)info->si_addr;

#if defined(__APPLE__)
    pc = (uint64_t)state->uc_mcontext->__ss.__pc;
#endif
    fprintf(stderr, "\n[v2] FAULT signal=%d addr=0x%llx pc=0x%llx\n", number,
            (unsigned long long)address, (unsigned long long)pc);
    if (image_base != 0 && pc >= image_base && pc < image_end) {
        fprintf(stderr, "[v2] pc = image + 0x%llx\n",
                (unsigned long long)(pc - image_base));
    } else if (space_base != 0 && pc >= space_base && pc < space_end) {
        fprintf(stderr, "[v2] pc = space + 0x%llx (heap or stack)\n",
                (unsigned long long)(pc - space_base));
    } else {
        fprintf(stderr, "[v2] pc is outside the guest\n");
    }
    if (space_base != 0 && address >= space_base && address < space_end) {
        fprintf(stderr, "[v2] addr = space + 0x%llx\n",
                (unsigned long long)(address - space_base));
    }
    /* The instructions around pc, when they are inside the guest. */
    if (space_base != 0 && pc >= space_base + 16 && pc < space_end) {
        const uint32_t *words = (const uint32_t *)(uintptr_t)(pc - 16);

        fprintf(stderr, "[v2] code: %08x %08x  [%08x] %08x %08x\n",
                words[0], words[1], words[2], words[3], words[4]);
    }
    v2_syscall_dump_trace();
    _exit(128 + number);
}

static void install_fault_handlers(void)
{
    struct sigaction action;

    memset(&action, 0, sizeof(action));
    action.sa_sigaction = v2_fault;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);
    sigaction(SIGILL, &action, NULL);
    sigaction(SIGFPE, &action, NULL);
}

static uint8_t *read_file(const char *path, size_t *length)
{
    struct stat info;
    uint8_t *buffer;
    int fd;
    size_t done = 0;

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return NULL;
    }
    if (fstat(fd, &info) != 0 || info.st_size <= 0) {
        close(fd);
        return NULL;
    }
    buffer = (uint8_t *)malloc((size_t)info.st_size);
    if (buffer == NULL) {
        close(fd);
        return NULL;
    }
    while (done < (size_t)info.st_size) {
        ssize_t got = pread(fd, buffer + done, (size_t)info.st_size - done,
                            (off_t)done);
        if (got <= 0) {
            free(buffer);
            close(fd);
            return NULL;
        }
        done += (size_t)got;
    }
    close(fd);
    *length = done;
    return buffer;
}

int main(int argc, char **argv)
{
#if TARGET_OS_IPHONE
    /*
     * Anonymous PROT_EXEC needs CS_DEBUGGED on iOS.  PT_TRACE_ME is the only
     * way to get it without a jailbreak entitlement; the app, not this
     * process, is the tracer, and it detaches after the handshake.
     * On macOS this call would stop the process instead, hence the guard.
     */
    ptrace(V2_PT_TRACE_ME, 0, NULL, 0);
#endif
    install_fault_handlers();
    const char *root = ".";
    const char *elf_path = NULL;
    int guest_argc = 0;
    char *guest_argv[V2_STACK_MAX_ARGS];
    char *guest_envp[3];
    struct v2_host host;
    struct v2_space *space = NULL;
    struct v2_patcher patcher;
    struct v2_elf_image image;
    struct v2_elf_load load;
    struct v2_proc proc;
    struct v2_auxv aux;
    struct v2_cpu cpu;
    char error[192] = "";
    uint8_t *file;
    size_t file_length = 0;
    uint64_t heap;
    uint64_t stack;
    uint64_t sp;
    size_t page_size;
    int fd;
    int status;

    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--root") == 0 && index + 1 < argc) {
            root = argv[++index];
            continue;
        }
        if (strcmp(argv[index], "--") == 0) {
            index++;
        }
        if (index < argc) {
            elf_path = argv[index];
            for (int rest = index + 1;
                 rest < argc && guest_argc < V2_STACK_MAX_ARGS - 1; rest++) {
                guest_argv[guest_argc++] = argv[rest];
            }
        }
        break;
    }
    if (elf_path == NULL) {
        fprintf(stderr,
                "usage: guest-runner [--root DIR] ELF [args...]\n");
        return 2;
    }
    {
        /* argv[0] is the program's own name, as the guest sees it. */
        for (int index = guest_argc; index > 0; index--) {
            guest_argv[index] = guest_argv[index - 1];
        }
        guest_argv[0] = (char *)elf_path;
        guest_argc++;
    }

    page_size = (size_t)sysconf(_SC_PAGESIZE);
    if (page_size < 4096) {
        die("page size", "unexpected");
    }

    host = v2_host_darwin();
    status = v2_space_create(&space, &host, V2_SPACE_SIZE, page_size,
                             V2_ISLAND_STRIDE, V2_ISLAND_SIZE);
    if (status != 0) {
        die("cannot reserve the guest address space", NULL);
    }
    printf("[v2] space 0x%llx..0x%llx page=0x%zx\n",
           (unsigned long long)(uintptr_t)v2_space_base(space),
           (unsigned long long)((uintptr_t)v2_space_base(space) +
                                v2_space_length(space)),
           page_size);

    file = read_file(elf_path, &file_length);
    if (file == NULL) {
        die("cannot read", elf_path);
    }
    status = v2_elf_parse(file, file_length, &image, error, sizeof(error));
    if (status != 0) {
        die("parse", error);
    }
    printf("[v2] elf %s type=%u segments=%d entry=0x%llx\n", elf_path,
           image.type, image.segment_count, (unsigned long long)image.entry);

    v2_patch_init(&patcher, space);
    patcher.entry_svc = (uint64_t)(uintptr_t)&v2_syscall_entry;
    patcher.entry_mrs = patcher.entry_svc;
    patcher.entry_msr = patcher.entry_svc;

    fd = open(elf_path, O_RDONLY);
    if (fd < 0) {
        die("cannot reopen", elf_path);
    }
    status = v2_elf_load(space, fd, &image, 0, &patcher, &load, error,
                         sizeof(error));
    close(fd);
    if (status != 0) {
        die("load", error);
    }
    free(file);
    printf("[v2] load base=0x%llx entry=0x%llx span=0x%llx\n",
           (unsigned long long)load.base, (unsigned long long)load.entry,
           (unsigned long long)load.span);
    printf("[v2] patch svc=%u mrs=%u msr=%u\n", patcher.counts[V2_PATCH_SVC],
           patcher.counts[V2_PATCH_MRS], patcher.counts[V2_PATCH_MSR]);

    status = v2_elf_protect(space, &image, &load, error, sizeof(error));
    if (status != 0) {
        die("protect", error);
    }
    status = v2_patch_seal(&patcher, error, sizeof(error));
    if (status != 0) {
        die("seal", error);
    }

    status = v2_proc_init(&proc, space, root);
    if (status != 0) {
        die("proc", "bad root");
    }
    proc.patcher = &patcher;
    proc.image_base = load.base;
    proc.image_entry = load.entry;
    proc.image_phdr = load.base + image.phoff;
    proc.image_phnum = image.phnum;
    proc.image_phent = image.phentsize;

    heap = (uint64_t)v2_space_map(space, NULL, V2_HEAP_SIZE,
                                  V2_PROT_READ | V2_PROT_WRITE, V2_MAP_ANON,
                                  -1, 0);
    if ((int64_t)heap <= 0) {
        die("heap", "cannot map 64 MiB contiguously");
    }
    proc.brk_base = heap;
    proc.brk_current = heap;
    proc.brk_limit = heap + V2_HEAP_SIZE;

    stack = (uint64_t)v2_space_map(space, NULL, V2_STACK_SIZE,
                                   V2_PROT_READ | V2_PROT_WRITE, V2_MAP_ANON,
                                   -1, 0);
    if ((int64_t)stack <= 0) {
        die("stack", "cannot map 8 MiB contiguously");
    }
    proc.stack_base = stack;
    proc.stack_top = stack + V2_STACK_SIZE;

    guest_envp[0] = "PATH=/";
    guest_envp[1] = "HOME=/";
    guest_envp[2] = NULL;

    memset(&aux, 0, sizeof(aux));
    aux.phdr = proc.image_phdr;
    aux.phnum = image.phnum;
    aux.phent = image.phentsize;
    aux.entry = load.entry;
    aux.base = 0;
    aux.pagesz = page_size;
    aux.hwcap = 0;
    aux.execfn = elf_path;

    sp = v2_stack_build(space, proc.stack_top, guest_argc, guest_argv, 2,
                        guest_envp, &aux);
    if (sp == 0) {
        die("stack", "cannot build the initial stack");
    }
    printf("[v2] stack top=0x%llx sp=0x%llx argc=%d\n",
           (unsigned long long)proc.stack_top, (unsigned long long)sp,
           guest_argc);

    memset(&cpu, 0, sizeof(cpu));
    cpu.pc = load.entry;
    cpu.sp = sp;

    v2_current_process = &proc;
    v2_current_patcher = &patcher;
    v2_tls_shadow = 0;

    image_base = load.start;
    image_end = load.start + load.span;
    space_base = (uint64_t)(uintptr_t)v2_space_base(space);
    space_end = space_base + v2_space_length(space);

    printf("[v2] enter\n");
    fflush(stdout);
    v2_guest_enter(cpu.pc, cpu.sp);
    return 0;
}

#else

#include <stdio.h>

int main(void)
{
    fprintf(stderr, "guest-runner only builds for macOS on aarch64\n");
    return 2;
}

#endif
