#!/usr/bin/env python3
"""Patch zlib's inffast.c to report a length code below 3.

inflate_fast does:

    len = (unsigned)(here->val);
    ...
    do {
        *out++ = *from++; *out++ = *from++; *out++ = *from++;
        len -= 3;
    } while (len > 2);

The loop is do/while, so it always stores three bytes before testing.  zlib
assumes here->val >= 3 (the smallest length base is 3); a zero or corrupt
value makes len wrap to 0xFFFFFFFD on the first subtraction and the loop never
ends, walking out++ through everything up to the next unmapped page.  Device
runs show exactly that: len = 0xffffffff and out on our guard page.

This prints the decoded code (op/bits/val) plus out/end whenever val < 3, so
the next run says whether the code table itself is corrupt or the index into
it is.

Usage: patch_inffast_len.py <path to inffast.c>
"""

import sys

ANCHOR = "            len = (unsigned)(here->val);"

INJECTION = r"""
            {
                /* zspy: a length base below 3 makes the do/while loop wrap */
                static int zf3Count = 0;
                if (len < 3 && zf3Count < 8) {
                    extern int dprintf(int, const char *, ...);
                    zf3Count++;
                    dprintf(2, "[zf3] #%d val=%u op=%u bits=%u len=%u"
                            " out=%p end=%p last=%p in=%p\n",
                            zf3Count,
                            (unsigned)here->val,
                            (unsigned)here->op,
                            (unsigned)here->bits,
                            (unsigned)len,
                            (void *)out,
                            (void *)end,
                            (const void *)last,
                            (const void *)in);
                }
            }"""


def main(argv):
    if len(argv) != 2:
        print("usage: patch_inffast_len.py <inffast.c>", file=sys.stderr)
        return 2
    path = argv[1]
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if "[zf3]" in text:
        print("already patched")
        return 0
    if text.count(ANCHOR) != 1:
        print(f"anchor found {text.count(ANCHOR)} times, refusing to patch")
        return 1
    text = text.replace(ANCHOR, ANCHOR + INJECTION, 1)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("inffast.c length probe patched")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
