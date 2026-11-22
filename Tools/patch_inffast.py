#!/usr/bin/env python3
"""Patch zlib's inffast.c to report the window-copy decision.

The device crashes in inflate_fast's three-byte copy loop with the source
pointer NULL, yet the inflate_state is byte-identical at entry for the stream
that works and the stream that dies.  zlib's own rule says the window-copy
branch is only reachable when the distance fits inside `whave`, and `whave > 0`
means the window was allocated -- so at least one of those values must be wrong
at that exact point.  Reading them from outside is impossible; this adds one
printf (via musl's dprintf, so no allocation) right before the check.

It logs the first three occurrences (baseline) plus every occurrence where
`op > whave` or the window pointer is NULL, capped at twelve lines.

Usage: patch_inffast.py <path to inffast.c>
"""

import sys

ANCHOR = "op = dist - op;             /* distance back in window */"

INJECTION = r"""
                    /* zspy: report the values that decide the window copy */
                    {
                        static int zfCount = 0;
                        if (zfCount < 12 &&
                            (zfCount < 3 || op > whave || state->window == 0)) {
                            extern int dprintf(int, const char *, ...);
                            zfCount++;
                            dprintf(2, "[zf] #%d dist=%lu op=%lu whave=%u"
                                    " wsize=%u wnext=%u window=%p sane=%d"
                                    " len=%u begin=%p\n",
                                    zfCount,
                                    (unsigned long)dist,
                                    (unsigned long)op,
                                    (unsigned)whave,
                                    (unsigned)state->wsize,
                                    (unsigned)state->wnext,
                                    (void *)state->window,
                                    (int)state->sane,
                                    (unsigned)len,
                                    (void *)beg);
                        }
                    }
"""


def main(argv):
    if len(argv) != 2:
        print("usage: patch_inffast.py <inffast.c>", file=sys.stderr)
        return 2
    path = argv[1]
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if "[zf]" in text:
        print("already patched")
        return 0
    if text.count(ANCHOR) != 1:
        print(f"anchor found {text.count(ANCHOR)} times, refusing to patch")
        return 1
    text = text.replace(ANCHOR, ANCHOR + "\n" + INJECTION, 1)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("inffast.c patched")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
