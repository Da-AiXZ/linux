#!/usr/bin/env python3
"""
Build a tiny static aarch64 Linux ELF (ET_DYN) that writes a string and
exits. It has no relocations, no interpreter and no libc, so it is the
smallest end-to-end test for the guest loader: ELF mapping, svc #0
patching, the syscall dispatcher and JIT execution.
"""

import struct
import sys


def movz(rd, imm):
    return 0xD2800000 | ((imm & 0xFFFF) << 5) | rd


def adr(rd, offset):
    immlo = offset & 3
    immhi = (offset >> 2) & 0x7FFFF
    return 0x10000000 | (immlo << 29) | (immhi << 5) | rd


def build(message: bytes, fault_probe: bool = True) -> bytes:
    text_offset = 0x1000

    instrs = []
    instrs.append(movz(0, 1))                    # mov x0, #1
    instrs.append(0)                             # adr x1, message (patched below)
    instrs.append(movz(2, len(message)))         # mov x2, #len
    instrs.append(movz(8, 64))                   # mov x8, #__NR_write
    instrs.append(0xD4000001)                    # svc #0
    if fault_probe:
        instrs.append(movz(1, 0))                # mov x1, #0
        instrs.append(0xB9000020)                # str w0, [x1]  (fault probe)
    instrs.append(movz(0, 0))                    # mov x0, #0
    instrs.append(movz(8, 93))                   # mov x8, #__NR_exit
    instrs.append(0xD4000001)                    # svc #0
    instrs[1] = adr(1, 4 * len(instrs) - 4)

    code = b"".join(struct.pack("<I", i) for i in instrs) + message
    filesz = text_offset + len(code)

    e_ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\x00" * 8
    ehdr = struct.pack(
        "<16sHHIQQQIHHHHHH",
        e_ident,
        3,          # ET_DYN
        183,        # EM_AARCH64
        1,          # EV_CURRENT
        text_offset,
        64,         # e_phoff
        0,          # e_shoff
        0,          # e_flags
        64,         # e_ehsize
        56,         # e_phentsize
        1,          # e_phnum
        0,
        0,
        0,
    )

    phdr = struct.pack(
        "<IIQQQQQQ",
        1,              # PT_LOAD
        5,              # PF_R | PF_X
        0,              # p_offset
        0,              # p_vaddr
        0,              # p_paddr
        filesz,         # p_filesz
        filesz,         # p_memsz
        0x1000,         # p_align
    )

    blob = bytearray(ehdr + phdr)
    blob.extend(b"\x00" * (text_offset - len(blob)))
    blob.extend(code)
    return bytes(blob)


if __name__ == "__main__":
    output = sys.argv[1] if len(sys.argv) > 1 else "guest-hello.elf"
    probe = "--no-fault" not in sys.argv[2:]
    with open(output, "wb") as handle:
        handle.write(build(b"hello from linux elf\n", fault_probe=probe))
    print(f"wrote {output}")
