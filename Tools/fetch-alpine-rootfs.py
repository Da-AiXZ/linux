#!/usr/bin/env python3
"""Rebuild v2/tests/guest/root from the Alpine packages it came from.

The G4 test needs a real musl runtime and apk; both are taken byte for byte out
of the official Alpine packages rather than rebuilt, so that "it works" means
"it works on what Alpine ships".  Run this if the rootfs is ever doubtsome:

    python Tools/fetch-alpine-rootfs.py            # fill in what is missing
    python Tools/fetch-alpine-rootfs.py --verify   # only check hashes

`--verify` is what CI could call if we ever wanted the hashes enforced; today
the files are committed and the hashes live in v2/tests/guest/DYNAMIC.md.

A proxy is honoured through the usual HTTPS_PROXY environment variable.
"""
import argparse
import hashlib
import io
import os
import sys
import tarfile
import urllib.request

BASE = "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                    "v2", "tests", "guest", "root")

# package -> [(member, destination)]
PACKAGES = {
    "musl-1.2.5-r12.apk": [
        ("lib/ld-musl-aarch64.so.1", "lib/ld-musl-aarch64.so.1"),
        ("lib/ld-musl-aarch64.so.1", "lib/libc.musl-aarch64.so.1"),
    ],
    "busybox-1.37.0-r14.apk": [
        ("bin/busybox", "bin/busybox"),
    ],
    "apk-tools-2.14.13-r0.apk": [
        ("sbin/apk", "sbin/apk"),
        ("usr/lib/libapk.so.2.14.0", "usr/lib/libapk.so.2.14.0"),
    ],
    "libcrypto3-3.3.7-r2.apk": [
        ("usr/lib/libcrypto.so.3", "usr/lib/libcrypto.so.3"),
    ],
    "libssl3-3.3.7-r2.apk": [
        ("usr/lib/libssl.so.3", "usr/lib/libssl.so.3"),
    ],
    "zlib-1.4-r0.apk": [
        # The file inside the package is libz.so.1.4; musl looks libs up by
        # file name, and the SONAME is libz.so.1, so it is stored as that.
        ("usr/lib/libz.so.1.4", "usr/lib/libz.so.1"),
    ],
}


def fetch(name):
    url = BASE + name
    print(f"  get {url}")
    with urllib.request.urlopen(url, timeout=180) as response:
        return response.read()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true",
                        help="only re-read the existing files")
    args = parser.parse_args()

    for package, members in PACKAGES.items():
        local = os.path.join(ROOT, ".apk-cache", package)
        cached = os.path.exists(local)
        if not args.verify and not cached:
            raw = fetch(package)
            os.makedirs(os.path.dirname(local), exist_ok=True)
            with open(local, "wb") as handle:
                handle.write(raw)
            cached = True
        if not cached:
            print(f"  {package}: not cached, run without --verify")
            return 1

        with open(local, "rb") as handle:
            raw = handle.read()
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tar:
            for member, destination in members:
                data = tar.extractfile(member).read()
                path = os.path.join(ROOT, destination)
                if args.verify:
                    if not os.path.exists(path):
                        print(f"  MISSING {destination}")
                        return 1
                    current = open(path, "rb").read()
                    if hashlib.sha256(current).hexdigest() != \
                            hashlib.sha256(data).hexdigest():
                        print(f"  DIFFERS {destination}")
                        return 1
                    print(f"  ok      {destination}")
                else:
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    with open(path, "wb") as output:
                        output.write(data)
                    print(f"  write   {destination} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
