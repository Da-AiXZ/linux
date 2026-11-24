/*
 * v2/entry_aarch64.c -- the two places where C calls into guest code and
 * guest code calls back into C.
 *
 * Both are written as top-level assembly, not as `__attribute__((naked))`
 * functions.  GCC only learned `naked` for AArch64 in version 15; on the GCC 13
 * that Ubuntu ships the attribute is ignored with a warning, the compiler then
 * emits a prologue around the body, and the result is a stub that adjusts the
 * stack it was supposed to leave alone.  Assembly symbols are the same on every
 * compiler.
 *
 * Three rules are load-bearing:
 *
 *   - the frame layout must match struct v2_cpu byte for byte (800 bytes);
 *   - the return to the guest is an explicit `br` to the stashed pc, never a
 *     `ret`, because the guest's x30 belongs to the guest;
 *   - the frame lives in the host's .bss, not on the guest's stack.
 *
 * The last rule is the one that took longest to learn.  The frame used to be
 * pushed 800 bytes below the guest's sp, which is memory the guest owns: the
 * next deeper call reuses exactly those bytes, and any read-before-write in
 * the guest then returned a host stack address instead of zero.  Linux gives a
 * fresh stack page as zeros, so "the guest read something we never wrote" was
 * a difference between our runtime and the kernel it emulates -- and it moved
 * with the host's layout, which is the shape of every measurement in this bug.
 * A host frame in host memory cannot be read by the guest at all.
 *
 * x16 (IP0) is clobbered on the way back.  That is the one register the guest
 * ABI does not need preserved across a call.  x17 is also consumed by the stub
 * (it carries the site address), which is a real deviation from Linux -- the
 * kernel preserves both -- and it is recorded here rather than hidden: no
 * compiler keeps a live value in x16/x17 across a call, and the stub needs one
 * register to name the site.
 */
#include "v2/cpu.h"

#if defined(__aarch64__)

#if defined(__APPLE__)
#define V2_ASM(name) "_" #name
#define V2_CALL(name) "bl _" #name "\n"
/* Darwin's assembler wants @PAGE/@PAGEOFF; ELF wants :lo12:. */
#define V2_LEA(reg, name) \
    "adrp " reg ", " V2_ASM(name) "@PAGE\n" \
    "add  " reg ", " reg ", " V2_ASM(name) "@PAGEOFF\n"
#define V2_BEGIN(name) \
    ".text\n" \
    ".p2align 2\n" \
    ".globl " V2_ASM(name) "\n" \
    V2_ASM(name) ":\n"
#define V2_END(name) ""
#else
#define V2_ASM(name) #name
#define V2_CALL(name) "bl " #name "\n"
#define V2_LEA(reg, name) \
    "adrp " reg ", " #name "\n" \
    "add  " reg ", " reg ", :lo12:" #name "\n"
#define V2_BEGIN(name) \
    ".text\n" \
    ".p2align 2\n" \
    ".globl " #name "\n" \
    ".type " #name ", %function\n" \
    #name ":\n"
#define V2_END(name) ".size " #name ", . - " #name "\n"
#endif

/*
 * 256 KiB, sixteen-byte aligned.  The dispatcher plus a handler plus a directory
 * listing is nowhere near that; the size exists so a future handler with a large
 * local cannot quietly walk off the end.
 *
 * Declared in C rather than reserved with `.space` inside a top-level asm block:
 * that puts the bytes in __TEXT, which is executable and *not writable*, so the
 * first push faults.  It took a CI run to notice, and the fault it produced
 * looked exactly like the bug this file exists to fix.
 *
 * Hidden visibility so `adrp/add` against them needs no GOT indirection in a
 * PIE -- a preemptible symbol would make the linker refuse the pair.
 */
#define V2_HOST_STACK_SIZE 262144
unsigned char v2_host_stack[V2_HOST_STACK_SIZE]
    __attribute__((aligned(16), used, visibility("hidden")));

/*
 * The guest's register file while the dispatcher runs.  Host memory, host
 * lifetime, one guest at a time.  It is a global rather than a local of the
 * dispatcher because the entry code reaches it from assembly before any C
 * frame exists.
 */
struct v2_cpu v2_cpu_frame
    __attribute__((aligned(16), used, visibility("hidden")));

