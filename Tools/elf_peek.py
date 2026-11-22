#!/usr/bin/env python3
"""Print the bytes and the nearest symbols around a virtual address in an ELF.

The device reports a crash as "pc in <base>+<offset>"; turning that offset into
a statement needs a disassembler, and the macOS runner has no llvm-objdump on
PATH.  This script maps the virtual address to a file offset through the
program headers, dumps the surrounding instruction words, and names the symbols
that bracket them, which is enough to identify the faulting load by hand.

Usage: elf_peek.py <elf> <vaddr-hex> [before] [after]
"""

import struct
import sys

PT_LOAD = 1


def segments(data):
    """Yield (vaddr, filesz, offset, flags) for every PT_LOAD."""
    program_offset = struct.unpack_from("<Q", data, 0x20)[0]
    entry_size = struct.unpack_from("<H", data, 0x36)[0]
    count = struct.unpack_from("<H", data, 0x38)[0]
    for index in range(count):
        base = program_offset + index * entry_size
        kind = struct.unpack_from("<I", data, base)[0]
        if kind != PT_LOAD:
            continue
        flags, offset, vaddr, _, filesz = struct.unpack_from("<IIQQQ", data,
                                                            base + 4)
        yield vaddr, filesz, offset, flags


def symbols(data):
    """Return [(value, name)] from .symtab when present."""
    section_offset = struct.unpack_from("<Q", data, 0x28)[0]
    section_size = struct.unpack_from("<H", data, 0x3A)[0]
    section_count = struct.unpack_from("<H", data, 0x3C)[0]
    found = []
    for index in range(section_count):
        base = section_offset + index * section_size
        if base + section_size > len(data):
            break
        kind = struct.unpack_from("<I", data, base + 0x04)[0]
        if kind != 2:  # SHT_SYMTAB
            continue
        offset = struct.unpack_from("<Q", data, base + 0x18)[0]
        size = struct.unpack_from("<Q", data, base + 0x20)[0]
        entry_size = struct.unpack_from("<Q", data, base + 0x38)[0] or 24
        link = struct.unpack_from("<I", data, base + 0x28)[0]
        string_base = section_offset + link * section_size
        string_offset = struct.unpack_from("<Q", data, string_base + 0x18)[0]
        string_size = struct.unpack_from("<Q", data, string_base + 0x20)[0]
        strings = data[string_offset:string_offset + string_size]
        for entry in range(offset, min(offset + size, len(data)), entry_size):
            name_offset = struct.unpack_from("<I", data, entry)[0]
            info = data[entry + 4]
            shndx = struct.unpack_from("<H", data, entry + 6)[0]
            value = struct.unpack_from("<Q", data, entry + 8)[0]
            if shndx == 0 or (info & 0x0F) not in (0, 1, 2):
                continue
            end = strings.find(b"\x00", name_offset)
            name = strings[name_offset:end].decode("ascii", "replace")
            if name:
                found.append((value, name))
    return sorted(found)


def main(argv):
    if len(argv) < 3:
        print("usage: elf_peek.py <elf> <vaddr-hex> [before] [after]",
              file=sys.stderr)
        return 2
    path = argv[1]
    target = int(argv[2], 16)
    before = int(argv[3], 16) if len(argv) > 3 else 0x10
    after = int(argv[4], 16) if len(argv) > 4 else 0x40
    data = open(path, "rb").read()

    start = target - before
    stop = target + after
    print(f"target vaddr 0x{target:x}, dumping 0x{start:x}..0x{stop:x}")
    for vaddr, filesz, offset, flags in segments(data):
        if not (vaddr <= start < vaddr + filesz):
            continue
        file_start = offset + (start - vaddr)
        chunk = data[file_start:file_start + (stop - start)]
        for index in range(0, len(chunk) - 3, 4):
            word = struct.unpack_from("<I", chunk, index)[0]
            mark = " <-- pc" if vaddr + (start - vaddr) + index == target else ""
            print(f"  0x{start + index:08x}: {word:08x}{mark}")
        break
    else:
        print("address is not inside any PT_LOAD")

    table = symbols(data)
    previous = None
    for value, name in table:
        if value <= target:
            previous = (value, name)
        else:
            print(f"symbol after : 0x{value:x} {name} (+0x{value - target:x})")
            break
    if previous is not None:
        print(f"symbol before: 0x{previous[0]:x} {previous[1]}"
              f" (+0x{target - previous[0]:x})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
