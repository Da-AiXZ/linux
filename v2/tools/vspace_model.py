#!/usr/bin/env python3
"""
vspace reference model — the normative definition of the v2 guest address
space.  The C implementation in src/vspace.c must agree with this file
byte for byte, and CI replays the traces this generates.

Why a model: the v1 runtime had no definition of its own address space at
all.  Four structures disagreed (host vm_region, GuestMmapRecords, the freed
ring, the runtime range list) and every failure was argued from whichever one
happened to be readable.  Here the page array *is* the address space, and
every rule below is executable.

Semantics (Linux arm64, page granular):
  - the space is one reservation of `pages` pages; guest page == host page
  - page 0 .. alloc_start-1 hold the trampoline islands and are never handed out
  - mmap returns a page-aligned address inside the space or -errno
  - MAP_FIXED replaces; MAP_FIXED_NOREPLACE fails with EEXIST
  - munmap/mprotect require a page-aligned address
  - remap with MAYMOVE copies through a fresh run
"""

import argparse
import random
import sys

PAGE = 0x4000
ISLAND_STRIDE = 0x4000000      # one island every 64 MiB
ISLAND_SIZE = 0x10000          # 64 KiB of stubs per island

EINVAL, ENOMEM, EEXIST, EFAULT = 22, 12, 17, 14

FREE, RESERVED, MAPPED = 0x00, 0x80, 0x10

MAP_FIXED = 0x10
MAP_ANON = 0x20
MAP_FIXED_NOREPLACE = 0x100000
MREMAP_MAYMOVE = 0x1
MREMAP_FIXED = 0x2


def fnv1a64(data):
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


