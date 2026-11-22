#!/usr/bin/env python3
"""Patch zlib's inflate.c to report left/avail_out at the literal write.

0.40.15 showed the crash is not in inflate_fast: it is the literal path
(`*put++ = state->length`) with put already on our guard page.  zlib gates
that write on `left == 0`, where left is strm->avail_out, so a negative
avail_out makes the check useless.  Print left, have, put and the literal at
the first few literals, and again the moment left goes negative, so the log
names the step that turned it.

Usage: patch_inflate.py <path to inflate.c>
"""

import sys

ANCHOR = """        case LIT:
            if (left == 0) goto inf_leave;"""

INJECTION = r"""
            {
                /* zspy: what the literal path thinks is left to write */
                static int zlSeen = 0;
                int zlNegative = ((unsigned)left > 0x80000000u);
                if (zlSeen < 6 || (zlNegative && zlSeen < 24)) {
                    extern int dprintf(int, const char *, ...);
                    zlSeen++;
                    dprintf(2, "[zl] #%d left=%u have=%u put=%p len=%u"
                            " mode=%u avail_out=%u avail_in=%u\n",
                            zlSeen,
                            (unsigned)left,
                            (unsigned)have,
                            (void *)put,
                            (unsigned)state->length,
                            (unsigned)state->mode,
                            (unsigned)strm->avail_out,
                            (unsigned)strm->avail_in);
                }
            }"""


def main(argv):
    if len(argv) != 2:
        print("usage: patch_inflate.py <inflate.c>", file=sys.stderr)
        return 2
    path = argv[1]
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if "[zl]" in text:
        print("already patched")
        return 0
    if text.count(ANCHOR) != 1:
        print(f"anchor found {text.count(ANCHOR)} times, refusing to patch")
        return 1
    text = text.replace(ANCHOR, ANCHOR + INJECTION, 1)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("inflate.c patched")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