__asm__(
    V2_BEGIN(v2_syscall_entry)
    V2_LEA("x9", v2_cpu_frame)
    "stp  x0, x1, [x9, #0]\n"
    "stp  x2, x3, [x9, #16]\n"
    "stp  x4, x5, [x9, #32]\n"
    "stp  x6, x7, [x9, #48]\n"
    "stp  x8, x9, [x9, #64]\n"
    "stp  x10, x11, [x9, #80]\n"
    "stp  x12, x13, [x9, #96]\n"
    "stp  x14, x15, [x9, #112]\n"
    /* x16 is not saved: nothing reads it back, and its value is the host's. */
    "str  x17, [x9, #136]\n"
    "stp  x18, x19, [x9, #144]\n"
    "stp  x20, x21, [x9, #160]\n"
    "stp  x22, x23, [x9, #176]\n"
    "stp  x24, x25, [x9, #192]\n"
    "stp  x26, x27, [x9, #208]\n"
    "stp  x28, x29, [x9, #224]\n"
    "str  x30, [x9, #240]\n"
    /*
     * x9 was saved at #72 above and is now reused as the base register.  The
     * store read its base before it wrote, so the value in the frame is the
     * guest's; the reload makes that independent of the reader knowing it.
     */
    V2_LEA("x9", v2_cpu_frame)
    "mov  x10, sp\n"
    "str  x10, [x9, #248]\n"
    "str  x17, [x9, #256]\n"
    "mrs  x10, nzcv\n"
    "str  x10, [x9, #264]\n"
    /*
     * The floating point and SIMD state, which the guest also owns.  A Linux
     * syscall preserves q0..q31, FPCR and FPSR; this trampoline preserved none
     * of them, so every call handed the guest back whatever the host's
     * formatting and copying code had left in those registers.
     */
    "stp  q0, q1, [x9, #272]\n"
    "stp  q2, q3, [x9, #304]\n"
    "stp  q4, q5, [x9, #336]\n"
    "stp  q6, q7, [x9, #368]\n"
    "stp  q8, q9, [x9, #400]\n"
    "stp  q10, q11, [x9, #432]\n"
    "stp  q12, q13, [x9, #464]\n"
    "stp  q14, q15, [x9, #496]\n"
    "stp  q16, q17, [x9, #528]\n"
    "stp  q18, q19, [x9, #560]\n"
    "stp  q20, q21, [x9, #592]\n"
    "stp  q22, q23, [x9, #624]\n"
    "stp  q24, q25, [x9, #656]\n"
    "stp  q26, q27, [x9, #688]\n"
    "stp  q28, q29, [x9, #720]\n"
    "stp  q30, q31, [x9, #752]\n"
    "mrs  x10, fpcr\n"
    "str  x10, [x9, #784]\n"
    "mrs  x10, fpsr\n"
    "str  x10, [x9, #792]\n"
    "mov  x19, x9\n"
    V2_LEA("x10", v2_host_stack)
    "mov  x11, #" "262144" "\n"
    "add  x10, x10, x11\n"
    "mov  sp, x10\n"
    "mov  x0, x19\n"
    V2_CALL(v2_syscall_dispatch)
    "ldp  q0, q1, [x19, #272]\n"
    "ldp  q2, q3, [x19, #304]\n"
    "ldp  q4, q5, [x19, #336]\n"
    "ldp  q6, q7, [x19, #368]\n"
    "ldp  q8, q9, [x19, #400]\n"
    "ldp  q10, q11, [x19, #432]\n"
    "ldp  q12, q13, [x19, #464]\n"
    "ldp  q14, q15, [x19, #496]\n"
    "ldp  q16, q17, [x19, #528]\n"
    "ldp  q18, q19, [x19, #560]\n"
    "ldp  q20, q21, [x19, #592]\n"
    "ldp  q22, q23, [x19, #624]\n"
    "ldp  q24, q25, [x19, #656]\n"
    "ldp  q26, q27, [x19, #688]\n"
    "ldp  q28, q29, [x19, #720]\n"
    "ldp  q30, q31, [x19, #752]\n"
    "ldr  x10, [x19, #784]\n"
    "msr  fpcr, x10\n"
    "ldr  x10, [x19, #792]\n"
    "msr  fpsr, x10\n"
    "ldr  x10, [x19, #264]\n"
    "msr  nzcv, x10\n"
    /*
     * sp leaves the frame before the frame pointer does.  x19 is the only
     * register holding the frame, and it is also a guest register that has to
     * be restored -- so sp and the return site are read out first, into x10
     * (restored immediately after) and x16 (the one register the guest ABI
     * lets us clobber).
     */
    "ldr  x10, [x19, #248]\n"
    "mov  sp, x10\n"
    "ldr  x16, [x19, #256]\n"
    /*
     * x20..x30 too, and before x19: they are callee-saved for the guest, the
     * dispatcher is C, and a guest that keeps its thread pointer in x19..x28
     * reads host leftovers otherwise -- musl does.  An earlier revision of this
     * file restored x0..x19 and stopped, which cost a full decode of a fault at
     * pc=0 with x20..x30 holding the dispatcher's values.
     */
    "ldp  x20, x21, [x19, #160]\n"
    "ldp  x22, x23, [x19, #176]\n"
    "ldp  x24, x25, [x19, #192]\n"
    "ldp  x26, x27, [x19, #208]\n"
    "ldp  x28, x29, [x19, #224]\n"
    "ldr  x30, [x19, #240]\n"
    "ldp  x0, x1, [x19, #0]\n"
    "ldp  x2, x3, [x19, #16]\n"
    "ldp  x4, x5, [x19, #32]\n"
    "ldp  x6, x7, [x19, #48]\n"
    "ldp  x8, x9, [x19, #64]\n"
    "ldp  x10, x11, [x19, #80]\n"
    "ldp  x12, x13, [x19, #96]\n"
    "ldp  x14, x15, [x19, #112]\n"
    "ldp  x18, x19, [x19, #144]\n"
    "br   x16\n"
    V2_END(v2_syscall_entry)
);

