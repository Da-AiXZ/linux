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
#include "v2/vmops.h"
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
static uint64_t link_base;
static uint64_t link_end;
static uint64_t space_base;
static uint64_t space_end;
/*
 * The fault handler runs with a broken guest, so it may only call functions
 * that cannot touch guest memory.  v2_space_guard_at reads the guard array,
 * which lives in host memory next to the page table, so it is safe here and
 * it turns "addr = space + 0x..." into a verdict.
 */
static struct v2_space *fault_space;

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
    if (fault_space != NULL && v2_space_guard_at(fault_space, info->si_addr)) {
        /*
         * This is the line the whole guard experiment exists for: it says the
         * faulting address is the page we deliberately left empty after a
         * mapping, so the access ran past the end of whatever was mapped just
         * below it, and `pc` names the code that did it.
         */
        fprintf(stderr, "[v2] GUARD PAGE: this access left the mapping below "
                        "it; pc above is the writer\n");
    }
    if (fault_space != NULL) {
        /*
         * What the table thinks of the page that faulted.  A SIGBUS in the
         * dynamic loader's memcpy on a page this table calls MAPPED means the
         * table and the host disagree -- which is the one state v2 exists to
         * make impossible.  A page the table calls FREE means we handed a free
         * page to memcpy, which is our caller's mistake but at least a
         * legible one.
         */
        int page_state = v2_space_state_at(fault_space, info->si_addr);

        fprintf(stderr, "[v2] page state=0x%02x (%s%s%s%s) guard=%d\n",
                (unsigned)page_state,
                (page_state & V2_PAGE_MAPPED) ? "MAPPED " : "free ",
                (page_state & V2_PAGE_RESERVED) ? "RESERVED " : "",
                (page_state & V2_PROT_READ) ? "r" : "-",
                (page_state & V2_PROT_WRITE) ? "w" : "-",
                v2_space_guard_at(fault_space, info->si_addr));
    }
#if defined(__APPLE__)
    /*
     * The registers at the fault.  "addr=0x6516" alone says nothing about
     * where that pointer came from; x0..x15 and lr usually make it obvious
     * which argument was never filled in.
     */
    {
        const struct __darwin_arm_thread_state64 *regs =
            &state->uc_mcontext->__ss;

        fprintf(stderr, "[v2] x0..x7  %016llx %016llx %016llx %016llx"
                        " %016llx %016llx %016llx %016llx\n",
                regs->__x[0], regs->__x[1], regs->__x[2], regs->__x[3],
                regs->__x[4], regs->__x[5], regs->__x[6], regs->__x[7]);
        fprintf(stderr, "[v2] x8..x15 %016llx %016llx %016llx %016llx"
                        " %016llx %016llx %016llx %016llx\n",
                regs->__x[8], regs->__x[9], regs->__x[10], regs->__x[11],
                regs->__x[12], regs->__x[13], regs->__x[14], regs->__x[15]);
        fprintf(stderr, "[v2] lr=%016llx sp=%016llx\n",
                (unsigned long long)regs->__lr,
                (unsigned long long)regs->__sp);
    }
