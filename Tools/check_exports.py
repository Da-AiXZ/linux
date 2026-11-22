#!/usr/bin/env python3
"""Verify that a shared object exports the given symbols.

The instrumented libz replaces Alpine's libz.so.1 by soname, so a missing
export is not a build error -- it only shows up on the device as
"Error relocating ...: <name>: symbol not found" and costs a reinstall to
discover.  Checking the ELF dynamic symbol table in CI turns that into a
one-second failure here instead.

Usage: check_exports.py <so> <symbol> [<symbol> ...]
Exit code 0 when every symbol is exported, 1 otherwise.
"""

import struct
import sys

SHT_DYNSYM = 11
SHN_UNDEF = 0
STB_GLOBAL = 1
STB_WEAK = 2


def dynamic_symbols(path):
    """Return the set of symbol names defined in the .dynsym section."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:4] != b"\x7fELF":
        raise ValueError(f"{path}: not an ELF file")
    if data[4] != 2:
        raise ValueError(f"{path}: not ELF64")

    section_offset = struct.unpack_from("<Q", data, 0x28)[0]
    section_size = struct.unpack_from("<H", data, 0x3A)[0]
    section_count = struct.unpack_from("<H", data, 0x3C)[0]

    names = set()
    for index in range(section_count):
        base = section_offset + index * section_size
        if base + section_size > len(data):
            break
        kind = struct.unpack_from("<I", data, base + 0x04)[0]
        if kind != SHT_DYNSYM:
            continue
        offset = struct.unpack_from("<Q", data, base + 0x18)[0]
        size = struct.unpack_from("<Q", data, base + 0x20)[0]
        entry_size = struct.unpack_from("<Q", data, base + 0x38)[0] or 24
        # sh_link points at the string table for this symbol table
        string_section = struct.unpack_from("<I", data, base + 0x28)[0]

        string_base = section_offset + string_section * section_size
        string_offset = struct.unpack_from("<Q", data, string_base + 0x18)[0]
        string_size = struct.unpack_from("<Q", data, string_base + 0x20)[0]
        strings = data[string_offset:string_offset + string_size]

        for entry in range(offset, min(offset + size, len(data)), entry_size):
            name_offset = struct.unpack_from("<I", data, entry)[0]
            info = data[entry + 4]
            shndx = struct.unpack_from("<H", data, entry + 6)[0]
            if shndx == SHN_UNDEF:
                continue
            binding = info >> 4
            if binding not in (STB_GLOBAL, STB_WEAK):
                continue
            end = strings.find(b"\x00", name_offset)
            if end < 0:
                continue
            names.add(strings[name_offset:end].decode("ascii", "replace"))
    return names


def main(argv):
    if len(argv) < 3:
        print("usage: check_exports.py <so> <symbol> [<symbol> ...]",
              file=sys.stderr)
        return 2
    path = argv[1]
    required = argv[2:]
    available = dynamic_symbols(path)
    missing = [name for name in required if name not in available]
    if missing:
        print(f"missing exports in {path}: {' '.join(missing)}")
        print(f"defined symbols: {len(available)}")
        return 1
    print(f"all {len(required)} required symbols exported by {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
