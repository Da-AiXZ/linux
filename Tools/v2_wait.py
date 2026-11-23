#!/usr/bin/env python3
"""
Block until the device uploads a new log, then exit.

Run it as a background job; when it exits with status 0 the harness reports
completion, which is what wakes the assistant up.  It deliberately records
the inbox size at start, so a log that was already there does not satisfy it.

    python Tools/v2_wait.py --timeout 3600

Exit codes: 0 = a new log arrived (its inbox line is printed), 1 = timeout.
"""

import argparse
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INBOX = os.path.join(ROOT, ".remote", "v2", "inbox.txt")


def size_now():
    try:
        return os.path.getsize(INBOX), os.path.getmtime(INBOX)
    except OSError:
        return 0, 0.0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args()

    start_size, start_mtime = size_now()
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        size, mtime = size_now()
        if size > start_size or (size > 0 and mtime > start_mtime):
            time.sleep(0.3)
            with open(INBOX, "r", encoding="utf-8") as handle:
                lines = [line.strip() for line in handle if line.strip()]
            if lines:
                print(lines[-1])
            return 0
        time.sleep(args.interval)
    print("no new log within the timeout")
    return 1


if __name__ == "__main__":
    sys.exit(main())
