#!/usr/bin/env python3
"""
Mechanical transcription of src/vspace.c, used to check the C implementation
against the traces before a compiler is available (there is no C toolchain on
the workstation that wrote it; CI is the first real compile).

This file is transcribed from the C, not from the model.  If it and the traces
disagree, either the C and the model disagree, or the transcription is wrong --
both are worth knowing before pushing.

Not part of the build; keep it in sync by hand.
"""

import sys

FREE, RESERVED, MAPPED = 0x00, 0x80, 0x10
PROT_MASK = 0x07
MAP_FIXED = 0x10
MAP_FIXED_NOREPLACE = 0x100000
MREMAP_MAYMOVE = 0x1
MREMAP_FIXED = 0x2
EINVAL, ENOMEM, EEXIST, EIO, EFAULT = 22, 12, 17, 5, 14


class C:
    def __init__(self, base, pages, page_size, island_size=0x10000, stride=0x4000000):
        self.base = base
        self.page_size = page_size
        self.page_count = pages
        self.length = pages * page_size
        self.state = bytearray(pages)
        length = self.length
        offset = 0
        while offset < length:
            first = offset // page_size
            last = min(pages, (offset + island_size) // page_size)
            for p in range(first, last):
                self.state[p] = RESERVED
            if stride > length:
                break
            offset += stride
        self.alloc_start = (island_size + page_size - 1) // page_size
        if self.alloc_start > pages:
            self.alloc_start = pages
        self.cursor = self.alloc_start

    # --- helpers, exactly as the C spells them ---------------------------
    def pages_for(self, length):
        count = length // self.page_size
        if length % self.page_size:
            count += 1
        return count

    def release_pages(self, first, count):
        for page in range(first, first + count):
            if self.state[page] & RESERVED:
                continue
            self.state[page] = FREE

    def scan(self, lo, hi, count):
        run = 0
        start = lo
        for page in range(lo, hi):
            if self.state[page] == FREE:
                if run == 0:
                    start = page
                run += 1
                if run == count:
                    return start
            else:
                run = 0
        return None

    def find_run(self, count):
        if count == 0 or count > self.page_count:
            return None
        found = self.scan(self.cursor, self.page_count, count)
        if found is not None:
            return found
        return self.scan(self.alloc_start, self.cursor, count)

    def commit(self, first, count, prot):
        for page in range(first, first + count):
            self.state[page] = MAPPED | (prot & PROT_MASK)

    # --- operations ------------------------------------------------------
    def map(self, hint, length, prot, flags):
        if length == 0:
            return -EINVAL
        count = self.pages_for(length)
        if count == 0:
            return -EINVAL
        if count > self.page_count:
            return -ENOMEM
        fixed = (flags & (MAP_FIXED | MAP_FIXED_NOREPLACE)) != 0
        first = 0
        if fixed:
            if hint == 0 or hint % self.page_size:
                return -EINVAL
            if hint < self.base:
                return -EINVAL
            first = (hint - self.base) // self.page_size
            if first + count > self.page_count:
                return -EINVAL
            for page in range(first, first + count):
                if self.state[page] & RESERVED:
                    return -EINVAL
            if flags & MAP_FIXED_NOREPLACE:
                for page in range(first, first + count):
                    if self.state[page] & MAPPED:
                        return -EEXIST
            else:
                for page in range(first, first + count):
                    if self.state[page] & MAPPED:
                        pass          # host decommit; state unchanged here
                self.release_pages(first, count)
        else:
            found = self.find_run(count)
            if found is None:
                return -ENOMEM
            first = found
            self.cursor = first + count
            if self.cursor >= self.page_count:
                self.cursor = self.alloc_start
        self.commit(first, count, prot)
        return self.base + first * self.page_size

    def unmap(self, addr, length):
        if length == 0 or addr % self.page_size:
            return -EINVAL
        if addr < self.base:
            return -EINVAL
        first = (addr - self.base) // self.page_size
        if first >= self.page_count:
            return 0
        count = self.pages_for(length)
        if count > self.page_count - first:
            count = self.page_count - first
        for page in range(first, first + count):
            if self.state[page] & MAPPED:
                pass              # host decommit
        self.release_pages(first, count)
        if first < self.cursor:
            self.cursor = first if first > self.alloc_start else self.alloc_start
        return 0

    def protect(self, addr, length, prot):
        if length == 0 or addr % self.page_size:
            return -EINVAL
        if addr < self.base:
            return -EINVAL
        first = (addr - self.base) // self.page_size
        if first >= self.page_count:
            return -ENOMEM
        count = self.pages_for(length)
        if count > self.page_count - first:
            count = self.page_count - first
        for page in range(first, first + count):
            if self.state[page] & RESERVED:
                continue
            if not (self.state[page] & MAPPED):
                return -ENOMEM
        for page in range(first, first + count):
            if self.state[page] & RESERVED:
                continue
            self.state[page] = MAPPED | (prot & PROT_MASK)
        return 0

    def remap(self, addr, old_length, new_length, flags):
        if old_length == 0 or new_length == 0 or addr % self.page_size:
            return -EINVAL
        if flags & MREMAP_FIXED:
            return -EINVAL
        if addr < self.base:
            return -EINVAL
        if new_length <= old_length and not (flags & MREMAP_MAYMOVE):
            return addr
        count_old = self.pages_for(old_length)
        count_new = self.pages_for(new_length)
        first = self.find_run(count_new)
        if first is None:
            return -ENOMEM
        self.cursor = first + count_new
        if self.cursor >= self.page_count:
            self.cursor = self.alloc_start
        old_first = (addr - self.base) // self.page_size
        prot = (self.state[old_first] & PROT_MASK) if (self.state[old_first] & MAPPED) else 0
        self.commit(first, count_new, 3)
        if prot != 3:
            for page in range(first, first + count_new):
                self.state[page] = MAPPED | (prot & PROT_MASK)
        self.unmap(addr, count_old * self.page_size)
        if old_first < self.cursor:
            self.cursor = old_first if old_first > self.alloc_start else self.alloc_start
        return self.base + first * self.page_size

    def hash(self):
        h = 0xCBF29CE484222325
        for value in self.state:
            h = ((h ^ value) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
        return h


def main(paths):
    failures = 0
    total = 0
    for path in paths:
        lines = open(path, encoding='ascii').read().splitlines()
        header = dict(token.split('=') for token in lines[0].split() if '=' in token)
        pages = int(header['pages'])
        page_size = int(header['page'], 16)
        space = C(0x140000000, pages, page_size)
        index = 1
        ops = 0
        while index < len(lines):
            op = lines[index].split()
            expected = lines[index + 1].strip()
            kind = op[0]
            if kind == 'M':
                result = space.map(int(op[1], 16), int(op[2], 16),
                                   int(op[3]), int(op[4]))
            elif kind == 'U':
                result = space.unmap(int(op[1], 16), int(op[2], 16))
            elif kind == 'P':
                result = space.protect(int(op[1], 16), int(op[2], 16), int(op[3]))
            elif kind == 'R':
                result = space.remap(int(op[1], 16), int(op[2], 16),
                                     int(op[3], 16), int(op[4]))
            else:
                raise SystemExit(f"{path}: bad op {kind}")
            if result < 0:
                actual = "=-0x%x 0x%x" % (-result, space.hash())
            else:
                actual = "=0x%x 0x%x" % (result, space.hash())
            if actual != expected:
                failures += 1
                print(f"{path}:{ops}\n  op       {' '.join(op)}\n"
                      f"  expected {expected}\n  actual   {actual}")
                if failures > 8:
                    return 1
            index += 2
            ops += 1
        total += ops
        print(f"{path}: {ops} operations, {'ok' if failures == 0 else 'MISMATCH'}")
    print(f"{total} operations, {failures} mismatches")
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:] or ['tests/trace/basic.tsv']))
