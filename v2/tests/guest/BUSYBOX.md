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

## Result (2026-11-24, macOS arm64 runner)

```
ls /            etc  hello.txt  sub
cat /etc/motd   v2 guest rootfs
uname -a        Linux v2 6.6.0-v2 #1 SMP aarch64 GNU/Linux
ls -l            -rw-r--r--    1 0 0    26 Nov 23 18:01 /hello.txt
id              uid=0(root) gid=0(root)
pwd             /
```

Three defects stood between "it loads" and this output, all found by running:

1. **AT_PHENT / AT_PHNUM tags were 11 / 10.** The real numbers are 4 and 5.
   musl computes the load bias by walking the program headers looking for
   PT_DYNAMIC; with a zero count it never entered the loop, kept base = 0 and
   faulted relocating against address 0x280. `hello` never noticed because it
   is pure assembly and reads no auxv.
2. **`writev` was missing.** musl's stdio flushes through `writev` when more
   than one buffer is pending, so every applet "ran" and printed nothing.
3. **The runner's diagnostics went to stdout**, so `pwd` -- which should be
   one line -- came back as five lines of `[v2] ...` plus "/". Diagnostics are
   stderr now; the guest owns stdout.
