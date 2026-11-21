# AGENTS.md

代码仓库。项目背景、当前状态、真机日志、决策与路线在私有工作区
[Da-AiXZ/linux-workspace](https://github.com/Da-AiXZ/linux-workspace)。动手前按顺序读：
`AGENTS.md` → `docs/STATUS.md` → `docs/ROADMAP.md` → `docs/DECISIONS.md`，历史细节查
`docs/JOURNAL.md`。

## 一句话

在 iPad Pro 2021（M1 / arm64e，iPadOS 16.6.1，TrollStore 2）上**原生执行** Linux 用户态：
guest arm64 指令由 M1 直接跑，只把 `svc #0` 改写成分支，进自建 syscall 层。
不是虚拟机、不是模拟器、不是解释器。

## 当前状态（2026-11-22，0.37.1 / build 74）

- **M0–M2.5 全部真机通过**。0.34.1：`Run Shell` 六条命令（`ls /`、`cat /etc/motd`、
  `uname`、`ls -l /`、`id`、`pwd`）全对，`status=0`；`Run Fork Test` 父子分别输出。
- **M3.1 已完成（0.35.5 真机）**：
  - 解析 `PT_INTERP`，加载 musl `ld-musl-aarch64.so.1` 到独立基址
  - auxv 写 `AT_BASE`=动态链接器（ld.so）基址、`AT_ENTRY`=主程序入口
  - 文件 `mmap` 改成 anon + `pread` 模拟（4KB offset、未签名 `.so` 的 `PROT_EXEC`）
  - 库在 mmap 时解析 phdr，对可执行段现场打 `svc`/`mrs`/`msr` 补丁
  - CI 随包带 Alpine 3.20.3 的 musl/libapk/libcrypto/libssl/libz + `apk`/`busybox`
  - 新菜单项：`Alpine BusyBox (dynamic)`、`Run APK --version`
  - 0.35.1：所有动作收进右上角 `...` 菜单，日志视图占满全屏
  - 0.35.2：`guest-runner` 在 `<App>/Helpers/`，Alpine 目录是 `<App>/Helpers/alpine`；
    之前误拼成 `Helpers/Helpers/alpine`，导致 `cannot read interp`。
    `/lib/*.so*` 在 rootfs 缺失时现在直接回退到 bundle 的 `Helpers/alpine/lib/`
  - 0.35.3：`msr tpidr_el0` 也必须用不建链接的 per-site 岛。musl 的
    `__set_thread_area` 是 leaf，`bl writeStub` 会先把 x30 改成 site+4，
    函数末尾 `ret` 回到 site+4 自循环。岛只借 x16（保存/恢复），不碰 x30。
  - **0.35.3 真机：动态 Alpine busybox 成功**（`Linux linuxprobe 6.6.0 #1 aarch64 Linux`，
    `status=0`）。`apk --version` 失败：加载 `libcrypto.so.3` / `libssl.so.3` 时
    `MAP_FIXED` 的 RW 段返回 `-ENOMEM`（`0xfffffffffffffff4`），随后符号重定位报
    `symbol not found`。
  - 0.35.4：`MAP_FIXED` 的文件段不能把长度对齐到 16KB 后再整体 `mprotect`
    （会 mprotect 到未映射页 → `ENOMEM`，且会把相邻 `.text` 的 `PROT_EXEC` 打掉）。
    改成 `GuestEnsureWritable`（只对未映射 host 页新建映射）+ `GuestProtectRange`
    （完整覆盖的页用精确权限，边缘 4KB/16KB 共享页取并集）。
  - **0.35.4 真机：库的 `MAP_FIXED` 全部成功**（`libcrypto`/`libssl`/`libz`/`libapk`
    的 RW 段都返回正确地址），但随后在 `libz+0x2830` 取指 `SIGBUS`：
    `esr=0x8200000f`（instruction abort，permission fault，level 3）。
  - 0.35.5：`GuestProtectRange` 的精确区间起点写成了 `headPage + 0x4000`，
    当 guest 地址已 16KB 对齐时**第一页永远不会被 mprotect**，整文件映射的第一页
    停在 `PROT_READ|PROT_WRITE`（不可执行）。改成 `firstFull = GuestAlignUp(address)`。
  - **0.35.5 真机：M3.1 完成**。动态 Alpine busybox `status=0`；
    `apk --version` 打印 `apk-tools 2.14.4, compiled for aarch64.`，`status=0`。
    只剩 `unsupported syscall 166`（umask）。
- **M3.2 已完成（0.37.1 真机）**：
  - guest 身份改为 root（`getuid/geteuid/getgid/getegid` 返回 0），否则 apk 拒绝安装；
    `fchownat/fchown` 直接返回成功（宿主用户无法 chown，但单用户运行时不需要）
  - 新增 syscall：`statfs(43)`、`fstatfs(44)`、`flock(32)`、`fchmod(52)`、
    `fchmodat(53)`、`umask(166)`；`statfs` 结构体按 Linux arm64 布局手工填充
  - rootfs 初始化：`/etc/apk/arch`、`/etc/apk/repositories`、`/etc/apk/world`、
    `/lib/apk/db/installed`（只在缺失时创建）；把 `Helpers/alpine-apk` 复制到 `/sbin/apk`
  - CI 用 `tools/make_hello_apk.py` 生成 625B 的 `hello.apk`（control tar 必须去掉
    tar 结束块，且普通文件要带 `APK-TOOLS.checksum.SHA1` PAX 记录，否则 apk 报错）
  - App 新增 `Run APK Add Hello`：静态 busybox shell → fork/exec `/sbin/apk` → 安装并运行
    `/usr/bin/hello`
  - **0.36.0 真机**：`Run APK Add Hello` 失败——父进程是动态 Alpine busybox，
    `sh` fork 时 `GuestForkWithSnapshot` 因 `GuestInterpBase != 0` 返回 `-ENOSYS`
    （`sh: can't fork`，`status=2`）。同一次 `Run Shell` 里 `cat` 还撞到
    `no free address range near trampoline`（execve 的固定候选地址全被占用）。
  - 0.36.1：`Run APK Add Hello` 改用**静态 busybox** 作 shell（静态父进程可以
    checkpoint/restore fork），子进程 exec 动态 `/sbin/apk`；`GuestChooseBase`
    改为在 ±64MB 内按 16MB 步进扫描双向候选。
  - **0.36.1 真机：fork 快照仍不稳**——`/sbin/apk` 在恢复子进程里照样
    `no free address range near trampoline`；`Run Shell` 的 `ls -l /` 恢复子进程
    直接 `pc=0x110204000`（堆地址）取指 abort；其余命令正常。
  - 0.37.0：M3.2 验收改为**不经 shell**：`Run APK Add Hello` 直接跑
    `Helpers/alpine-apk add --allow-untrusted /tmp/hello.apk`；新增
    `Run Installed Hello` 直跑 `<rootfs>/usr/bin/hello`（`GuestLauncher` 支持绝对路径）。
    fork 快照的深层问题留到 M4 单独修。**待真机**。
  - **0.37.0 真机**：直跑 `apk add` 已进入 apk 主逻辑，失败在
    `openat /lib/apk/db/lock` → `ENOENT`（`Unable to lock database`，`status=99`）。
  - 0.37.1：`apk add` 加 `--initdb`；`openat(O_CREAT)` 遇 `ENOENT` 时创建父目录并重试；
    bootstrap 增加 `apk db dir=... exists=...` 诊断。
  - **0.37.1 真机：M3.2 完成**。`apk add` 输出
    `(1/1) Installing hello (1.0-r0)` + `OK: 0 MiB in 1 packages`，`status=0`；
    `Run Installed Hello` 输出 `hello from linux elf`，`status=0`。
    剩余杂音：`unsupported syscall 40/39`（apk 尝试 mount/umount2，忽略失败）、
    `/etc/apk/protected_paths.d`、`/etc/apk/cache` 探测失败（可选路径）。
- 最新产物：`/workspace/LinuxProbe-0.37.1.ipa`
  sha256 `5ea6b97d62acd58f3504bcfd2de183706caf56d1b468406972059b420dfa0a90`
- **下一步**：M3.3 网络 + `apk update`（socket 透传、poll、DNS、TLS）；之后再修 fork 快照（M4）。

## 两个仓库

| 仓库 | 可见性 | 用途 |
|---|---|---|
| `Da-AiXZ/linux` | public | 代码、XcodeGen 工程、CI、产物 |
| `Da-AiXZ/linux-workspace` | private | 上下文、状态、决策、路线、日志 |

代码路径：

```
project.yml                     XcodeGen 定义（版本号在这里改）
.github/workflows/build.yml     CI：下载 Alpine、构建、签名、打包
App/                            宿主 App（ProbeViewController、GuestLauncher）
Guest/GuestRunner.m             ★ 核心：ELF 加载器 + PT_INTERP + svc/TLS 改写 +
                                  syscall 分发 + checkpoint/restore fork
Shared/                         Mach / IPC 常量
LiveProcess/                    NSExtension 探针（历史遗留，非主线）
Helper/ProbeHelper.m            能力探针
Tools/busybox.static            自建 glibc static-PIE busybox（ET_DYN，~2.3MB）
Tools/pie-hello                 glibc static-PIE 最小程序
tools/make_guest_elf.py         生成最小 aarch64 ELF
tools/make_fork_elf.py          生成 fork 测试 ELF
```

## 构建与交付

没有本地 Xcode。所有构建走 GitHub Actions：

```bash
# 改完并 push main 后
gh run list --limit 3
gh run watch <run-id> --exit-status
gh run download <run-id> -n LinuxProbe-ipas -D /workspace/dlN
unzip -p /workspace/dlN/LinuxProbe.ipa Payload/Probe.app/Info.plist | plutil -p -
cp /workspace/dlN/LinuxProbe.ipa /workspace/LinuxProbe-X.Y.Z.ipa
shasum -a 256 /workspace/LinuxProbe-X.Y.Z.ipa
```

用户网络打不开 GitHub，**必须**把 IPA 下载到 `/workspace` 并给 `computer://` 链接和 sha256。

`gh run download` 必须在仓库目录内执行；偶发 `file exists`/`EOF` 时先 `rm -rf dlN` 再重试。

## 版本号

每次 push 前改 `project.yml`：

```yaml
MARKETING_VERSION: "X.Y.Z"
CURRENT_PROJECT_VERSION: "N"
```

用户靠标题里的 `X.Y.Z (N)` 区分版本，**不要重复用同一个版本号构建**。

## 签名（高优先级）

- 最后一步 `codesign` **必须带 `--entitlements`**，否则会把 ldid 写入的权限剥掉。
- 禁止添加：`com.apple.private.cs.debugger`、`dynamic-codesigning`、
  `com.apple.private.skip-library-validation`（A12+/iOS 15+ 带上必闪退）。
- 不要缩小 `__PAGEZERO`，不要给主程序设置 `-pagezero_size`（`posix_spawn` 报 88）。
- 可用组合：`get-task-allow`、`com.apple.private.security.no-sandbox`、
  `platform-application`、`container-required=false`、`no-container`、存储类权限；
  Helper 额外 `allow-jit`、`com.apple.private.hypervisor`、`com.apple.private.memorystatus`。

## Guest 运行时不变量（`Guest/GuestRunner.m`）

1. guest 必须是 **ET_DYN / PIE**；iOS 不允许映射 4GB 以下。
2. guest 是 4KB 页，host 是 16KB 页。固定映射地址必须 16KB 对齐；`mprotect` 的 guest
   范围可能只覆盖 host 页的一部分，**不能**把范围取整后整体 `mprotect`：
   完整覆盖的 host 页用精确权限，边缘共享页取"当前权限 | 新权限"（`GuestProtectRange`）。
3. guest 初始 `sp` 必须 16 字节对齐。
4. 改写代码页后调用 `sys_icache_invalidate`。
5. **`svc` / `mrs` / `msr tpidr_el0` 都必须用"不建链接"的 per-site 跳板**（`b island`）：
   `bl` 会把 `x30` 改成 `site+4`；glibc 的 leaf wrapper、musl 的 `__set_thread_area`
   都会因此 `ret` 回 `site+4` 自循环。
6. 入口栈上的 argv/envp/auxv 必须完整：
   `AT_PHDR/AT_PHENT/AT_PHNUM/AT_PAGESZ(4096)/AT_BASE/AT_ENTRY/AT_RANDOM/AT_HWCAP/AT_EXECFN`。
   静态：`AT_BASE=0`、`AT_ENTRY`=主程序入口；动态：`AT_BASE`=动态链接器基址。
7. `brk` 返回**当前 break**，初始为堆起始；堆是预映射的 64MB。
8. syscall 返回必须保留 `x1–x17`、`TPIDR_EL0`、`NZCV`。
9. **TPIDR_EL0 不可依赖**：XNU 会在中断/调度返回时把它重置成自己的值。
   装载时把每条 `mrs xN, tpidr_el0` / `msr tpidr_el0, xN` 改成影子变量
   `GuestTlsPointer` 的读写桩；否则第一次 TLS 访问就崩。
10. TLS stub 的栈保存只用 `str x30, [sp, #-16]!` / `ldr x30, [sp], #16`；
    不要用 `ldp/stp ..., xzr`（0.19.0 真机 SIGILL）。
11. 手写指令编码按字段位移填：`mov x0, x<rt>` 是 `0xAA0003E0 | (rt << 16)`。
12. **fork 不能依赖宿主 fork 子任务**：iOS 的 fork 子进程里主程序 `__TEXT`
    是 `prot=1 max=1`，匿名 `r-x` 页首次取指也指令 abort（ESR `0x82000006`）。
    现在的实现是 checkpoint/restore：写快照（已 patch 镜像 + `[heapBase, brk)` +
    `[stackPage, stackTop)`）→ `posix_spawn --restore` → 同址恢复 → `x0=0`、
    `sp=frame` → 跳 `GuestSyscallTrampoline+0x48`。动态可执行文件的 fork 暂未支持，
    `GuestForkWithSnapshot` 会在 `GuestInterpBase != 0` 时返回 `-ENOSYS`。
13. **detach 握手可用**：runner 打印 `ready for detach` 后 `raise(SIGSTOP)`；
    App（真正的 tracer）在 `waitpid(WUNTRACED)` 收到 SIGSTOP 后
    `ptrace(PT_DETACH, pid, NULL, SIGCONT)`，再补发若干次 SIGCONT。
    子进程自 detach 会 `EPERM`；对运行中的 tracee detach 会 `EBUSY`。
14. **文件映射必须模拟**：`mmap(fd, offset)` 不直接透传，而是
    `anon RW + pread + 打补丁 + mprotect`。原因：Alpine ELF 的段偏移是 4KB 对齐，
    宿主要求 16KB；未签名 `.so` 的文件页在 iOS 上拿不到 `PROT_EXEC`。
15. **运行期库也要打补丁**：musl ld.so 会先整文件 mmap、再按 `PT_LOAD` `MAP_FIXED`；
    每次文件 mmap 都解析 ELF phdr，对 `PT_LOAD|X` 区间扫描并改写
    `svc`/`mrs`/`msr`。补丁期间跳板岛临时 `mprotect RW`，补完封回 RX。
16. **`MAP_FIXED` 段不能 remap 整个 16KB host 页**：guest 段只覆盖这个 host 页的一部分时，
    邻居段的字节（包括已打的代码补丁）和权限都必须保留。用 `GuestEnsureWritable`：
    已映射的页只加 `PROT_WRITE`，只有真正未映射的 host 页才新建映射；
    长度用 guest 原始 `length`，不能用对齐后的 `mapLength`（0.35.4 修）。
17. **所有 guest mmap/库映射都要在跳板岛 ±112MB 内**（`i` 指令 ±128MB）。
    跳板岛 1MB；`GuestAllocateMmapAddress` 负责选址。
18. `Tools/busybox.static` / `Tools/pie-hello` 是二进制。**绝不能让文本模式工具重写它们**
    （0.26.2 被 UTF-8 替换字符污染，2,302,928 → 3,829,530 B）。改完必须校验大小和 ELF 头。
19. rootfs：guest `/` → `<容器>/Documents/rootfs`，由 App 通过 `LINUXPROBE_ROOT` 传入。
    `GuestBootstrapRootfs` 负责建目录、写 `/etc/*`、装 static busybox 与 Alpine 运行时。

## 调试

沙箱里可以用交叉工具链反汇编 guest：

```bash
aarch64-linux-gnu-objdump -d Tools/busybox.static | less
# offset = pc - base（日志里有 base 和 pc）
```

0.35.x 关键日志：

| 日志 | 含义 |
|---|---|
| `[guest] interp <path> host=… base=0x… size=0x…` | 找到并映射了动态链接器 |
| `[guest] loaded … patched=N … interp=0x…` | 主镜像 + 动态链接器补丁总数 |
| `[guest] mmap addr=… len=… prot=… fd=… off=… -> 0x…` | guest mmap 前 12 次调用 |
| `[guest] mmap elf off=… patched=… mrs=… msr=…` | 运行时库现场补丁数 |
| `[guest] mmap anon fixed … in host page …` | 固定匿名映射（4KB 粒度） |
| `[guest] mprotect 0x… host pages from 0x…` | 非 16KB 对齐的 mprotect，边缘页取并集 |
| `[guest] entry=… at_base=… at_entry=…` | 动态链接器入口与 auxv |
| `[guest] unsupported syscall N` | ld.so/apk 需要的下一个 syscall |
| `[guest] signal N … pc=… far=… esr=…` | 进程内故障现场 |
| `[guest] alarm1/2/3 pc=…` | 20s watchdog |

定位：`offset = pc - base`，用 `llvm-objdump`/`aarch64-linux-gnu-objdump` 查该地址。

## 当前优先级

1. **M3.3 网络 + `apk update`**：socket 透传（AF_INET / sockaddr 转换、SOL_SOCKET
   选项常量）、`poll/ppoll/select`、`sendto/recvfrom/sendmsg/recvmsg`、DNS、TLS；
   验收 `apk update`、`apk add bash`。
   - 注意 Linux 与 Darwin 的 socket 常量不同（`SOL_SOCKET` Linux=1 / Darwin=0xffff，
     `sockaddr` 有/无 `sa_len`）。
   - `apk` 目前会调 `mount/umount2`（40/39），失败可忽略。
2. M4：性能基准、syscall 按站点特化、fork 快照修复（动态镜像 fork + 恢复子进程选址）、交互终端、常用工具验证。

## 不要做

- 不要引入 QEMU / 虚拟机 / 解释器（用户已否决，性能目标不符）。
- 不要复制 LinuxRunner / iSH 的 GPL 代码。
- 不要为了让某个程序跑起来而加封禁 entitlement 或改动主程序 Mach-O 布局。
- 不要把 `svc`/`mrs` 改成 `bl`（x30 会被破坏）。
- 不要用宿主 fork 子进程执行 guest 代码（子进程没有可执行映射）。
- 不要用文本工具重写 `Tools/*` 二进制。
