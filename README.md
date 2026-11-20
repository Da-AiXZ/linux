# Linux Probe

在 iPadOS 上跑 Linux 环境的可行性验证工程。当前是第一里程碑：用真机把后续架构依赖的硬约束测出来，避免在错误路线上投入。

目标设备：**iPad Pro 2021（M1，arm64e），iPadOS 16.6.1**。

## 这一版做什么

宿主 App 通过私有 `NSExtension` API 启动一个内嵌的 `LiveProcess.appex` 扩展进程，再通过 Mach 消息把探测任务交给它。扩展进程会测：

- NSExtension 进程能否启动，真实 pid 是多少
- Mach send right 能否通过 `NSExtensionItem` 传递
- 宿主能否从 audit token 拿到调用者的真实 pid（防伪造）
- Mach 消息往返延迟（后续 syscall broker 的性能上限）
- `fork` / `posix_spawn` 在扩展进程里是否可用
- `task_for_pid` 对自己、对宿主是否可用
- 匿名页 `mmap(RW) -> mprotect(RX) -> 执行` 是否成功
- `MAP_JIT` 是否可用
- 文件系统可写范围、内存上限、fd 上限

结果以 JSON 形式分阶段通过 Mach 消息回传，显示在 App 里。即使某个危险探测让扩展进程崩溃，前面的阶段也已经写进日志。

## 构建

推送到 `main` 后，GitHub Actions 会自动在 `macos-15` 上：

1. `xcodegen generate`
2. `xcodebuild` 无签名构建
3. `ldid` 写入探测 entitlements，打包 `LinuxProbe.ipa`
4. 上传 artifact `LinuxProbe-ipa`

也可以在 Actions 页面手动 `workflow_dispatch`。

## 安装

iPadOS 16.6.1 推荐 **TrollStore 2**（TrollInstallerX）：

1. 在 iPad 上安装 TrollStore 2。
2. 从 Actions 最近一次运行下载 `LinuxProbe-ipa`。
3. 用 TrollStore 打开 `LinuxProbe.ipa` 安装。

备选：AltStore / Sideloadly。免费开发者证书通常只带 `get-task-allow`，`increased-memory-limit` 可能不生效，但探测仍可运行。

## 运行

打开 **Linux Probe**，点 **Run Probe**。日志会分阶段出现：

- `stage=device`：设备、内存、fd、沙箱可写范围
- `stage=process`：`fork` / `posix_spawn` / `task_for_pid`
- `stage=mach`：Mach 往返延迟
- `stage=jit`：RX/JIT（最后执行；如果崩溃，前面阶段仍在）
- `done`：全部完成

如果 `stage=process` 没出现，说明 `fork` 或 `posix_spawn` 直接把扩展进程带崩了，这本身也是结论。

重点看这几项：

| 字段 | 含义 | 对路线的影响 |
|---|---|---|
| `process.fork` | `-1` 表示无 fork | 需要 extension-per-process + 进程表模拟 |
| `process.posixSpawn` | 非 0 表示不能 spawn | 同上 |
| `process.taskForPidHost` | `0` 表示能拿宿主 task port | 能省掉 breakpoint 交接；否则要实现交接 |
| `process.taskForPidSelf` | 自己 task port | 一般应为 0 |
| `jit.mprotectRX` | `true` 表示匿名页可执行 | RX 开放，ELF 直跑/JIT 改写可行 |
| `jit.execResult` | `42` 表示真的执行成功 | 关键判定 |
| `jit.mmapJIT` | `true` 表示 MAP_JIT 可用 | 另一条 JIT 路径 |
| `mach.microsecondsPerRoundTrip` | 单次 Mach 往返耗时 | 决定 syscall broker 的性能上限 |

判定逻辑：

- `mprotectRX=true` 且 `execResult=42`：可以在扩展进程里跑任意 arm64 代码。优先走 **ELF loader + 加载时改写 `svc` + 跨进程 syscall broker**，能直接吃 Debian/Alpine arm64 包。
- 只有 `mmapJIT=true`：需要确认 JIT entitlement/调试器附加是否在扩展进程里也生效；可行的话同样走 ELF 路线。
- 两者都不行：走 **Mach-O 用户态** 路线，用 arm64 Mach-O 重新构建 Linux 工具链和包，CPU 仍是原生速度，但包体系是自建的。
- TrollStore 安装时 `allow-jit` 不一定生效。如果 `mprotectRX=false` 且 `mmapJIT=false`，可以用 AltStore/SideStore 的 JIT 功能再测一次，或者在有 Dopamine 等越狱环境时复测。
- `taskForPidHost != 0`：需要实现 Nyxian 式的 breakpoint 异常端口交接，才能读写 guest 内存。

## 路线

- **M0（本仓库当前）**：真机探针，确定 RX/JIT、进程模型、Mach 延迟。
- **M1**：Mach syscall server + 虚拟进程表 + task port 交接；跑通一个最小的 guest Mach-O payload。
- **M2**：Linux ABI 层（先 arm64、musl、静态 busybox），实现 10–20 个核心 syscall。
- **M3**：rootfs + `dpkg`/`apt`（自建包或 Debian arm64，取决于 M0 结果）。

## 说明

- 使用私有 API，仅用于个人设备，不能上 App Store。
- 代码是独立实现，没有复制 Nyxian 的源码；Nyxian 仅作为架构参考。
- iOS 16.6.1 没有 Hypervisor.framework，因此本工程不尝试虚拟机，只做用户态进程/ABI 层。
