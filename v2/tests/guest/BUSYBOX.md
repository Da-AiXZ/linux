# tests/guest/busybox — where this binary comes from

| | |
|---|---|
| version | busybox 1.36.1 |
| libc | musl, static, **PIE** (ET_DYN, no PT_INTERP) |
| machine | aarch64 |
| bytes | 1 297 640 |
| sha256 | `dbb3bebd6eef7e3fbf4cf9e6766fd88b7d57500f32b9ab22a015a690b0ff856f` |
| built by | `.github/workflows/v2-busybox.yml` (manual run) |

## Why it is not `busybox-static` from Alpine

Alpine's `busybox-static` is **ET_EXEC at 0x400000**. Neither iOS nor macOS
lets a process map that low (the arm64 minimum is 4 GiB), so the v2 loader
cannot place it at all — the address is not "hard", it is impossible.

A PIE build has no fixed address, which is exactly what the arena model
needs: the loader picks the base and everything is relative.

## How it is built

```
zig cc -target aarch64-linux-musl -fPIE -pie -O2    # compile and link
make -j$(nproc) CC=<wrapper> HOSTCC=gcc SKIP_STRIP=y
```

The wrapper in the workflow exists for four flags that GNU ld accepts and
lld does not:

| flag | why it has to go |
|---|---|
| `-Wp,-MD,<file>` | zig's driver deletes the path and reports FileNotFound; rewritten to `-MD -MF` |
| `-Wl,--warn-common` | lld has no such option |
| `-Wl,-Map,<file>` | ditto |
| `-Wl,--verbose` | ditto (it is the last flag on busybox's link line, so it failed last) |

Rebuild with **Actions → v2-busybox → Run workflow**, then download the
artifact and replace this file, updating the sha256 above.

## What it is used for

G3: six applets, each hitting a different part of the syscall table.

| command | exercises |
|---|---|
| `ls /` | openat, getdents64, close |
| `cat /etc/motd` | openat, read, write |
| `uname -a` | uname |
| `ls -l /hello.txt` | newfstatat, stat layout, localtime fallback |
| `id` | getuid/getgid, /etc/passwd via openat |
| `pwd` | getcwd |

`tests/guest/root/` is the guest's `/` for those runs; the app builds the
same fixture under `Documents/root` on the device.
