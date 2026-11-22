# Linux Probe

在 iPadOS 上以**原生速度**运行 Linux 用户态的实验工程。

目标设备：**iPad Pro 2021（M1，arm64e），iPadOS 16.6.1**，通过 **TrollStore 2** 安装（不上架 App Store）。

不是虚拟机，不是模拟器，不是解释器：guest 是 arm64 Linux ELF，指令由 M1 直接执行；
只把 `svc #0` 改写成分支，跳进自建的 syscall 分发器。

## 当前状态（0.40.11）

| 阶段 | 状态 |
|---|---|
| M0 能力探针 | ✅ JIT、fork/spawn、`task_for_pid`、Mach 服务、Hypervisor trap 全部实测 |
| M1 原生 ELF | ✅ 最小 aarch64 ELF 直接执行，`status=0` |
| M2 真实 busybox | ✅ glibc static-PIE `busybox` / `pie-hello` 原生执行，`status=0` |
| M2.5 文件系统 + shell | ✅ `Run Shell` 六条命令全部正确；外部命令走 checkpoint/restore fork + execve |
| M3.1 动态链接器 | ✅ 动态 Alpine busybox 与 `apk --version` 全部通过 |
| M3.2 本地 apk | ✅ `apk add --initdb --allow-untrusted /tmp/hello.apk` 安装并运行成功 |
| M3.3 网络 | 🚧 传输层全通（DNS/TCP/TLS/下载/RSA 校验），**卡在 `apk` 解析 `APKINDEX.tar.gz`** |
| 线程 / guest 信号 / 动态 fork / PTY | ❌ 未实现（M3.3 之后） |

最新版本 **0.40.11 (106)**。

### 唯一阻塞项：索引解析时 `IO ERROR`

`apk` 读取仓库索引时 `inflate()` 失败，`apk` 打印 `IO ERROR`，表现为随机失败
（同一进程有时能完整解析 `OK: 24049`）。

已经**证明**的事实（详见 workspace 仓库 `docs/BUG-index-io-error.md` 第 20 节）：

- 缓存索引与官方 CDN **逐字节一致**（sha256 `c9a6f6d0…` / `2978db48…`）；
- zlib 实际消费的字节与磁盘**逐位相同**（`crc32(file[:667],1)=1023b41d`，与设备上报值相同）；
- 索引是**多成员 gzip**，前 667 B 是签名段（解出 1024 B），zlib 在 667 处结束是正确行为；
- 加载的 libz **没有被补丁改写**（`svc=0 mrs=0 msr=0`）；
- 崩溃时 `inflate_state` **入场干净**（两个流逐字段相同）；
- 每次 `mmap` 返回的地址在创建时**都有真实后备**（`vm_region_64` 校验）；
- 崩溃地址**既不在释放区间**、**也不在任何映射记录**里。

收敛结论：libz 在写一块**从未登记、也从未释放**的地址。三条否定交叉后，唯一剩下的路径是
`GuestHandleFixedAnon`（子页 `MAP_FIXED`）——它只把地址改成可写并 `memset`，
**既不建立映射也不登记记录**，因此 guard page、canary、释放环表全都覆盖不到它。

下一步：给该路径补 `GuestRememberMmap` 与日志、审计 `GuestEnsureWritable` 是否真的建立映射、
把 `GuestHandleMremap` 里直接调宿主的 `munmap` 换成页感知释放。

