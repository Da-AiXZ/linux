/*
 * v2/entry_aarch64.c -- the two places where C calls into guest code and
 * guest code calls back into C.
 *
 * Everything here is a naked function with hand-written instructions.  Two
 * rules are load-bearing:
 *
 *   - the frame layout must match struct v2_cpu byte for byte (272 bytes);
 *   - the return to the guest is an explicit `br` to the stashed pc, never a
 *     `ret`, because the guest's x30 belongs to the guest.
 *
 * x16 (IP0) is clobbered on the way back.  That is the one register the
 * guest ABI does not need preserved across a syscall: no compiler keeps a
 * value in x16/x17 across a call.
 *
 * The dispatcher runs on its own stack, not the guest's.  It used to run on the
 * guest's, which put the host's return addresses a kilobyte below the guest's
 * sp -- inside memory the guest is free to use and, on Linux, would have been
 * zeros or its own leftovers.  A guest that reads an uninitialised local then
 * reads whatever the host left behind, and that differs from run to run.
 */
#include "v2/cpu.h"

#if defined(__aarch64__)

#if defined(__APPLE__)
#define V2_CALL(name) "bl _" #name "\n"
#else
#define V2_CALL(name) "bl " #name "\n"
#endif

#if defined(__APPLE__)
#define V2_ASM(name) "_" #name
#else
#define V2_ASM(name) #name
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
 */
#define V2_HOST_STACK_SIZE 262144
unsigned char v2_host_stack[V2_HOST_STACK_SIZE] __attribute__((aligned(16)));

