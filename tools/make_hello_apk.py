#!/usr/bin/env python3
"""
Build the tiny unsigned Alpine package used by "Run APK Add Hello".

APK v2 is two concatenated gzip streams: a control tar (.PKGINFO) followed
by a data tar.  The control tar must NOT contain the end-of-archive zero
blocks, otherwise the tar parser stops there and never reaches the data.
The datahash is the SHA-256 of the compressed data stream.
"""

import gzip
import hashlib
import io
import sys
import tarfile


def make_tar(entries, cut_end):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w",
                      format=tarfile.PAX_FORMAT) as archive:
        for name, is_dir, data, mode in entries:
            info = tarfile.TarInfo(name)
            info.mtime = 1700000000
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mode = mode
            if is_dir:
                info.type = tarfile.DIRTYPE
                info.size = 0
                archive.addfile(info)
            else:
                info.size = len(data)
                if name.endswith("hello"):
                    # apk treats files without an embedded checksum as a
                    # broken install (broken_files=1, exit code 1).
                    info.pax_headers = {
                        "APK-TOOLS.checksum.SHA1":
                            hashlib.sha1(data).hexdigest(),
                    }
                archive.addfile(info, io.BytesIO(data))
    raw = buffer.getvalue()
    if cut_end:
        # Python's tarfile pads the archive to a 10240-byte record, so strip
        # every trailing all-zero block.  The tar parser must flow straight
        # into the next gzip member (the data tar) without seeing EOF blocks.
        blocks = [raw[index:index + 512]
                  for index in range(0, len(raw), 512)]
        while blocks and blocks[-1] == b"\0" * 512:
            blocks.pop()
        raw = b"".join(blocks)
    return raw


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: make_hello_apk.py <hello-elf> <out.apk>")
    payload = open(sys.argv[1], "rb").read()

    data_tar = gzip.compress(make_tar([
        ("usr", True, b"", 0o755),
        ("usr/bin", True, b"", 0o755),
        ("usr/bin/hello", False, payload, 0o755),
    ], cut_end=False), mtime=0)

    pkginfo = "\n".join([
        "pkgname = hello",
        "pkgver = 1.0-r0",
        "pkgdesc = Linux Probe test package",
        "url = https://github.com/Da-AiXZ/linux",
        "builddate = 1700000000",
        "packager = Linux Probe",
        "size = %d" % len(payload),
        "arch = aarch64",
        "origin = hello",
        "datahash = %s" % hashlib.sha256(data_tar).hexdigest(),
        "",
    ]).encode()

    control_tar = gzip.compress(make_tar([
        (".PKGINFO", False, pkginfo, 0o644),
    ], cut_end=True), mtime=0)

    with open(sys.argv[2], "wb") as handle:
        handle.write(control_tar)
        handle.write(data_tar)
    print("wrote %s (%d bytes)" % (sys.argv[2], len(control_tar) + len(data_tar)))


if __name__ == "__main__":
    main()
