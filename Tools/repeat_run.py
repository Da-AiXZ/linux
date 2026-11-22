#!/usr/bin/env python3
"""Run the same device command N times and collect every log.

The index failure is probabilistic: the same build parses both repositories in
one run and reports "incorrect data check" in another.  One run therefore says
nothing.  This driver queues the command, waits for the upload, queues it
again, and repeats, so a batch of runs can be compared afterwards -- in
particular a failing run that carries [zout] outcrc/trailer.

    python Tools/repeat_run.py --command apkUpdateLocal --build 122 --times 6
"""

import argparse
import json
import os
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INBOX = os.path.join(ROOT, ".remote", "inbox.txt")
LOGS = os.path.join(ROOT, ".remote", "logs")


def post_command(command):
    request = urllib.request.Request(
        "http://127.0.0.1:8765/command",
        data=command.encode(),
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.read().decode().strip()


def inbox_state():
    if not os.path.exists(INBOX):
        return 0, 0.0
    return os.path.getsize(INBOX), os.path.getmtime(INBOX)


def wait_for_upload(size_before, mtime_before, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        size, mtime = inbox_state()
        if size > size_before or (mtime > mtime_before and size > 0):
            time.sleep(0.4)
            with open(INBOX, "r", encoding="utf-8") as handle:
                lines = [line for line in handle.read().splitlines() if line]
            return lines[-1] if lines else ""
        time.sleep(2.0)
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", default="apkUpdateLocal")
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--times", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    queued = "%s@%d" % (args.command, args.build)
    results = []
    for index in range(args.times):
        size_before, mtime_before = inbox_state()
        status = post_command(queued)
        line = wait_for_upload(size_before, mtime_before, args.timeout)
        entry = {"run": index + 1, "queued": status, "inbox": line}
        if line:
            path = line.split("|")[0]
            entry["log"] = os.path.basename(path)
            entry["exists"] = os.path.exists(path)
        results.append(entry)
        print(json.dumps(entry, ensure_ascii=False), flush=True)
        if not line:
            print("no upload within %ds, stopping" % args.timeout, flush=True)
            break
    print(json.dumps({"runs": len(results)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
