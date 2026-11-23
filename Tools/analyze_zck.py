#!/usr/bin/env python3
"""Turn a Linux Probe run log into a verdict about the inflate failure.

Why this exists
---------------
0.40.32-0.40.38 logs carry three numbers per inflate() call:

    [zck] call=N check=XXXXXXXX ... outcrc=YYYYYYYY total_out=T

  check   -- zlib's own running CRC (inflate_state + 0x20)
  outcrc  -- the wrapper's independent CRC of everything written so far
  total_out -- bytes produced so far

Two different CRC32 implementations over the same bytes must agree.  When they
do not, one of them is wrong, and which one tells us what happened:

  * outcrc == crc32(true prefix) and check != it
        -> the output is perfect, only zlib's accumulator is wrong.
           A single stray store hit state->check.  This script recovers the
           value that was written (the "seed") by inverting CRC32.
  * outcrc != crc32(true prefix)
        -> the decoded bytes themselves differ: a different bug class
           (bad code table, runaway copy, short stream).
  * neither, but the chain check_i -> check_j does not hold
        -> check was replaced more than once (or the output changed mid-run).

Usage
-----
    python3 Tools/analyze_zck.py dist/logs/20261123-*.log
    python3 Tools/analyze_zck.py --dir .remote/logs
    python3 Tools/analyze_zck.py --self-test        # validate the inverter

The decompressed reference comes from dist/main.idx and dist/community.idx
(two-member gzip: 1KB signature, then the index).  If dist/*.raw is missing it
is rebuilt on the fly.
"""

import argparse
import glob
import os
import re
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DIST = os.path.join(ROOT, "dist")

# ---------------------------------------------------------------- CRC32 tools

_TABLE = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ 0xEDB88320 if _c & 1 else _c >> 1
    _TABLE.append(_c)


def _step_back(internal_new, byte):
    """Undo one reflected-CRC32 byte step.  Returns the previous state."""
    for index in range(256):
        high = internal_new ^ _TABLE[index]
        if high < (1 << 24):
            return ((high << 8) | (index ^ byte)) & 0xFFFFFFFF
    return None


def crc_seed(result, data):
    """Value S such that zlib.crc32(data, S) == result, or None."""
    internal = (~result) & 0xFFFFFFFF
    for byte in reversed(data):
        internal = _step_back(internal, byte)
        if internal is None:
            return None
    return (~internal) & 0xFFFFFFFF


def self_test():
    samples = [b"", b"a", b"hello world", bytes(range(256)) * 3]
    for data in samples:
        for seed in (0, 1, 0x12345678, 0xFFFFFFFF):
            value = zlib.crc32(data, seed) & 0xFFFFFFFF
            back = crc_seed(value, data)
            if back != seed:
                print("FAIL seed=%08x len=%d got=%s" % (seed, len(data), back))
                return 1
    print("crc_seed self-test ok")
    return 0


# --------------------------------------------------------------- reference data

_REFERENCE = {}


def _members(path):
    """All gzip members of an .idx file, decompressed, in order."""
    compressed = open(path, "rb").read()
    members = []
    rest = compressed
    while rest:
        engine = zlib.decompressobj(47)
        part = engine.decompress(rest)
        part += engine.flush()
        if not part:
            break
        members.append(part)
        rest = engine.unused_data
    return members


def reference(name):
    """The index member of dist/<name>.idx.

    apk re-inits the z_stream at every gzip member, so `total_out` counts
    inside one member.  The first member is the 1KB RSA signature and the
    second one is the index, so the reference for `total_out` is the LAST
    member -- not the concatenation (that mistake shifts every prefix by
    1024 bytes and makes every comparison look clean).
    """
    if name in _REFERENCE:
        return _REFERENCE[name]
    idx_path = os.path.join(DIST, name + ".idx")
    raw_path = os.path.join(DIST, name + ".member2")
    if os.path.exists(raw_path):
        data = open(raw_path, "rb").read()
    elif os.path.exists(idx_path):
        try:
            data = _members(idx_path)[-1]
        except (zlib.error, OSError):
            data = None
        if data is not None:
            try:
                with open(raw_path, "wb") as handle:
                    handle.write(data)
            except OSError:
                pass
    else:
        data = None
    _REFERENCE[name] = data
    return data


# ----------------------------------------------------------------- log parsing

LINE_BUILD = re.compile(r"=====\s*build\s+(\S+)\s*\((\S+)\)")
LINE_LIBZ = re.compile(r"\[guest\]\s+libz\s+selected=(\S+)\s+size=(\d+)")
LINE_RUN = re.compile(r"#####\s*RUN\s+(\d+)/(\d+)\s+status=(-?\d+)\s*(\S*)")
LINE_INIT2 = re.compile(r"\[zspy\]\s+init2\s+.*state=(0x[0-9a-fA-F]+)")
LINE_GAP = re.compile(r"\[zgap\]")