class Space:
    def __init__(self, pages, base=0x140000000):
        self.pages = pages
        self.base = base
        self.state = bytearray(pages)          # the single source of truth
        self.alloc_start = 0
        self.cursor = 0
        # islands
        off = 0
        while off < pages * PAGE:
            first = off // PAGE
            last = min(pages, (off + ISLAND_SIZE) // PAGE)
            for p in range(first, last):
                self.state[p] = RESERVED
            off += ISLAND_STRIDE
        # first allocatable page after the first island
        self.alloc_start = (ISLAND_SIZE + PAGE - 1) // PAGE
        self.cursor = self.alloc_start

    # ---- helpers ---------------------------------------------------------
    def mapped(self, p):
        return (self.state[p] & MAPPED) != 0

    def prot(self, p):
        return self.state[p] & 0x07

    def reserved(self, p):
        return (self.state[p] & RESERVED) != 0

    def _aligned(self, addr):
        return (addr % PAGE) == 0

    def _num_pages(self, length):
        return (length + PAGE - 1) // PAGE

    def _page_index(self, addr):
        return (addr - self.base) // PAGE

    def _scan(self, lo, hi, count):
        run = 0
        start = lo
        for p in range(lo, hi):
            if self.state[p] == FREE:
                if run == 0:
                    start = p
                run += 1
                if run == count:
                    return start
            else:
                run = 0
        return None

    def _find_run(self, count):
        """First fit from cursor, then wrap once.  Deterministic."""
        if count > self.pages:
            return None
        found = self._scan(self.cursor, self.pages, count)
        if found is not None:
            return found
        return self._scan(self.alloc_start, self.cursor, count)

    def _commit(self, first, count, prot):
        for p in range(first, first + count):
            self.state[p] = MAPPED | (prot & 0x07)

    def _release(self, first, count):
        for p in range(first, first + count):
            if self.reserved(p):
                continue
            self.state[p] = FREE

    # ---- operations ------------------------------------------------------
    def map(self, hint, length, prot, flags):
        if length == 0:
            return -EINVAL
        count = self._num_pages(length)
        if count > self.pages:
            return -ENOMEM
        fixed = flags & MAP_FIXED or flags & MAP_FIXED_NOREPLACE
        if fixed:
            if hint == 0 or not self._aligned(hint):
                return -EINVAL
            if hint < self.base or hint + length > self.base + self.pages * PAGE:
                return -EINVAL
            first = self._page_index(hint)
            for p in range(first, first + count):
                if self.reserved(p):
                    return -EINVAL
            if flags & MAP_FIXED_NOREPLACE:
                for p in range(first, first + count):
                    if self.mapped(p):
                        return -EEXIST
            else:
                self._release(first, count)
        else:
            first = self._find_run(count)
            if first is None:
                return -ENOMEM
            self.cursor = first + count
            if self.cursor >= self.pages:
                self.cursor = self.alloc_start
        self._commit(first, count, prot)
        return self.base + first * PAGE

    def unmap(self, addr, length):
        if length == 0 or not self._aligned(addr):
            return -EINVAL
        if addr < self.base:
            return -EINVAL
        first = self._page_index(addr)
        if first >= self.pages:
            return 0
        count = min(self._num_pages(length), self.pages - first)
        self._release(first, count)
        if first < self.cursor:
            self.cursor = max(self.alloc_start, first)
        return 0

    def protect(self, addr, length, prot):
        if length == 0 or not self._aligned(addr):
            return -EINVAL
        if addr < self.base:
            return -EINVAL
        first = self._page_index(addr)
        if first >= self.pages:
            return -ENOMEM
        count = min(self._num_pages(length), self.pages - first)
        for p in range(first, first + count):
            if self.reserved(p):
                continue
            if not self.mapped(p):
                return -ENOMEM
        for p in range(first, first + count):
            if not self.reserved(p):
                self.state[p] = MAPPED | (prot & 0x07)
        return 0

    def remap(self, addr, old_len, new_len, flags):
        if old_len == 0 or new_len == 0 or not self._aligned(addr):
            return -EINVAL
        if flags & MREMAP_FIXED:
            return -EINVAL
        if addr < self.base:
            return -EINVAL
        if new_len <= old_len and not (flags & MREMAP_MAYMOVE):
            return addr
        count_old = self._num_pages(old_len)
        old_first = self._page_index(addr)
        if count_old > self.pages - old_first:
            count_old = self.pages - old_first
        count_new = self._num_pages(new_len)
        first = self._find_run(count_new)
        if first is None:
            return -ENOMEM
        self.cursor = first + count_new
        if self.cursor >= self.pages:
            self.cursor = self.alloc_start
        keep = min(count_old, count_new)
        prot = self.prot(old_first) if self.mapped(old_first) else 0
        # copy: the page array only tracks state, but the copy is what makes
        # the new run live, so the old run must survive until it is done.
        self._commit(first, count_new, prot)
        self._release(old_first, count_old)
        if old_first < self.cursor:
            self.cursor = max(self.alloc_start, old_first)
        return self.base + first * PAGE

    def check(self, addr, length, need_prot):
        if not self._aligned(addr):
            return False
        if addr < self.base:
            return False
        first = self._page_index(addr)
        count = self._num_pages(length)
        if first + count > self.pages:
            return False
        for p in range(first, first + count):
            if not self.mapped(p) or (self.prot(p) & need_prot) != need_prot:
                return False
        return True

    def hash(self):
        return fnv1a64(self.state)

    # ---- invariants ------------------------------------------------------
    def verify(self):
        assert len(self.state) == self.pages
        for st in self.state:
            assert st == FREE or st == RESERVED or (MAPPED <= st <= MAPPED | 0x07), st
            assert not (st & RESERVED and st & MAPPED), st
        # islands must stay reserved
        off = 0
        while off < self.pages * PAGE:
            p = off // PAGE
            for q in range(p, min(self.pages, p + ISLAND_SIZE // PAGE)):
                assert self.state[q] == RESERVED, (q, self.state[q])
            off += ISLAND_STRIDE
        # cursor must point at a page inside the allocatable area
        assert self.alloc_start <= self.cursor <= self.pages


def emit_trace(path, seed, ops, pages):
    rng = random.Random(seed)
    space = Space(pages)
    lines = []
    live = []          # (addr, length) of live mappings

    lines.append(f"# vspace trace seed={seed} pages={pages} page={PAGE:#x}")
    for _ in range(ops):
        pick = rng.random()
        if pick < 0.55 or not live:
            length = rng.choice([1, PAGE, PAGE * 2, PAGE * 4, PAGE * 17]) \
                if rng.random() < 0.3 else rng.choice([PAGE, PAGE * 2, PAGE * 8])
            prot = rng.choice([0, 1, 2, 3, 3, 3, 5, 7])
            fixed = rng.random() < 0.25
            hint = 0
            if fixed and live and rng.random() < 0.6:
                base, blen = rng.choice(live)
                hint = base + rng.choice([0, PAGE]) if rng.random() < 0.5 else base
                hint -= hint % PAGE
            elif fixed:
                hint = space.base + space.alloc_start * PAGE
            flags = MAP_ANON | (MAP_FIXED if fixed else 0)
            result = space.map(hint, length, prot, flags)
            if result > 0:
                live.append((result, length))
            lines.append(f"M {hint:#x} {length:#x} {prot} {flags}")
            lines.append(f"={result:#x} {space.hash():#x}")
        elif pick < 0.80:
            base, blen = rng.choice(live)
            length = rng.choice([blen, PAGE, PAGE * 2])
            if rng.random() < 0.3:
                base += PAGE
            result = space.unmap(base, length)
            live = [m for m in live if not (m[0] >= base and m[0] < base + length)]
            lines.append(f"U {base:#x} {length:#x}")
            lines.append(f"={result:#x} {space.hash():#x}")
        elif pick < 0.93:
            base, blen = rng.choice(live)
            prot = rng.choice([0, 1, 2, 3, 5])
            result = space.protect(base, blen, prot)
            lines.append(f"P {base:#x} {blen:#x} {prot}")
            lines.append(f"={result:#x} {space.hash():#x}")
        else:
            base, blen = rng.choice(live)
            new_len = rng.choice([blen * 2, PAGE * 32, blen])
            result = space.remap(base, blen, new_len, MREMAP_MAYMOVE)
            if result > 0 and result != base:
                live = [m for m in live if m != (base, blen)]
                live.append((result, new_len))
            lines.append(f"R {base:#x} {blen:#x} {new_len:#x} {MREMAP_MAYMOVE}")
            lines.append(f"={result:#x} {space.hash():#x}")
        space.verify()

    with open(path, "w", encoding="ascii") as handle:
        handle.write("\n".join(lines) + "\n")
    return len(lines) // 2


def check(seeds, ops, pages):
    total = 0
    for seed in range(seeds):
        rng = random.Random(seed * 7919 + 13)
        space = Space(pages)
        live = []
        for _ in range(ops):
            pick = rng.random()
            if pick < 0.55 or not live:
                length = rng.choice([PAGE, PAGE * 2, PAGE * 8])
                prot = rng.choice([0, 1, 2, 3, 5, 7])
                result = space.map(0, length, prot, MAP_ANON)
                if result > 0:
                    live.append((result, length))
            elif pick < 0.80:
                base, blen = rng.choice(live)
                space.unmap(base, blen)
                live.remove((base, blen))
            elif pick < 0.93:
                base, blen = rng.choice(live)
                space.protect(base, blen, rng.choice([0, 1, 2, 3, 5]))
            else:
                base, blen = rng.choice(live)
                new_len = blen * 2
                result = space.remap(base, blen, new_len, MREMAP_MAYMOVE)
                if result > 0:
                    live.remove((base, blen))
                    live.append((result, new_len))
            space.verify()
            total += 1
    return total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", default="")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--ops", type=int, default=500)
    parser.add_argument("--pages", type=int, default=0x4000)   # 256 MiB
    parser.add_argument("--check", type=int, default=0)
    args = parser.parse_args()

    if args.check:
        n = check(args.check, args.ops, args.pages)
        print(f"model ok: {args.check} seeds, {n} operations, invariants held")
        return 0
    if args.trace:
        n = emit_trace(args.trace, args.seed, args.ops, args.pages)
        print(f"wrote {args.trace}: {n} operations")
        return 0
    parser.error("nothing to do")
    return 2


if __name__ == "__main__":
    sys.exit(main())
