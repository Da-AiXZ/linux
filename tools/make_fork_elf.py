#!/usr/bin/env python3
"""
Build a tiny static aarch64 Linux ELF (ET_DYN) that calls clone(SIGCHLD)
and lets both sides print:

    parent: write(1, "parent\\n", 7); exit(0)
    child:  write(1, "child\\n", 6);  exit(0)

No libc, no relocations, no interpreter.  It isolates `clone` (host fork)
from glibc, so a fault here points at the runtime rather than the guest
C library.
"""

import struct
import sys


def movz(rd, imm):
    return 0xD2800000 | ((imm & 0xFFFF) << 5) | rd


def adr(rd, offset):
    immlo = offset & 3
    immhi = (offset >> 2) & 0x7FFFF
    return 0x10000000 | (immlo << 29) | (immhi << 5) | rd


def cbz(rt, offset):
    return 0xB4000000 | (((offset >> 2) & 0x7FFFF) << 5) | rt


SVC = 0xD4000001

PARENT_MESSAGE = b"parent\n"
CHILD_MESSAGE = b"child\n"


def build() -> bytes:
    text_offset = 0x1000
    # ADR is PC-relative to the address of the ADR instruction itself.
    parent_adr_index = 8
    child_block_index = 15
    child_adr_index = 16
    instruction_count = 23
    parent_message_offset = instruction_count * 4
    child_message_offset = parent_message_offset + len(PARENT_MESSAGE)

    instrs = [
        movz(0, 17),                                   # clone(SIGCHLD, 0, 0, 0)
        movz(1, 0),
        movz(2, 0),
        movz(3, 0),
        movz(8, 220),                                  # __NR_clone
        SVC,
        cbz(0, (child_block_index - 6) * 4),           # child -> child block
        movz(0, 1),                                    # parent: write()
        adr(1, parent_message_offset - parent_adr_index * 4),
        movz(2, len(PARENT_MESSAGE)),
        movz(8, 64),
        SVC,
        movz(0, 0),                                    # parent: exit(0)
        movz(8, 93),
        SVC,
        movz(0, 1),                                    # child: write()
        adr(1, child_message_offset - child_adr_index * 4),
        movz(2, len(CHILD_MESSAGE)),
        movz(8, 64),
        SVC,
        movz(0, 0),                                    # child: exit(0)
        movz(8, 93),
        SVC,
    ]
    assert len(instrs) == instruction_count

    code = b"".join(struct.pack("<I", i) for i in instrs)
    code += PARENT_MESSAGE + CHILD_MESSAGE
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
        0,
        0,
        64,
        56,
        1,
        0,
        0,
        0,
    )
    phdr = struct.pack(
        "<IIQQQQQQ",
        1,              # PT_LOAD
        5,              # PF_R | PF_X
        0,
        0,
        0,
        filesz,
        filesz,
        0x1000,
    )
    blob = bytearray(ehdr + phdr)
    blob.extend(b"\x00" * (text_offset - len(blob)))
    blob.extend(code)
    return bytes(blob)


if __name__ == "__main__":
    output = sys.argv[1] if len(sys.argv) > 1 else "fork-test.elf"
    with open(output, "wb") as handle:
        handle.write(build())
    print(f"wrote {output}")