def fields(line):
    """key=value tokens of one log line, tolerant of extra fields.

    The [zck] format grew over time (this_out/state_total/out/out_start were
    added after total_out), so matching a fixed word order silently drops
    every line on newer builds.
    """
    found = {}
    for token in line.split():
        if "=" not in token:
            continue
        key, _, value = token.partition("=")
        if key and key not in found:
            found[key] = value
    return found


class Stream(object):
    """One inflateInit2 .. inflateEnd/ fail sequence."""

    def __init__(self, state):
        self.state = state
        self.calls = []      # (call, check, outcrc, total_out)
        self.end_crc = None  # outcrc printed by [zout] at stream end
        self.end_out = None
        self.fail = None     # (ret, total_out, message)
        self.gaps = 0

    @property
    def last(self):
        return self.calls[-1] if self.calls else None


def parse(path):
    """Returns (build, libz, runs, streams) for one log file."""
    build = "?"
    libz = None
    runs = []
    streams = []
    current = None
    for line in open(path, "r", encoding="utf-8", errors="replace"):
        if not line:
            continue
        match = LINE_BUILD.search(line)
        if match:
            build = "%s(%s)" % (match.group(1), match.group(2))
        match = LINE_LIBZ.search(line)
        if match:
            libz = "%s size=%s" % (match.group(1), match.group(2))
        match = LINE_RUN.search(line)
        if match:
            runs.append((int(match.group(1)), int(match.group(2)),
                         int(match.group(3)), match.group(4)))
        if "[zspy] init2" in line:
            current = Stream(LINE_INIT2.search(line).group(1)
                             if LINE_INIT2.search(line) else "?")
            streams.append(current)
        if current is None:
            continue
        if "[zck]" in line:
            values = fields(line)
            if {"call", "check", "outcrc", "total_out"} <= set(values):
                current.calls.append((int(values["call"]),
                                      int(values["check"], 16),
                                      int(values["outcrc"], 16),
                                      int(values["total_out"])))
                continue
        if "[zout]" in line:
            values = fields(line)
            if "outcrc" in values and "total_out" in values:
                current.end_crc = int(values["outcrc"], 16)
                current.end_out = int(values["total_out"])
                continue
        if "[zspy] fail" in line:
            values = fields(line)
            message = ""
            if "msg=" in line:
                message = line.split("msg=", 1)[1].strip()
            try:
                current.fail = (int(values.get("ret", "0")),
                                int(values.get("total_out", "0")),
                                message)
            except ValueError:
                current.fail = (0, 0, message)
            continue
        if LINE_GAP.search(line):
            current.gaps += 1
    return build, libz, runs, streams


def identify(stream):
    """main / community / None, using the 1KB signature member's CRC."""
    if stream.end_crc is not None and stream.end_out == 1024:
        if stream.end_crc == 0x42564AED:
            return "main"
        if stream.end_crc == 0x25BC3B16:
            return "community"
    last = stream.last
    if last is None:
        return None
    for name in ("main", "community"):
        data = reference(name)
        if data is not None and last[3] <= len(data):
            if zlib.crc32(data[:last[3]]) & 0xFFFFFFFF == last[2]:
                return name
    return None


