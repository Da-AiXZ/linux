#!/usr/bin/env python3
"""Merge the device logs into one chronological document, split by time gaps.

Each run gets a summary block (build, command, verdict, marker counts) and the
verbatim lines that matter for the memory investigation.  Runs that failed, or
that produced [zm]/[zck]/[zfix]/[ovl]/signal evidence, are reproduced in full;
clean passes keep only their diagnostic lines, because their value is the count,
not the text.

    python Tools/merge_logs.py --out dist/logs-merged/probe-by-time.md
"""

import argparse
import datetime
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGS = os.path.join(ROOT, ".remote", "logs")

TIMESTAMP = re.compile(r"(\d{8})-(\d{6})")

MARKERS = (
    "[zspy]", "[zout]", "[zck]", "[zfix]", "[zm]", "[zc]", "[zc4]", "[zu]",
    "[ovl]", "OK:", "IO ERROR", "WARNING", "ERROR:", "installing",
    "Installing", "signal", "status=", "guest exited", "read fd=",
    "read guard", "mmap hist", "canary", "ensure-writable",
)

INTERESTING = ("[zm]", "[zmd]", "[zck]", "[ovl]", "signal", "canary")

# What the memory investigation actually reads: the verdict, the CRC pair, the
# write detector and the crash line.  [zu]/[zc]/[zspy] are per-call chatter and
# would drown the document.
COMPACT_MARKERS = (
    "[zm]", "[zmd]", "[zck]", "[ovl]", "[zout]", "incorrect data check",
    "signal", "OK:", "IO ERROR", "WARNING", "ERROR:", "Installing",
    "guest exited", "status=", "canary", "read verify",
)


def parse(path):
    name = os.path.basename(path)
    match = TIMESTAMP.search(name)
    when = datetime.datetime.strptime(name[:15], "%Y%m%d-%H%M%S") if match else None
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    lines = text.splitlines()
    build = ""
    command = ""
    for line in lines[:5]:
        found = re.search(r"build ([\d.]+) \((\d+)\)", line)
        if found:
            build = "%s (%s)" % (found.group(1), found.group(2))
        found = re.search(r"remote command: (\S+)", line)
        if found:
            command = found.group(1)
    fails = [l for l in lines if "incorrect data check" in l]
    ok = any("OK:" in l for l in lines)
    interesting = any(marker in text for marker in INTERESTING) or "signal" in text
    status = ""
    for line in reversed(lines):
        found = re.search(r"guest exited: (.*)", line)
        if found:
            status = found.group(1).strip()
            break
    keys = [l for l in lines if any(marker in l for marker in MARKERS)]
    brief = [l for l in lines if any(marker in l for marker in COMPACT_MARKERS)]
    if fails:
        verdict = "FAIL"
    elif status not in ("", "status=0"):
        verdict = "CRASH"
    elif ok:
        verdict = "OK"
    else:
        verdict = "UNKNOWN"
    return {
        "path": path,
        "verdict": verdict,
        "name": name,
        "when": when,
        "build": build,
        "command": command,
        "lines": lines,
        "keys": keys,
        "brief": brief,
        "fails": fails,
        "ok": ok and not fails,
        "failed": bool(fails),
        "interesting": interesting,
        "status": status,
        "zm": sum(1 for l in lines if "[zm]" in l),
        "zck": sum(1 for l in lines if "[zck]" in l),
        "zfix": sum(1 for l in lines if "[zfix]" in l),
        "ovl": sum(1 for l in lines if "[ovl]" in l),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=os.path.join(ROOT, "dist", "logs-merged", "probe-by-time.md"))
    parser.add_argument("--gap", type=int, default=1800, help="seconds that start a new segment")
    parser.add_argument("--pattern", default="20261123-*.log")
    parser.add_argument("--compact", action="store_true",
                        help="only diagnostic lines for every run, no full text")
    args = parser.parse_args()

    runs = [parse(p) for p in sorted(glob.glob(os.path.join(LOGS, args.pattern)))]
    runs = [r for r in runs if r["when"] is not None]
    if not runs:
        print("no logs matched")
        return 1

    segments = []
    for run in runs:
        if not segments or (run["when"] - segments[-1][-1]["when"]).total_seconds() > args.gap:
            segments.append([run])
        else:
            segments[-1].append(run)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    out = []
    out.append("# LinuxProbe 真机日志合并（按时间段）\n")
    out.append("来源：`%s`　文件数：%d　时间跨度：%s → %s\n" % (
        os.path.relpath(LOGS, ROOT).replace("\\", "/"),
        len(runs),
        runs[0]["when"].strftime("%m-%d %H:%M:%S"),
        runs[-1]["when"].strftime("%m-%d %H:%M:%S")))
    if args.compact:
        out.append("规则：每轮只保留判读行（`[zm]/[zck]/[zfix]/[ovl]/[zout]`、"
                   "校验结果、崩溃行、`OK:`/`WARNING`、退出码），逐轮按时间排列。\n")
    else:
        out.append("规则：失败轮或带 `[zm]/[zck]/[zfix]/[ovl]/signal` 的轮次保留全文；"
                   "干净通过的轮次只保留诊断行。\n")

    out.append("\n## 总览\n")
    out.append("| # | 时间 | 构建 | 命令 | 结果 | 状态 | zm | zck | zfix | ovl | 文件 |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for index, run in enumerate(runs, 1):
        verdict = run["verdict"]
        out.append("| %d | %s | %s | %s | %s | %s | %d | %d | %d | %d | `%s` |" % (
            index,
            run["when"].strftime("%H:%M:%S"),
            run["build"],
            run["command"],
            verdict,
            run["status"],
            run["zm"], run["zck"], run["zfix"], run["ovl"],
            run["name"]))

    totals = {
        "runs": len(runs),
        "fail": sum(1 for r in runs if r["failed"]),
        "ok": sum(1 for r in runs if r["ok"]),
        "zm": sum(r["zm"] for r in runs),
        "zck": sum(r["zck"] for r in runs),
        "ovl": sum(r["ovl"] for r in runs),
    }
    out.append("\n合计：%d 轮，失败 %d，通过 %d，`[zm]` %d 行，`[zck]` %d 行，`[ovl]` %d 行。\n" % (
        totals["runs"], totals["fail"], totals["ok"], totals["zm"], totals["zck"], totals["ovl"]))

    for number, segment in enumerate(segments, 1):
        out.append("\n---\n")
        out.append("## 时间段 %d：%s – %s（%d 轮）\n" % (
            number,
            segment[0]["when"].strftime("%H:%M:%S"),
            segment[-1]["when"].strftime("%H:%M:%S"),
            len(segment)))
        builds = sorted({run["build"] for run in segment})
        out.append("构建：%s\n" % "、".join(b for b in builds if b))
        for run in segment:
            verdict = run["verdict"]
            full = (run["verdict"] in ("FAIL", "CRASH") or run["interesting"]) \
                and not args.compact
            out.append("\n### %s · %s · %s · %s%s\n" % (
                run["when"].strftime("%H:%M:%S"), run["build"], run["command"], verdict,
                "" if full else "（仅诊断行）"))
            if run["fails"]:
                for line in run["fails"]:
                    out.append("> " + line.split("] ", 1)[-1])
                out.append("")
            if full:
                body = run["lines"]
            else:
                body = run["brief"] if args.compact else run["keys"]
            out.append("```text")
            out.extend(body)
            out.append("```")

    with open(args.out, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(out) + "\n")

    print("wrote %s (%d runs, %d bytes)" % (
        args.out, len(runs), os.path.getsize(args.out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