#endif
    /* The instructions around pc, when they are inside the guest. */
    if (link_base != 0 && pc >= link_base && pc < link_end) {
        fprintf(stderr, "[v2] pc is inside the interpreter (+0x%llx)\n",
                (unsigned long long)(pc - link_base));
    } else if (image_base != 0 && pc >= image_base && pc < image_end) {
        fprintf(stderr, "[v2] pc is inside the program (+0x%llx)\n",
                (unsigned long long)(pc - image_base));
    }
    if (space_base != 0 && pc >= space_base + 8 && pc + 8 <= space_end) {
        /*
         * The bracketed word is the faulting instruction.  It used to start at
         * pc-16 with the brackets on the third word, which bracketed pc-8 --
         * a report that names the wrong instruction is worse than none, and
         * this one cost a wrong hypothesis before it was noticed.
         */
        const uint32_t *words = (const uint32_t *)(uintptr_t)(pc - 8);

        fprintf(stderr, "[v2] code: %08x %08x [%08x] %08x %08x   (pc-8..pc+8)\n",
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

/*
 * The app's version string lives in Info.plist and can be replaced by an
 * install that failed to replace the executable -- that is exactly what
 * happened on 0.1.11.12, whose log announced a new version and ran the last
 * version's code.  A stamp inside the binary is the only claim an install
 * cannot fake, so the helper prints one.
 *
 * -Wdate-time exists because a timestamp makes builds unreproducible; that is
 * the point here, so it is silenced for this one function and nowhere else.
 */
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdate-time"
#endif
static const char *build_stamp(void)
{
    return __DATE__ " " __TIME__;
}
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

/*
 * One anonymous page, written, released, and asked for again at the same
 * address.  Linux promises the second mapping reads as zeros; v2's decommit
 * mprotects it PROT_NONE and calls madvise(MADV_DONTNEED), and on Darwin
 * madvise is a *hint* ("the system may reclaim these pages"), not a promise.
 *
 * If the page comes back dirty, then every .bss in every library can be seeded
 * with the previous occupant's bytes -- the tail of a segment is mapped
 * MAP_FIXED over pages that held another library a moment ago.  musl keeps its
 * globals, its dso chain and its exit list in exactly that .bss, which is the
 * shape of a bug whose symptom is "a random symbol is not found" and "a NULL
 * dereference while printing the error".
 *
 * It runs in its own throwaway space so the real arena is not shifted by a
 * single page: this is a measurement, and a measurement that changes the
 * layout cannot be compared with one that does not.
 */
static void page_zero_selftest(size_t page_size)
{
    struct v2_host host = v2_host_darwin();
    struct v2_space *probe = NULL;
    uint8_t *bytes;
    unsigned long long first;
    unsigned long long again;
    size_t dirty = 0;
    size_t discarded = 0;

    if (v2_space_create(&probe, &host, 8 * page_size, page_size, 0, 0) != 0) {
        fprintf(stderr, "[v2] pagetest: cannot reserve a probe space\n");
        return;
    }
    first = (unsigned long long)v2_space_map(probe, NULL, page_size,
                                             V2_PROT_READ | V2_PROT_WRITE,
                                             V2_MAP_ANON, -1, 0);
    if ((long long)first <= 0) {
        fprintf(stderr, "[v2] pagetest: cannot map a probe page\n");
        v2_space_destroy(probe);
        return;
    }
    memset((void *)(uintptr_t)first, 0xA5, page_size);
    v2_space_unmap(probe, (void *)(uintptr_t)first, page_size);

    again = (unsigned long long)v2_space_map(probe, (void *)(uintptr_t)first,
                                             page_size,
                                             V2_PROT_READ | V2_PROT_WRITE,
                                             V2_MAP_ANON | V2_MAP_FIXED, -1, 0);
    if ((long long)again <= 0) {
        fprintf(stderr, "[v2] pagetest: cannot remap the probe page\n");
        v2_space_destroy(probe);
        return;
    }
    bytes = (uint8_t *)(uintptr_t)again;
    for (size_t index = 0; index < page_size; index++) {
        if (bytes[index] != 0) {
            dirty++;
        }
    }
    fprintf(stderr, "[v2] pagetest: page reused after unmap is %s (%zu of %zu "
                    "bytes nonzero)\n",
            dirty == 0 ? "zero" : "DIRTY", dirty, page_size);

    /* The other path a guest can take: madvise(MADV_DONTNEED) on a live page. */
    memset(bytes, 0x5A, page_size);
    v2_space_advise(probe, (void *)(uintptr_t)again, page_size,
                    V2_MADV_DONTNEED);
    for (size_t index = 0; index < page_size; index++) {
        if (bytes[index] != 0) {
            discarded++;
        }
    }
    fprintf(stderr, "[v2] pagetest: madvise(DONTNEED) discarded %s (%zu of %zu "
                    "bytes still nonzero)\n",
            discarded == 0 ? "and zeroed the page" : "NOTHING",
            discarded, page_size);
    v2_space_destroy(probe);
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

/*
 * Register every PT_LOAD separately.  Comparing a whole image linearly against
 * the file is only correct when vaddr == offset for every segment: true for the
 * libraries ld.so maps (one mapping at offset zero), false for the program and
 * the interpreter, whose second segment starts at a different file offset than
 * its vaddr.  That mismatch produced a fake 569-byte "difference" in apk and
 * cost three rounds of instrumentation (ARCH 14.9).
 */
static void verify_note_segments(const char *host_path,
                                 const struct v2_elf_image *image,
                                 const struct v2_elf_load *load)
{
    for (int index = 0; index < image->segment_count; index++) {
        const struct v2_elf_segment *segment = &image->segments[index];

        if (segment->filesz == 0) {
            continue;
        }
        v2_verify_note_host(host_path, load->base + segment->vaddr,
                            (size_t)segment->filesz, segment->offset);
        if ((segment->flags & V2_PROT_WRITE) != 0) {
            v2_verify_note_writable(load->base + segment->vaddr,
                                    load->base + segment->vaddr +
                                        segment->memsz);
        }
    }
}

int main(int argc, char **argv)
{
    fprintf(stderr, "[v2] helper built %s\n", build_stamp());
    if (getenv("V2_PAGETEST") != NULL) {
        page_zero_selftest((size_t)sysconf(_SC_PAGESIZE));
    }
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
    struct v2_elf_image interp_image;
    struct v2_elf_load interp_load;
    struct v2_proc proc;
    struct v2_auxv aux;
    struct v2_cpu cpu;
    char error[192] = "";
    uint8_t *file;
    size_t file_length = 0;
    uint64_t heap;
    uint64_t stack;
    uint64_t aux_base_pending = 0;
    uint64_t jump_entry;
    uint64_t sp;
    size_t page_size;
    int fd;
    int status;

    /* V2_VERIFY=1 makes every file mapping prove it matches the file. */
    if (getenv("V2_VERIFY") != NULL) {
        v2_verify_mappings = 1;
    }
    memset(&interp_image, 0, sizeof(interp_image));
    memset(&interp_load, 0, sizeof(interp_load));

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
    fault_space = space;
    /*
     * V2_GUARD=1 leaves one empty page after every first-fit mapping, so a
     * write past the end of a mapping faults here instead of landing in the
     * next mapping's first page.  Bytes written *after* V2_VERIFY compared an
     * image against its file are invisible to that check, which is why the
     * flake survived three generations of instrumentation.
     *
     * One page, not sixteen: v2 keeps guest pages equal to host pages, so a
     * single page is exactly the boundary.  (v1 needed 16 KiB and still missed
     * three quarters of its mappings, because 4 KiB requests left a slack.)
     */
    if (getenv("V2_GUARD") != NULL) {
        if (v2_space_set_guard(space, 1) != 0) {
            die("guard pages", "cannot allocate the guard array");
        }
        fprintf(stderr, "[v2] guard: one page after every mapping\n");
    }
    if (getenv("V2_CHECK_SPACE") != NULL) {
        v2_check_space = 1;
        fprintf(stderr, "[v2] space check: every operation is verified\n");
    }
    fprintf(stderr, "[v2] space 0x%llx..0x%llx page=0x%zx\n",
           (unsigned long long)(uintptr_t)v2_space_base(space),
           (unsigned long long)((uintptr_t)v2_space_base(space) +
                                v2_space_length(space)),
           page_size);

    /*
     * The path translator is needed before the interpreter is loaded, and it
     * only needs the root, so it comes up before the ELF is parsed.
     */
    status = v2_proc_init(&proc, space, root);
    if (status != 0) {
        die("proc", "bad root");
    }

    file = read_file(elf_path, &file_length);
    if (file == NULL) {
        die("cannot read", elf_path);
    }
    status = v2_elf_parse(file, file_length, &image, error, sizeof(error));
    if (status != 0) {
        die("parse", error);
    }
    fprintf(stderr, "[v2] elf %s type=%u segments=%d entry=0x%llx\n", elf_path,
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
    /* Cover the images we mapped ourselves; V2_VERIFY compares them at exit. */
    verify_note_segments(elf_path, &image, &load);
    jump_entry = load.entry;   /* the interpreter replaces this below */
    fprintf(stderr, "[v2] load base=0x%llx entry=0x%llx span=0x%llx\n",
           (unsigned long long)load.base, (unsigned long long)load.entry,
           (unsigned long long)load.span);

    /*
     * A dynamically linked program names its interpreter in PT_INTERP.  The
     * kernel would load that file at a random base and jump to *its* entry,
     * with AT_BASE pointing at it and AT_PHDR/AT_ENTRY still describing the
     * main program -- because it is ld.so that reads the main program's
     * dynamic section and relocates it.
     */
    if (image.has_interp) {
        char host_path[V2_PATH_MAX * 2];
        char interp_error[192] = "";
        uint8_t *interp_file;
        size_t interp_length = 0;
        int interp_fd;

        status = v2_proc_translate(&proc, -100 /* AT_FDCWD */, image.interp,
                                   host_path, sizeof(host_path));
        if (status != 0) {
            die("cannot locate the interpreter", image.interp);
        }
        interp_file = read_file(host_path, &interp_length);
        if (interp_file == NULL) {
            die("cannot read the interpreter", host_path);
        }
        status = v2_elf_parse(interp_file, interp_length, &interp_image,
                              interp_error, sizeof(interp_error));
        if (status != 0) {
            die("interpreter parse", interp_error);
        }
        interp_fd = open(host_path, O_RDONLY);
        if (interp_fd < 0) {
            die("cannot reopen the interpreter", host_path);
        }
        status = v2_elf_load(space, interp_fd, &interp_image, 0, &patcher,
                             &interp_load, interp_error, sizeof(interp_error));
        close(interp_fd);
        free(interp_file);
        if (status != 0) {
            die("interpreter load", interp_error);
        }
        status = v2_elf_protect(space, &interp_image, &interp_load,
                                interp_error, sizeof(interp_error));
        if (status != 0) {
            die("interpreter protect", interp_error);
        }
        fprintf(stderr,
                "[v2] interp %s base=0x%llx entry=0x%llx span=0x%llx\n",
                image.interp, (unsigned long long)interp_load.base,
                (unsigned long long)interp_load.entry,
                (unsigned long long)interp_load.span);
        verify_note_segments(host_path, &interp_image, &interp_load);
        jump_entry = interp_load.entry;
        aux_base_pending = interp_load.base;
    }

    status = v2_elf_protect(space, &image, &load, error, sizeof(error));
    if (status != 0) {
        die("protect", error);
    }
    fprintf(stderr, "[v2] patch svc=%u mrs=%u msr=%u\n",
           patcher.counts[V2_PATCH_SVC], patcher.counts[V2_PATCH_MRS],
           patcher.counts[V2_PATCH_MSR]);

    status = v2_patch_seal(&patcher, error, sizeof(error));
    if (status != 0) {
        die("seal", error);
    }
    /*
     * The four bytes at each site now hold `b stub` instead of `svc`, so they
     * are the one difference the exit-time comparison must not report.  Every
     * other byte still has to match the file exactly.
     */
    for (int index = 0; index < patcher.site_count; index++) {
        v2_verify_ignore(patcher.sites[index].address, 4);
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
    aux.base = aux_base_pending;
    aux.pagesz = page_size;
    /*
     * AT_HWCAP.  Only FP and ASIMD are claimed: every aarch64 core has them,
     * and claiming more would make OpenSSL (inside libcrypto) select code
     * paths this runtime has never executed.  With AES/SHA bits clear it
     * uses portable C -- slower, and correct on any core.
     */
    aux.hwcap = 3;   /* HWCAP_FP | HWCAP_ASIMD */
    aux.execfn = elf_path;

    sp = v2_stack_build(space, proc.stack_top, guest_argc, guest_argv, 2,
                        guest_envp, &aux);
    if (sp == 0) {
        die("stack", "cannot build the initial stack");
    }
    fprintf(stderr, "[v2] stack top=0x%llx sp=0x%llx argc=%d\n",
           (unsigned long long)proc.stack_top, (unsigned long long)sp,
           guest_argc);

    memset(&cpu, 0, sizeof(cpu));
    cpu.pc = jump_entry;
    cpu.sp = sp;

    v2_current_process = &proc;
    v2_current_patcher = &patcher;
    v2_tls_shadow = 0;

    image_base = load.start;
    image_end = load.start + load.span;
    link_base = interp_load.start;
    link_end = interp_load.start + interp_load.span;
    space_base = (uint64_t)(uintptr_t)v2_space_base(space);
    space_end = space_base + v2_space_length(space);

    fprintf(stderr, "[v2] enter pc=0x%llx at_base=0x%llx\n",
            (unsigned long long)cpu.pc, (unsigned long long)aux.base);
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
