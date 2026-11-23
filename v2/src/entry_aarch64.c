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
 */
#include "v2/cpu.h"

#if defined(__aarch64__)

#if defined(__APPLE__)
#define V2_CALL(name) "bl _" #name "\n"
#else
#define V2_CALL(name) "bl " #name "\n"
#endif

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
        "stp  x16, x17, [sp, #128]\n"
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
        "mov  x0, sp\n"
        "mov  x1, x17\n"
        V2_CALL(v2_syscall_dispatch)
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

__attribute__((naked, noreturn, used)) void v2_guest_enter(uint64_t pc,
                                                           uint64_t sp)
{
    __asm__ volatile(
        "mov  x9, x0\n"
        "mov  sp, x1\n"
        "br   x9\n");
}

#endif /* __aarch64__ */