def analyse_stream(stream):
    """Returns a dict describing what happened in one stream."""
    result = {
        "state": stream.state,
        "index": identify(stream),
        "calls": len(stream.calls),
        "verdict": "EMPTY",
        "seed": None,
        "mismatch_at": None,
        "detail": "",
        "fail": stream.fail[2] if stream.fail else "",
        "out": stream.fail[1] if stream.fail else stream.end_out,
    }
    if not stream.calls:
        return result
    # The first gzip member is the 1KB RSA signature, not index data.
    if stream.end_out == 1024 and stream.end_crc in (0x42564AED, 0x25BC3B16):
        result["verdict"] = "SIGNATURE"
        result["detail"] = "1KB signature member"
        return result
    name = result["index"]
    if name is None:
        result["verdict"] = "UNKNOWN"
        result["detail"] = "no reference data for this stream"
        return result

    data = reference(name)
    last = stream.calls[-1]
    if last[3] > len(data):
        result["verdict"] = "UNKNOWN"
        result["detail"] = "total_out beyond reference"
        return result
    last_truth = zlib.crc32(data[:last[3]]) & 0xFFFFFFFF
    result["last_outcrc_ok"] = (last[2] == last_truth)

    first_bad = None
    for index, call in enumerate(stream.calls):
        if call[2] != call[1]:
            first_bad = index
            break
    result["mismatch_at"] = (stream.calls[first_bad][0]
                             if first_bad is not None else None)

    if not result["last_outcrc_ok"]:
        result["verdict"] = "DECODE"
        result["detail"] = ("outcrc != crc32(reference) at the last call: "
                            "the decoded bytes themselves are wrong")
        return result
    if first_bad is None:
        result["verdict"] = "CLEAN"
        return result

    # Does check behave like one CRC chain over the true output?  If yes, the
    # accumulator was replaced ONCE and then kept running normally -- that is
    # the "stray store" signature.  A break means the value changed again.
    breaks = 0
    for index in range(1, len(stream.calls)):
        previous = stream.calls[index - 1]
        current = stream.calls[index]
        if current[3] <= previous[3]:
            continue
        segment = data[previous[3]:current[3]]
        if (zlib.crc32(segment, previous[1]) & 0xFFFFFFFF) != current[1]:
            breaks += 1
    result["chain_breaks"] = breaks

    # Walk back to the last call whose check matched its own outcrc: that value
    # is a correct CRC, so it is the seed zlib used for the next update.
    base = None
    for index in range(first_bad - 1, -1, -1):
        if stream.calls[index][2] == stream.calls[index][1]:
            base = index
            break
    if base is None:
        if breaks == 0:
            result["verdict"] = "SEED_EARLY"
            result["detail"] = ("output perfect and the CRC chain is intact, "
                                "but check was already wrong at the first "
                                "logged call (call %d); this log does not "
                                "include the call where it changed" %
                                stream.calls[0][0])
        else:
            result["verdict"] = "CHAIN"
            result["detail"] = ("output perfect but the CRC chain breaks %d "
                                "time(s): check was replaced more than once"
                                % breaks)
        return result

    start = stream.calls[base][3]
    end = stream.calls[first_bad][3]
    if end <= start:
        result["verdict"] = "DECODE"
        result["detail"] = "no output between the last good and first bad call"
        return result
    segment = data[start:end]
    expected = stream.calls[first_bad][1]
    seed = crc_seed(expected, segment)
    result["seed"] = seed
    result["seed_from"] = start
    result["seed_to"] = end
    if seed is not None and (zlib.crc32(segment, seed) & 0xFFFFFFFF) == expected:
        result["verdict"] = "SEED"
        result["detail"] = ("output perfect; check seeded with 0x%08x "
                            "instead of 0x%08x" %
                            (seed, stream.calls[base][1]))
    else:
        result["verdict"] = "DECODE"
        result["detail"] = "check is not a CRC of the true output segment"
    return result


def describe(path):
    build, libz, runs, streams = parse(path)
    reports = [analyse_stream(stream) for stream in streams]
    return {
        "path": path,
        "build": build,
        "libz": libz,
        "runs": runs,
        "streams": reports,
    }


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="*", help="log files")
    parser.add_argument("--dir", help="directory of *.log files")
    parser.add_argument("--build", help="only logs whose build header contains "
                                       "this string, e.g. 0.41.0")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--quiet", action="store_true",
                        help="only print the tally")
    options = parser.parse_args(argv[1:])

    if options.self_test:
        return self_test()

    paths = list(options.logs)
    if options.dir:
        paths += sorted(glob.glob(os.path.join(options.dir, "*.log")))
    if not paths:
        parser.print_help()
        return 2

    verdicts = {}
    seeds = []
    failures = []
    total_runs = 0
    total_fail = 0
    for path in paths:
        report = describe(path)
        if options.build and options.build not in report["build"]:
            continue
        total_runs += len(report["runs"])
        # apk keeps going after a stream fails, so its exit status is 0 even
        # on a bad run.  Trust the app's own PASS/FAIL tag when present.
        total_fail += sum(1 for run in report["runs"]
                          if run[2] != 0 or run[3] == "FAIL")
        if not options.quiet:
            print("=" * 78)
            print("%s  build %s  libz %s" %
                  (os.path.basename(path), report["build"],
                   report["libz"] or "(not logged)"))
            for run in report["runs"]:
                print("  RUN %d/%d status=%d %s" % run)
        for stream in report["streams"]:
            if stream["verdict"] == "EMPTY":
                continue
            verdicts[stream["verdict"]] = verdicts.get(stream["verdict"], 0) + 1
            if stream["seed"] is not None:
                seeds.append(stream["seed"])
            if stream["verdict"] not in ("CLEAN",):
                failures.append((os.path.basename(path), stream))
            if not options.quiet:
                print("  stream %-10s calls=%-4d %-7s %s" %
                      (stream["index"] or "?", stream["calls"],
                       stream["verdict"], stream["detail"]))
                if stream["fail"]:
                    print("      fail: %s" % stream["fail"])

    print()
    print("-" * 78)
    print("logs=%d runs=%d failed_runs=%d" %
          (len(paths), total_runs, total_fail))
    for verdict in sorted(verdicts):
        print("  %-8s %d" % (verdict, verdicts[verdict]))
    if seeds:
        unique = sorted(set(seeds))
        print("  recovered seeds: %s" % ", ".join("0x%08x" % s for s in unique))
        if len(unique) == 1:
            print("  -> same value every time: a constant is being written")
        else:
            print("  -> different values: the writer stores changing data "
                  "(pointer, counter, or copied bytes)")
    if not failures:
        if "CLEAN" in verdicts:
            print("  -> every stream kept a correct check: no stray store here")
        else:
            print("  -> no [zck] lines: is this an instrumented (zspy) run?")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