项目上下文、决策、真机日志和路线记录在
[Da-AiXZ/linux-workspace](https://github.com/Da-AiXZ/linux-workspace)（私有）。

## 工作原理

```
Probe.app（宿主，TrollStore 去沙盒）
  │  posix_spawn + 管道
  ▼
Helpers/guest-runner <elf> [guest argv...]
  ├─ ptrace(PT_TRACE_ME) → CS_DEBUGGED（TrollStore 环境下可用）
  ├─ 读取 ELF，按 16KB 页对齐映射到 4GB 以上（ET_DYN / PIE）
  ├─ 若有 PT_INTERP：再把动态链接器（musl ld.so，ELF 术语叫 program interpreter）加载到独立基址
  ├─ 扫描可执行段，把 svc #0 / mrs tpidr_el0 / msr tpidr_el0 改写为 per-site 跳板
  │     svc/mrs:  b island          （不建链接，x30 不能被改）
  │     msr:      bl writeStub[rt]
  ├─ 构造 argv/envp/auxv（AT_PHDR/AT_PHNUM/AT_ENTRY/AT_BASE/AT_RANDOM…）
  └─ GuestJump(entry, 16 字节对齐的 sp)
         ▼
   guest arm64 指令直接在 M1 上执行
   遇到 syscall → 跳板 → trampoline → GuestSyscallDispatch（宿主 libc/syscall）
```

静态链接和动态链接的区别只在最后一步之前：

- **static-PIE**：入口是主程序 `_start`，`AT_BASE=0`。
- **PT_INTERP**：入口是动态链接器（ld.so）的 `_start`，`AT_BASE`=ld.so 基址，`AT_ENTRY`=主程序入口；
  ld.so 自己处理 `DT_NEEDED`、重定位、RELRO 和符号解析。

## 动态链接的关键处理（0.35.0）

1. **文件 `mmap` 不再透传**。Alpine 的 ELF 段偏移是 4KB 对齐、宿主页是 16KB；未签名 `.so`
   的文件页也拿不到 `PROT_EXEC`。所以一律 `anon + pread` 模拟，再按 guest 请求
   `mprotect`。
2. **库在映射时打补丁**。musl 的 ld.so 会先整文件 `mmap`、再按 `PT_LOAD` `MAP_FIXED`；
   我们在每次文件 mmap 时解析 phdr，找出可执行段，现场把 `svc` / `mrs` / `msr` 改掉。
3. **跳板岛要够近**。所有 guest 映射都放在跳板岛 ±112MB 内；跳板岛扩大到 1MB，
   库映射时临时 `mprotect RW`，补完再封回 RX。
4. **4KB guest 页 / 16KB host 页**。ld.so 的 `MAP_FIXED` 段可能只覆盖某个 16KB host 页的
   一部分；此时只对完整覆盖的 host 页应用精确权限，边缘页取"旧权限 | 新权限"，绝不能用
   取整后的范围整体 `mprotect`（会越界返回 `ENOMEM`，也会把相邻 `.text` 的 `PROT_EXEC` 打掉）。
5. **`MAP_FIXED` 不能重新映射整页**。段与段共享 16KB 页时，新映射会清掉邻居的字节和代码补丁；
   只有 host 页确实未映射时才新建，其余只改权限。

## 实测约束（决定架构的关键）

1. **JIT**：`MAP_JIT` 不可用；`dynamic-codesigning` 在 A12+/iOS 15+ 会闪退。
   用 `ptrace(PT_TRACE_ME)` 获得 `CS_DEBUGGED`。**不要用 `PT_SIGEXC` + 自建 Mach 异常端口**：
   实测端口注册成功但收不到 guest 故障。
2. **4GB 以下不可映射**：64 位进程 `VM_MIN_ADDRESS = 0x100000000`。
   guest 必须是 **ET_DYN / PIE**（Alpine 官方 `busybox-static` 是 ET_EXEC，不能用）。
3. **iOS fork 子任务不能执行我们的代码**：子进程里主程序 `__TEXT` 是 `prot=1 max=1`，
   匿名 `r-x` 页首次取指也指令 abort。所以 guest fork 走 **checkpoint/restore**：
   写快照 → `posix_spawn` 新 runner → 同址恢复 → 从 `svc` 返回点继续。
   动态可执行文件的 fork 尚未支持（会返回 `-ENOSYS`）。
4. **主程序布局**：`__PAGEZERO` 必须是 4GB、`__TEXT` 在 `0x100000000`；缩小 pagezero 会让
   `posix_spawn` 报 88（Malformed Mach-o）。
5. **16KB host 页**：固定映射地址、跳板岛必须 16KB 对齐。guest 按 4KB 页思考，
   两个 guest 映射可能共享同一个 host 页，所以改权限时不能动邻居（见上节第 4/5 条）。
6. **SP 16 字节对齐**：trampoline 第一条 `stp` 会触发 SP 对齐异常。
7. **TPIDR_EL0 不可依赖**：XNU 会在中断返回时把它重置成自己的值，必须用影子变量
   `GuestTlsPointer` + 改写所有 `mrs/msr tpidr_el0` 来模拟。
8. 改写代码页后必须 `sys_icache_invalidate`。
9. 打包最后一步 `codesign` 必须带 `--entitlements`，否则权限被剥掉。

## 构建

推送到 `main` 后，GitHub Actions 在 `macos-15-intel` 上：

1. 下载 Alpine 3.20.3 aarch64 minirootfs（只取 musl/libapk/libcrypto/libssl/libz + `apk`/`busybox`）
2. `xcodegen generate`
3. `xcodebuild` 无签名构建（`Probe`、`LiveProcess`、`ProbeHelper`、`GuestRunner`）
4. 复制 helper、`Tools/busybox.static`、`Tools/pie-hello`、Alpine 运行时进 `.app`
5. `ldid` + `codesign --entitlements` 预签
6. 产出 `LinuxProbe.ipa` / `LinuxProbe-unsigned.ipa`（artifact `LinuxProbe-ipas`）

版本号在 [project.yml](project.yml) 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`。

## 安装与使用

1. iPad 上用 TrollStore 覆盖安装 `LinuxProbe.ipa`。
2. 打开 App，点右上角 `...` 展开菜单：
   - **Run Probe**：历史能力探针（JIT / fork / `task_for_pid` / Mach 延迟）
   - **Run Fork Test**：手写 ELF 直接 `clone(SIGCHLD)`
   - **Run Shell**：`busybox sh -c` 跑 `ls/cat/uname/ls -l/id/pwd`
   - **Run BusyBox ls -l /**、**Run BusyBox**、**Run PIE Hello**
   - **Alpine BusyBox (dynamic)**：动态链接 Alpine busybox（M3.1 测试）
   - **Run APK --version**：动态链接 `apk`（M3.1 验收）
   - **Run APK Add Hello**：直接运行 `apk add --allow-untrusted /tmp/hello.apk`（M3.2 验收）
   - **Run Installed Hello**：直接运行安装后的 `/usr/bin/hello`（验证安装结果）
   - **Run APK Update (network)**：`apk --allow-untrusted update`（M3.3 验收）
   - **Install Bash (network)**：`apk add bash`
   - **Run Bash**：运行安装后的 `/bin/bash -c "echo bash ok; uname -a; id"`
3. 日志直接显示在 App 里。

关键日志：

```
[guest] before/after: flags=… debugged=0/1     JIT 状态
[guest] selftest=42                            匿名 RX 页可执行
[guest] island=0x…                             跳板岛
[guest] interp /lib/ld-musl-aarch64.so.1 …     动态链接器加载（0.35.0 起）
[guest] loaded … patched=N interp=0x…          主镜像 + 动态链接器补丁数
[guest] mmap elf off=… patched=… mrs=… msr=…   运行时库打补丁（0.35.0 起）
[guest] entry=… at_base=… at_entry=…           入口与 auxv
[guest] svc N site=0x… x0…x3 tls=0x…           syscall 调用点
[guest] socket family=… type=… -> N             新建 socket（0.38.0 起）
[guest] connect fd=N family=2 ok/errno=…        TCP/UDP 连接
[guest] unsupported syscall N                  缺 syscall
[guest] signal N addr=… pc=… lr=… far=… esr=…  进程内故障现场
[guest] alarm1/2/3 pc=…                        30s watchdog（最多 12 次）
```

网络层把 Linux 的 `sockaddr`（16 位 family）与 Darwin 的 `sockaddr`
（`sa_len` + 8 位 family）逐字段转换；`SOL_SOCKET` 是 1 vs `0xffff`；
`EAGAIN`/`EINPROGRESS`/`ECONNREFUSED` 等 errno 数值也全部翻译。
每个 socket 都设置 `SO_NOSIGPIPE`，并把 guest 的 `MSG_NOSIGNAL` 丢弃。

## 目录

```
project.yml                     XcodeGen 工程定义
.github/workflows/build.yml     CI（含 Alpine 运行时下载）
App/                            宿主 App（ProbeViewController、GuestLauncher）
Guest/GuestRunner.m             ★ ELF 加载器、PT_INTERP、svc/TLS 改写、syscall 分发、fork 快照
Shared/                         Mach / 通道常量
LiveProcess/                    NSExtension 探针（历史遗留）
Helper/ProbeHelper.m            能力探针
Tools/busybox.static            自建 glibc static-PIE busybox 1.36.1
Tools/pie-hello                 glibc static-PIE 最小程序
tools/make_guest_elf.py         生成最小 aarch64 ELF
tools/make_fork_elf.py          生成 fork 测试 ELF
```

## 路线

- **M1（完成）**：原生执行最小 ELF。
- **M2（完成）**：真实 static-PIE busybox。
- **M2.5（完成）**：rootfs + shell + 外部命令 fork/exec。
- **M3.1（已完成）**：`PT_INTERP` + musl ld.so，`apk --version` 已通过。
- **M3.2（已完成）**：Alpine rootfs + 本地 `apk add`，0.37.1 真机通过。
- **M3.3（进行中）**：网络 + `apk update`（socket/poll/TLS），0.38.0 待真机。
- **M4**：性能基准、syscall 特化、fork 快照优化、交互终端、常用工具验证。

详细任务和验收标准见工作区仓库的 `docs/ROADMAP.md`。

## 说明

- 使用私有 API，仅用于个人设备，不能上架。
- 不 boot Linux 内核，不支持内核模块 / systemd。
- 不支持 x86。
- 参考项目：iSH / ios-linuxkit / LinuxRunner（解释器路线）、
  [Kernarium](https://github.com/imxieyi/Kernarium)（原生 UML 内核 + 解释器用户态）、
  [Nyxian](https://github.com/emexlab/Nyxian)（沙盒内的用户态微内核 + Mach-O）。
  本项目只做 guest 用户态的原生执行，不复制它们的代码。
