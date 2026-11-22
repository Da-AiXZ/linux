#!/usr/bin/env python3
"""Count the patch sites GuestPatchCodeRange would rewrite in a guest ELF.

The loader scans every executable PT_LOAD segment in 4-byte steps and rewrites
three encodings:

    0xD4000001              svc #0
    (w & 0xFFFFFFE0)==D53BD040   mrs xN, tpidr_el0
    (w & 0xFFFFFFE0)==D51BD040   msr tpidr_el0, xN

This script reproduces exactly that scan, so the counts can be compared with
the `loaded ... patched=N tls_mrs=N tls_msr=N' line the device prints.  A
mismatch means the scan hit a word that is not really an instruction (for
example a literal-pool constant), which would silently corrupt guest code.

    python Tools/verify_patch_sites.py <elf> [--expect 478,90,1]
"""

import struct
import sys

PT_LOAD = 1
PF_X = 1


def executable_ranges(data):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit("not a little-endian ELF64 file")
    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
    e_phnum = struct.unpack_from("<H", data, 0x38)[0]
    for index in range(e_phnum):
        base = e_phoff + index * e_phentsize
        p_type = struct.unpack_from("<I", data, base)[0]
        p_flags = struct.unpack_from("<I", data, base + 4)[0]
        p_offset = struct.unpack_from("<Q", data, base + 8)[0]
        p_filesz = struct.unpack_from("<Q", data, base + 32)[0]
        if p_type == PT_LOAD and (p_flags & PF_X) and p_filesz >= 4:
            yield p_offset, p_offset + p_filesz


def count(path):
    with open(path, "rb") as handle:
        data = handle.read()
    svc = mrs = msr = 0
    for start, end in executable_ranges(data):
        for offset in range(start, end - 3, 4):
            word = struct.unpack_from("<I", data, offset)[0]
            if word == 0xD4000001:
                svc += 1
            elif (word & 0xFFFFFFE0) == 0xD53BD040:
                mrs += 1
            elif (word & 0xFFFFFFE0) == 0xD51BD040:
                msr += 1
    return svc, mrs, msr


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    svc, mrs, msr = count(path)
    print(f"{path}: svc={svc} mrs={mrs} msr={msr} sites={svc + mrs + msr}")

    for argument in sys.argv[2:]:
        if argument.startswith("--expect="):
            expected = [int(part) for part in argument.split("=", 1)[1].split(",")]
            actual = [svc, mrs, msr]
            if expected != actual:
                print(f"MISMATCH: device reports {expected}, static scan {actual}")
                raise SystemExit(1)
            print("counts match the device log")


if __name__ == "__main__":
    main()
