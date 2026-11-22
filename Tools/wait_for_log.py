#!/usr/bin/env python3
"""Block until the device uploads a new log, then exit.

Started as a background job by the workstation side of the loop.  When it
exits with status 0 the harness reports completion, which is what wakes the
assistant up instead of the user having to say "look again".

    python Tools/wait_for_log.py --timeout 3600

Exit codes: 0 = a log arrived (inbox content printed), 1 = timed out.
"""

import argparse
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INBOX = os.path.join(ROOT, ".remote", "inbox.txt")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--interval", type=float, default=2.0)
    args = parser.parse_args()

    deadline = time.time() + args.timeout
    while time.time() < deadline:
        try:
            if os.path.exists(INBOX) and os.path.getsize(INBOX) > 0:
                with open(INBOX, "r", encoding="utf-8") as handle:
                    print(handle.read().strip())
                return 0
        except OSError:
            pass
        time.sleep(args.interval)
    print("no new log within the timeout")
    return 1


if __name__ == "__main__":
    sys.exit(main())
