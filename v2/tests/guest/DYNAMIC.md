# G4 的 guest 运行时（Alpine v3.21 / aarch64）

`root/` 是本项目唯一的“根文件系统”。G3 只用它的 `etc/` 和文本文件；
G4 起它还装着 musl 与 apk 的依赖，因为动态链接必须真的从磁盘上把库读进来。

所有文件直接从 `https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/` 的
官方 apk 包中取出（未重打包、未打补丁），因此这里的 sha256 就是上游的字节。
取包脚本见 `Tools/fetch-alpine-rootfs.py`。

| 路径 | 字节 | 来自 | 为什么需要 |
|---|---:|---|---|
| `lib/ld-musl-aarch64.so.1` | 723480 | musl 1.2.5-r12 | the interpreter named by PT_INTERP |
| `lib/libc.musl-aarch64.so.1` | 723480 | musl 1.2.5-r12 | same file; DT_NEEDED name |
| `bin/busybox` | 919304 | busybox 1.37.0-r14 | dynamic build (needs ld.so) |
| `sbin/apk` | 69264 | apk-tools 2.14.13-r0 | `apk --version` |
| `usr/lib/libapk.so.2.14.0` | 200328 | apk-tools 2.14.13-r0 | apk's own library |
| `usr/lib/libcrypto.so.3` | 4139216 | libcrypto3 3.3.7-r2 | OpenSSL crypto |
| `usr/lib/libssl.so.3` | 868080 | libssl3 3.3.7-r2 | OpenSSL tls |
| `usr/lib/libz.so.1` | 133008 | zlib 1.4-r0 | deflate |

## sha256

```
a965363d0cb99ab9b28f4c51ee6bb64162b4e204f0d20efda72541a2e4147a5e  lib/ld-musl-aarch64.so.1
a965363d0cb99ab9b28f4c51ee6bb64162b4e204f0d20efda72541a2e4147a5e  lib/libc.musl-aarch64.so.1
f35a45f702095d9c2a718deb42c1cf4efa6d2919f212d273c4ea569d0bd03dcb  bin/busybox
7df7ac45057ea5aceebda93691bda6886ae479d0ff7250ca5ce8d46caa77179c  sbin/apk
2825f0d8566d9b4c5d82694bddc26b21288bf2293c9cb8054958659447bf7e38  usr/lib/libapk.so.2.14.0
c7ca672c906187d617c8585f82c024f6a26db7188ba0dc4036732923d2203974  usr/lib/libcrypto.so.3
2ef41af26ced4419f0855d941783aa06f10f90f1ae6be840b9a38da48b793353  usr/lib/libssl.so.3
d948400330d462b285d528e2f2666c027918b09b3dc4c9ceef2d4a4a732e312f  usr/lib/libz.so.1
```

## 为什么是静态 PIE（G3）又为什么是动态（G4）

两者都要。

- 静态 PIE 证明**装载器本身**能处理自举（musl 的 `rcrt1.o` 自己做重定位）；
- 动态证明**装载器 + ld.so** 能协作：我们只负责把 ld.so 放到它要的位置、
  把 `AT_BASE` 指过去，剩下的库查找、符号解析、重定位全部由 guest 里的 ld.so
  完成——那是 musl 的代码在用我们的 `openat`/`pread64`/`mmap`/`mprotect`。

## Alpine 的二进制是 PIE

这一点在 G4 之前必须确认，否则整步做不成：

```
lib/ld-musl-aarch64.so.1   ET_DYN  lowest_vaddr=0x0
bin/busybox                ET_DYN  lowest_vaddr=0x0   interp=/lib/ld-musl-aarch64.so.1
sbin/apk                   ET_DYN  lowest_vaddr=0x0   interp=/lib/ld-musl-aarch64.so.1
usr/lib/libcrypto.so.3     ET_DYN  lowest_vaddr=0x0
```

Alpine 自 3.13 起默认 `-fPIE -pie`，所以所有包都是 `ET_DYN`、最低段在 0。
这与 iOS/macOS 的“不许映射 4 GiB 以下”正好相容：我们自己做 ASLR，
把镜像放在 arena 里任意一个 16 KiB 对齐的位置。

## 目录是摊平的，不是真的 rootfs

`openat` 的词法翻译把 guest 的 `/usr/lib/libz.so.1` 变成
`<root>/usr/lib/libz.so.1`，所以这里只需要普通文件，不需要 chroot 或 loop 设备。
musl 的默认搜索路径是 `/lib:/usr/local/lib:/usr/lib`，因此：

- `libc.musl-aarch64.so.1` → `lib/`
- `libapk.so.2.14.0` / `libcrypto.so.3` / `libssl.so.3` / `libz.so.1` → `usr/lib/`

`libz.so.1.4` 在包里叫这个名字，但它的 `DT_SONAME` 是 `libz.so.1`，而 musl 是按
**文件名**查找的，所以这里直接复制成 `libz.so.1`。

## 许可

这些文件是 Alpine（musl libc：MIT；busybox：GPLv2；apk-tools：GPLv2；
OpenSSL：Apache-2.0；zlib：zlib）的产物，仅作为**测试输入**存在，不参与
本项目自身的编译，也不随 App 分发。`v2-ios.yml` 只把 `tests/guest/hello`
和静态 `busybox` 放进 IPA。