/*
 * Every register, not just the two that matter.
 *
 * This used to take (pc, sp) and set nothing else, which meant the guest's
 * x0..x30 were whatever the host happened to hold at that moment -- for the
 * runner that is the host's own stack and heap addresses, so they differed from
 * run to run and by roughly an address-space worth of bits.  Nothing noticed
 * because the entry hash covers memory, not registers, and musl's _dlstart only
 * reads sp; but the fingerprints taken at the first syscall boundary differed on
 * every run, which means the guest had already stored some of that residue into
 * its own memory.
 *
 * A guest that starts from a defined state is the premise the whole determinism
 * argument rests on, so it starts from the struct.
 */
__asm__(
    V2_BEGIN(v2_guest_enter)
    "mov  x17, x0\n"
    "ldr  x16, [x17, #248]\n"
    "ldp  x0, x1, [x17, #0]\n"
    "ldp  x2, x3, [x17, #16]\n"
    "ldp  x4, x5, [x17, #32]\n"
    "ldp  x6, x7, [x17, #48]\n"
    "ldp  x8, x9, [x17, #64]\n"
    "ldp  x10, x11, [x17, #80]\n"
    "ldp  x12, x13, [x17, #96]\n"
    "ldp  x14, x15, [x17, #112]\n"
    "ldp  x18, x19, [x17, #144]\n"
    "ldp  x20, x21, [x17, #160]\n"
    "ldp  x22, x23, [x17, #176]\n"
    "ldp  x24, x25, [x17, #192]\n"
    "ldp  x26, x27, [x17, #208]\n"
    "ldp  x28, x29, [x17, #224]\n"
    "ldr  x30, [x17, #240]\n"
    "mov  sp, x16\n"
    "ldr  x16, [x17, #256]\n"
    /* A fresh Linux process starts with neutral floating point control. */
    "msr  fpcr, xzr\n"
    "msr  fpsr, xzr\n"
    /*
     * And with zeroed vector registers.  The general registers were fixed
     * first; these were not, so every guest began with whatever SIMD state the
     * host had, spilled it to its own stack, and the spilled words differed
     * between runs -- which is what the stack comparison kept finding, one
     * random-looking doubleword at a time.
     */
    "movi v0.16b, #0\n"
    "movi v1.16b, #0\n"
    "movi v2.16b, #0\n"
    "movi v3.16b, #0\n"
    "movi v4.16b, #0\n"
    "movi v5.16b, #0\n"
    "movi v6.16b, #0\n"
    "movi v7.16b, #0\n"
    "movi v8.16b, #0\n"
    "movi v9.16b, #0\n"
    "movi v10.16b, #0\n"
    "movi v11.16b, #0\n"
    "movi v12.16b, #0\n"
    "movi v13.16b, #0\n"
    "movi v14.16b, #0\n"
    "movi v15.16b, #0\n"
    "movi v16.16b, #0\n"
    "movi v17.16b, #0\n"
    "movi v18.16b, #0\n"
    "movi v19.16b, #0\n"
    "movi v20.16b, #0\n"
    "movi v21.16b, #0\n"
    "movi v22.16b, #0\n"
    "movi v23.16b, #0\n"
    "movi v24.16b, #0\n"
    "movi v25.16b, #0\n"
    "movi v26.16b, #0\n"
    "movi v27.16b, #0\n"
    "movi v28.16b, #0\n"
    "movi v29.16b, #0\n"
    "movi v30.16b, #0\n"
    "movi v31.16b, #0\n"
    "msr  nzcv, xzr\n"
    "mov  x17, xzr\n"
    "br   x16\n"
    V2_END(v2_guest_enter)
);

#endif /* __aarch64__ */
