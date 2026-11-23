#!/usr/bin/env python3
"""Wait for the 0.41.0 A/B self test to finish, then print the verdict.

This is the "wake me up" service.  It watches .remote/logs for uploads from
the device, tracks the two shards (stock zlib, instrumented zlib), and exits
as soon as both report ##### SELF-TEST DONE.  Its exit is the signal that the
workstation side has something to analyse.

    python3 Tools/watch_experiment.py --build 0.41.0 --expect 2

Exit codes:
    0  both shards finished (verdict written)
    2  timeout, nothing conclusive (partial verdict written)
    3  no log arrived at all (device never reached the server)

The verdict file is .remote/verdict.txt; it always ends with a one-line
summary so it can be read without the console.
"""

import argparse
import datetime
import glob
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(ROOT, ".remote")
LOGS = os.path.join(STATE, "logs")
VERDICT = os.path.join(STATE, "verdict.txt")

LINE_RUN = re.compile(r"##### RUN (\d+)/(\d+) status=(-?\d+) (\S+)")
LINE_DONE = re.compile(
    r"##### SELF-TEST DONE total=(\d+) failed=(\d+) failed_runs=(\S+) libz=(\S+)")
LINE_BUILD = re.compile(r"=====\s*build\s+(\S+)\s*\((\S+)\)")
LINE_LIBZ = re.compile(r"\[guest\] libz selected=(\S+)")
LINE_LABEL = re.compile(r"##### RUN \d+/\d+ libz=(\S+)")


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def summarise(path):
    text = read(path)
    build = LINE_BUILD.search(text)
    if build is None:
        return None
    info = {
        "path": path,
        "build": build.group(1),
        "runs": LINE_RUN.findall(text),
        "done": None,
        "libz": None,
    }
    done = LINE_DONE.search(text)
    if done is not None:
        info["done"] = {
            "total": int(done.group(1)),
            "failed": int(done.group(2)),
            "failed_runs": done.group(3),
            "libz": done.group(4),
        }
    selected = LINE_LIBZ.search(text)
    if selected is not None:
        info["libz"] = selected.group(1)
    label = LINE_LABEL.search(text)
    if info["libz"] is None and label is not None:
        info["libz"] = label.group(1)
    return info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", default="0.41.0")
    parser.add_argument("--expect", type=int, default=2,
                        help="how many SELF-TEST DONE shards to wait for")
    parser.add_argument("--timeout", type=int, default=45 * 60)
    parser.add_argument("--quiet-every", type=int, default=60)
    parser.add_argument("--until", action="append", default=[],
                        help="exit as soon as a new log contains this text")
    parser.add_argument("--max-logs", type=int, default=0,
                        help="also exit after this many matching logs")
    parser.add_argument("--logs", default=LOGS, help="override the log directory")
    parser.add_argument("--verdict", default=VERDICT,
                        help="override the verdict file")
    options = parser.parse_args()

    log_dir = options.logs
    verdict_path = options.verdict
    if not os.path.isdir(log_dir):
        print("[watch] no %s yet" % log_dir)
        return 3

    seen = set(glob.glob(os.path.join(log_dir, "*.log")))
    start = time.time()
    deadline = start + options.timeout
    shards = {}
    runs_seen = 0
    last_note = 0.0
    matched = []
    considered = 0
    hit = None

    print("[watch] build=%s expect=%d logs=%d waiting for the device..."
          % (options.build, options.expect, len(seen)))
    sys.stdout.flush()

    while time.time() < deadline:
        fresh = [path for path in glob.glob(os.path.join(log_dir, "*.log"))
                 if path not in seen]
        for path in sorted(fresh, key=os.path.getmtime):
            # The server writes the file and closes it; give it a moment so a
            # half-written upload is not parsed as a broken run.
            if time.time() - os.path.getmtime(path) < 1.0:
                continue
            seen.add(path)
            info = summarise(path)
            if info is None or options.build not in info["build"]:
                continue
            considered += 1
            text = read(path)
            for pattern in options.until:
                if pattern in text:
                    hit = (pattern, path, text)
                    print("[watch] PATTERN %r in %s" %
                          (pattern, os.path.basename(path)))
                    break
            if hit is not None:
                break
            if info["runs"]:
                runs_seen += 1
                tag = info["libz"] or "?"
                print("[watch] %s run %s/%s %s" %
                      (tag, info["runs"][0][0], info["runs"][0][1],
                       info["runs"][0][3]))
            if info["done"] is not None:
                done = info["done"]
                tag = done["libz"]
                shards[tag] = done
                print("[watch] DONE libz=%s total=%d failed=%d (%s)" %
                      (tag, done["total"], done["failed"],
                       done["failed_runs"]))
            sys.stdout.flush()

        if hit is not None:
            break
        if options.max_logs and considered >= options.max_logs:
            print("[watch] reached --max-logs %d" % options.max_logs)
            break
        if len(shards) >= options.expect:
            break
        if time.time() - last_note > options.quiet_every:
            last_note = time.time()
            print("[watch] %ds elapsed, runs=%d shards=%d" %
                  (int(time.time() - start), runs_seen, len(shards)))
            sys.stdout.flush()
        time.sleep(2)

    lines = []
    if options.until:
        lines.append("===== watch result (build %s) =====" % options.build)
        lines.append("logs considered: %d" % considered)
        if hit is not None:
            lines.append("matched: %s (%s)" % (hit[0], os.path.basename(hit[1])))
            for line in hit[2].splitlines():
                if "[dbg]" in line:
                    lines.append("  " + line.strip())
        else:
            lines.append("matched: none")
        lines.append("SUMMARY matched=%s logs=%d" %
                     (hit[0] if hit is not None else "none", considered))
        with open(verdict_path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
        print()
        print("\n".join(lines))
        return 0 if hit is not None else 2

    lines.append("===== 0.41.0 A/B verdict =====")
    lines.append("generated %s" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    if not shards:
        lines.append("no SELF-TEST DONE line arrived in %d seconds"
                     % options.timeout)
        lines.append("runs seen: %d" % runs_seen)
        lines.append("SUMMARY no-data")
        with open(verdict_path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
        print("\n".join(lines))
        return 2 if runs_seen else 3

    for tag in sorted(shards):
        done = shards[tag]
        lines.append("libz=%-6s total=%d failed=%d failed_runs=%s" %
                     (tag, done["total"], done["failed"], done["failed_runs"]))
    stock = shards.get("stock")
    spy = shards.get("zspy")
    if stock is not None and spy is not None:
        if stock["failed"] == 0 and spy["failed"] == 0:
            verdict = "no-failure"
            note = ("neither batch failed -- rerun x20 before believing it")
        elif stock["failed"] == 0 < spy["failed"]:
            verdict = "instrument-is-the-writer"
            note = ("stock is clean, zspy fails: the probe path (write/read "
                    "handlers or the 132KB shadow memcpy) is the writer")
        elif stock["failed"] > 0 and spy["failed"] > 0:
            verdict = "runtime-is-the-writer"
            note = ("both fail: unrelated to the probe -- use the watchpoint "
                    "run to get the writer's pc")
        else:
            verdict = "stock-worse"
            note = "stock fails more than zspy -- inspect the logs by hand"
    else:
        verdict = "incomplete"
        note = "only %d of %d shards reported" % (len(shards), options.expect)
    lines.append("verdict=%s" % verdict)
    lines.append("note=%s" % note)

    # Per-stream detail from the logs of this build.
    paths = [path for path in glob.glob(os.path.join(log_dir, "*.log"))
             if path in seen]
    if paths:
        try:
            output = subprocess.run(
                [sys.executable, os.path.join(ROOT, "Tools", "analyze_zck.py"),
                 "--build", options.build] + paths,
                capture_output=True, text=True, timeout=600).stdout
            lines.append("")
            lines.append(output.strip())
        except (OSError, subprocess.SubprocessError) as error:
            lines.append("analyzer failed: %s" % error)

    lines.append("SUMMARY runs=%d shards=%d verdict=%s" %
                 (runs_seen, len(shards), verdict))
    with open(verdict_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    print()
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
