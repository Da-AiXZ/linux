#!/usr/bin/env python3
"""Patch zlib's inflate.c to report every updatewindow() call.

0.40.18 finally named the failure: `incorrect data check`.  The input bytes are
bit-identical to the CDN, the state fields are sane, so the bytes inflated were
wrong -- which means the sliding window held something other than what zlib
last wrote there.

updatewindow() is the only writer, and its copy length comes from
`out - strm->avail_out`.  A damaged avail_out makes that copy longer than the
output actually produced, and the window is filled from whatever lies before
next_out.  Print copy/wsize/wnext/window plus avail_out on the first calls and
on any copy larger than the window, so the next run says whether zlib itself
over-copies or the window was overwritten from outside.

Usage: patch_updatewindow.py <path to inflate.c>
"""

import sys

ANCHOR = """local int updatewindow(z_streamp strm, const Bytef *end, unsigned copy) {
    struct inflate_state FAR *state;
    unsigned dist;

    state = (struct inflate_state FAR *)strm->state;
"""

INJECTION = r"""
    {
        /* zspy: name the copy that fills the sliding window */
        static int zuCount = 0;
        if (zuCount < 4 || copy > 32768U) {
            extern int dprintf(int, const char *, ...);
            zuCount++;
            dprintf(2, "[zu] #%d copy=%u wsize=%u whave=%u wnext=%u"
                    " window=%p end=%p avail_out=%u\n",
                    zuCount,
                    (unsigned)copy,
                    (unsigned)state->wsize,
                    (unsigned)state->whave,
                    (unsigned)state->wnext,
                    (void *)state->window,
                    (const void *)end,
                    (unsigned)strm->avail_out);
        }
    }
"""


def main(argv):
    if len(argv) != 2:
        print("usage: patch_updatewindow.py <inflate.c>", file=sys.stderr)
        return 2
    path = argv[1]
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if "[zu]" in text:
        print("already patched")
        return 0
    if text.count(ANCHOR) != 1:
        print(f"anchor found {text.count(ANCHOR)} times, refusing to patch")
        return 1
    text = text.replace(ANCHOR, ANCHOR + INJECTION, 1)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("updatewindow patched")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
