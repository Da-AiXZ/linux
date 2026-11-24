#!/usr/bin/env python3
"""Compare two syscall traces and report the first line that differs.

The trace format is one syscall per line:

    1234 mmap(0x0 0x4000 0x3 0x22 0xffffffff 0x0) site=0x120014140 -> 0x120020000

Two runs that were given the same inputs -- same image, same frozen clock, same
pinned address space -- should produce the same trace, so the first differing
line is where one of them went a different way.  Everything before it is a
common prefix and therefore not the cause.

Exit status is 0 when the traces match, 1 when they differ, 2 on a file error,
so it can be used as a step in a script.
"""
import argparse
import sys


def load(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return [line.rstrip("\n") for line in handle]


def syscall_name(line):
    parts = line.split(" ", 2)
    if len(parts) < 2:
        return ""
    return parts[1].split("(", 1)[0]


def label(line, fallback):
    """The trace's own counter, so ignored lines do not shift the numbering."""
    head = line.split(" ", 1)[0]
    return head if head.isdigit() else str(fallback)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", help="trace of the run that worked")
    parser.add_argument("suspect", help="trace of the run that failed")
    parser.add_argument("--ignore", default="clock_gettime",
                        help="comma separated syscall names whose lines are "
                             "skipped on both sides (default: clock_gettime)")
    parser.add_argument("--context", type=int, default=8,
                        help="how many common lines to show before the "
                             "divergence (default: 8)")
    parser.add_argument("--max", type=int, default=1,
                        help="how many divergences to report (default: 1)")
    args = parser.parse_args()

    ignore = {name.strip() for name in args.ignore.split(",") if name.strip()}

    try:
        left = [line for line in load(args.reference)
                if syscall_name(line) not in ignore]
        right = [line for line in load(args.suspect)
                 if syscall_name(line) not in ignore]
    except OSError as error:
        print("error: %s" % error, file=sys.stderr)
        return 2

    print("reference: %d calls   suspect: %d calls   (ignored: %s)"
          % (len(left), len(right), ", ".join(sorted(ignore)) or "nothing"))

    reported = 0
    index = 0
    while index < min(len(left), len(right)):
        if left[index] != right[index]:
            reported += 1
            print("\nfirst divergence at call %s"
                  % label(left[index], index))
            start = max(0, index - args.context)
            if index > start:
                print("  common prefix, last %d calls:" % (index - start))
                for line in left[start:index]:
                    print("    %s" % line)
            print("  reference: %s" % left[index])
            print("  suspect  : %s" % right[index])
            if reported >= args.max:
                return 1
        index += 1

    if len(left) != len(right):
        print("\nthe traces agree for %d calls, then one of them stops"
              % min(len(left), len(right)))
        if len(left) > min(len(left), len(right)):
            print("  reference continues: %s" % left[min(len(left), len(right))])
        else:
            print("  suspect continues  : %s" % right[min(len(left), len(right))])
        return 1

    print("\nidentical: %d calls, no divergence" % len(left))
    return 0


if __name__ == "__main__":
    sys.exit(main())
