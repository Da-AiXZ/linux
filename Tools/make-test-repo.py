#!/usr/bin/env python3
"""Build the local APK repository the G5 tests use.

`apk update` and `apk add` are the gate this project dies or survives on, and
they have to run without a network: a repo served from a directory inside the
guest root is the smallest thing that still exercises the whole path -- index,
fetch, archive, database.

The packages are **the real Alpine ones**, byte for byte, with their index
records copied verbatim.  Hand-built packages were tried first and apk answered
"BAD archive" at unpack time; a repository that ships anything but upstream
bytes would be testing our idea of the format instead of apk's.

    python Tools/make-test-repo.py            # fill in what is missing
    python Tools/make-test-repo.py --verify   # only check what is there

Packages are cached in v2/tests/guest/root/.apk-cache (gitignored); the copies
under repo/ are committed, so CI needs no network.
"""
import argparse
import gzip
import hashlib
import io
import os
import re
import sys
import tarfile
import urllib.request

BRANCH = "v3.21"
ARCH = "aarch64"
BASE = f"https://dl-cdn.alpinelinux.org/alpine/{BRANCH}/main/{ARCH}/"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "v2", "tests", "guest", "root")
REPO = os.path.join(ROOT, "repo", "main", "aarch64")
CACHE = os.path.join(ROOT, ".apk-cache")

# musl provides so:libc.musl-aarch64.so.1, which everything else depends on;
# zlib is small, real, and installs exactly one file we can look for.
PACKAGES = ["musl", "zlib"]


def fetch(url):
    print(f"  get {url}")
    with urllib.request.urlopen(url, timeout=240) as response:
        return response.read()


def index_text():
    cached = os.path.join(CACHE, "APKINDEX.tar.gz")
    raw = open(cached, "rb").read() if os.path.exists(cached) else None
    if raw is None:
        raw = fetch(BASE + "APKINDEX.tar.gz")
        os.makedirs(CACHE, exist_ok=True)
        open(cached, "wb").write(raw)
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tar:
        return tar.extractfile("APKINDEX").read().decode()


def records(text):
    out = {}
    for block in text.split("\n\n"):
        match = re.search(r"^P:(.+)$", block, re.M)
        if match:
            out[match.group(1).strip()] = block.strip()
    return out


def tar_gz(entries):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w",
                      format=tarfile.USTAR_FORMAT) as tar:
        for name, data, mode in entries:
            info = tarfile.TarInfo(name)
            info.mode, info.uid, info.gid = mode, 0, 0
            info.uname = info.gname = "root"
            info.mtime = 1700000000
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return gzip.compress(raw.getvalue(), mtime=0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()

    table = records(index_text())
    os.makedirs(REPO, exist_ok=True)
    os.makedirs(CACHE, exist_ok=True)

    keep = []
    for name in PACKAGES:
        if name not in table:
            print(f"{name} is not in the index")
            return 1
        version = re.search(r"^V:(.+)$", table[name], re.M).group(1).strip()
        filename = f"{name}-{version}.apk"
        cached = os.path.join(CACHE, filename)
        raw = open(cached, "rb").read() if os.path.exists(cached) else None
        if raw is None:
            raw = fetch(BASE + filename)
            open(cached, "wb").write(raw)

        target = os.path.join(REPO, filename)
        if args.verify:
            current = open(target, "rb").read() if os.path.exists(target) else b""
            if hashlib.sha256(current).hexdigest() != hashlib.sha256(raw).hexdigest():
                print(f"  DIFFERS {filename}")
                return 1
            print(f"  ok      {filename} ({len(raw)} bytes)")
        else:
            open(target, "wb").write(raw)
            print(f"  write   {filename} ({len(raw)} bytes)")
        keep.append(table[name] + "\n\n")

    if not args.verify:
        archive = tar_gz([("DESCRIPTION", b"v2 test repository\n", 0o644),
                          ("APKINDEX", "".join(keep).encode(), 0o644)])
        open(os.path.join(REPO, "APKINDEX.tar.gz"), "wb").write(archive)
        print(f"  index   {len(archive)} bytes, {len(keep)} record(s)")

        # apk 2.x keeps its database in /lib/apk/db and needs the directory to
        # exist; git cannot store an empty directory, hence the .keep files.
        etc_apk = os.path.join(ROOT, "etc", "apk")
        for directory in (etc_apk, os.path.join(etc_apk, "keys"),
                          os.path.join(ROOT, "var", "cache", "apk"),
                          os.path.join(ROOT, "lib", "apk", "db")):
            os.makedirs(directory, exist_ok=True)
            keep_file = os.path.join(directory, ".keep")
            if not os.path.exists(keep_file):
                open(keep_file, "w").close()
        with open(os.path.join(etc_apk, "repositories"), "w") as handle:
            handle.write("/repo/main\n")
        with open(os.path.join(etc_apk, "arch"), "w") as handle:
            handle.write("aarch64\n")
        open(os.path.join(etc_apk, "world"), "w").close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