__attribute__((naked, used)) void v2_syscall_entry(void)
{
    __asm__ volatile(
        "sub  sp, sp, #272\n"
        "stp  x0, x1, [sp, #0]\n"
        "stp  x2, x3, [sp, #16]\n"
        "stp  x4, x5, [sp, #32]\n"
        "stp  x6, x7, [sp, #48]\n"
        "stp  x8, x9, [sp, #64]\n"
        "stp  x10, x11, [sp, #80]\n"
        "stp  x12, x13, [sp, #96]\n"
        "stp  x14, x15, [sp, #112]\n"
        /* x16 is not saved: nothing reads it back, and its value is the host's. */
        "str  x17, [sp, #136]\n"
        "stp  x18, x19, [sp, #144]\n"
        "stp  x20, x21, [sp, #160]\n"
        "stp  x22, x23, [sp, #176]\n"
        "stp  x24, x25, [sp, #192]\n"
        "stp  x26, x27, [sp, #208]\n"
        "stp  x28, x29, [sp, #224]\n"
        "str  x30, [sp, #240]\n"
        "add  x9, sp, #272\n"
        "str  x9, [sp, #248]\n"
        "str  x17, [sp, #256]\n"
        "mrs  x9, nzcv\n"
        "str  x9, [sp, #264]\n"
        "mov  x19, sp\n"
        /*
         * The floating point and SIMD state, which the guest also owns.  A Linux
         * syscall preserves q0..q31, FPCR and FPSR; this trampoline preserved
         * none of them, so every call handed the guest back whatever the host's
         * formatting and copying code had left in those registers.  They live
         * below the frame because the frame's layout is the guest's struct.
         */
        "sub  sp, sp, #528\n"
        "stp  q0, q1, [sp, #0]\n"
        "stp  q2, q3, [sp, #32]\n"
        "stp  q4, q5, [sp, #64]\n"
        "stp  q6, q7, [sp, #96]\n"
        "stp  q8, q9, [sp, #128]\n"
        "stp  q10, q11, [sp, #160]\n"
        "stp  q12, q13, [sp, #192]\n"
        "stp  q14, q15, [sp, #224]\n"
        "stp  q16, q17, [sp, #256]\n"
        "stp  q18, q19, [sp, #288]\n"
        "stp  q20, q21, [sp, #320]\n"
        "stp  q22, q23, [sp, #352]\n"
        "stp  q24, q25, [sp, #384]\n"
        "stp  q26, q27, [sp, #416]\n"
        "stp  q28, q29, [sp, #448]\n"
        "stp  q30, q31, [sp, #480]\n"
        "mrs  x9, fpcr\n"
        "str  x9, [sp, #512]\n"
        "mrs  x9, fpsr\n"
        "str  x9, [sp, #520]\n"
        "adrp x10, " V2_ASM(v2_host_stack) "@PAGE\n"
        "add  x10, x10, " V2_ASM(v2_host_stack) "@PAGEOFF\n"
        "mov  x11, #" "262144" "\n"
        "add  x10, x10, x11\n"
        "mov  sp, x10\n"
        "mov  x0, x19\n"
        V2_CALL(v2_syscall_dispatch)
        "mov  sp, x19\n"
        "sub  sp, sp, #528\n"
        "ldp  q0, q1, [sp, #0]\n"
        "ldp  q2, q3, [sp, #32]\n"
        "ldp  q4, q5, [sp, #64]\n"
        "ldp  q6, q7, [sp, #96]\n"
        "ldp  q8, q9, [sp, #128]\n"
        "ldp  q10, q11, [sp, #160]\n"
        "ldp  q12, q13, [sp, #192]\n"
        "ldp  q14, q15, [sp, #224]\n"
        "ldp  q16, q17, [sp, #256]\n"
        "ldp  q18, q19, [sp, #288]\n"
        "ldp  q20, q21, [sp, #320]\n"
        "ldp  q22, q23, [sp, #352]\n"
        "ldp  q24, q25, [sp, #384]\n"
        "ldp  q26, q27, [sp, #416]\n"
        "ldp  q28, q29, [sp, #448]\n"
        "ldp  q30, q31, [sp, #480]\n"
        "ldr  x9, [sp, #512]\n"
        "msr  fpcr, x9\n"
        "ldr  x9, [sp, #520]\n"
        "msr  fpsr, x9\n"
        "add  sp, sp, #528\n"
        "ldr  x9, [sp, #264]\n"
        "msr  nzcv, x9\n"
        "ldp  x0, x1, [sp, #0]\n"
        "ldp  x2, x3, [sp, #16]\n"
        "ldp  x4, x5, [sp, #32]\n"
        "ldp  x6, x7, [sp, #48]\n"
        "ldp  x8, x9, [sp, #64]\n"
        "ldp  x10, x11, [sp, #80]\n"
        "ldp  x12, x13, [sp, #96]\n"
        "ldp  x14, x15, [sp, #112]\n"
        "ldp  x18, x19, [sp, #144]\n"
        "ldp  x20, x21, [sp, #160]\n"
        "ldp  x22, x23, [sp, #176]\n"
        "ldp  x24, x25, [sp, #192]\n"
        "ldp  x26, x27, [sp, #208]\n"
        "ldp  x28, x29, [sp, #224]\n"
        "ldr  x30, [sp, #240]\n"
        "ldr  x16, [sp, #256]\n"
        "ldr  x17, [sp, #128 + 8]\n"
        "add  sp, sp, #272\n"
        "br   x16\n");
}

__attribute__((naked, noreturn, used)) void v2_guest_enter(
    const struct v2_cpu *cpu)
{
    /*
     * Every register, not just the two that matter.
     *
     * This used to take (pc, sp) and set nothing else, which meant the guest's
     * x0..x30 were whatever the host happened to hold at that moment -- for the
     * runner that is the host's own stack and heap addresses, so they differed
     * from run to run and by roughly an address-space worth of bits.  Nothing
     * noticed because the entry hash covers memory, not registers, and musl's
     * _dlstart only reads sp; but the fingerprints taken at the first syscall
     * boundary differed on every run, which means the guest had already stored
     * some of that residue into its own memory.
     *
     * A guest that starts from a defined state is the premise the whole
     * determinism argument rests on, so it starts from the struct.
     */
    __asm__ volatile(
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
         * first; these were not, so every guest began with whatever SIMD state
         * the host had, spilled it to its own stack, and the spilled words
         * differed between runs -- which is what the stack comparison kept
         * finding, one random-looking doubleword at a time.
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
        "br   x16\n");
}

#endif /* __aarch64__ */
