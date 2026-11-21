# Linux Probe

在 iPadOS 上以**原生速度**运行 Linux 用户态的实验工程。

目标设备：**iPad Pro 2021（M1，arm64e），iPadOS 16.6.1**，通过 **TrollStore 2** 安装（不上架 App Store）。

不是虚拟机，不是模拟器，不是解释器：guest 是 arm64 Linux ELF，指令由 M1 直接执行；
只把 `svc #0` 改写成 `bl`，跳进自建的 syscall 分发器。

## 当前状态

| 阶段 | 状态 |
|---|---|
| M1 原生 ELF 执行 | ✅ `hello from linux elf`，`status=0` |
| M2 真实 busybox | 🚧 static-PIE busybox 已能加载（`patched=297`），正在解决 glibc 启动阶段的问题 |
| M3 Alpine / Debian rootfs | ⏳ |

最新版本 **0.19.0 (33)**。项目上下文、决策和路线记录在
[Da-AiXZ/linux-workspace](https://github.com/Da-AiXZ/linux-workspace)（私有）。

## 工作原理

```
Probe.app（宿主）
  │  posix_spawn + 管道
  ▼
Helpers/guest-runner <elf> [guest argv...]
  ├─ ptrace(PT_TRACE_ME) → CS_DEBUGGED（TrollStore 环境下可用）
  ├─ 读取 ELF，按 16KB 页对齐映射到 4GB 以上（ET_DYN / static-PIE）
  ├─ 扫描可执行段，把每条 svc #0 改写为 bl 跳板岛
  │     跳板岛: ldr x16, #8; br x16; .quad GuestSyscallTrampoline
  ├─ 构造 argv/envp/auxv（AT_PHDR、AT_PHNUM、AT_RANDOM、AT_HWCAP…）
  └─ GuestJump(entry, 16 字节对齐的 sp)
         ▼
   guest arm64 指令直接在 M1 上执行
   遇到 syscall → trampoline → GuestSyscallDispatch（宿主 syscall）
```

## 实测约束（决定架构的关键）

1. **JIT**：`MAP_JIT` 不可用；`dynamic-codesigning` 在 A12+/iOS 15+ 会闪退。
   用 `ptrace(PT_TRACE_ME)` 获得 `CS_DEBUGGED`。**不要用 `PT_SIGEXC` + 自建 Mach 异常端口**：
   实测（0.16.7/0.16.8）端口注册成功但收不到 guest 故障，进程静默 `status=1`；
   故障诊断用 POSIX `sigaction`（0.16.9 起，打印 `pc/lr/sp/far/esr` 与 `fault offset`）。
2. **4GB 以下不可映射**：64 位进程 `VM_MIN_ADDRESS = 0x100000000`，`VM_FLAGS_OVERWRITE` 也不行。
   guest 必须是 **ET_DYN / static-PIE**（Alpine 官方 `busybox-static` 是 ET_EXEC，不能用）。
3. **主程序布局**：`__PAGEZERO` 必须是 4GB、`__TEXT` 在 `0x100000000`；缩小 pagezero 会导致
   `posix_spawn` 报 88（Malformed Mach-o）。
4. **16KB 页**：固定映射、`mprotect`、跳板岛地址都必须 16KB 对齐。
5. **SP 16 字节对齐**：trampoline 第一条 `stp` 会触发 SP 对齐异常。
6. 改写代码页后必须 `sys_icache_invalidate`。
7. 打包最后一步 `codesign` 必须带 `--entitlements`，否则权限被剥掉。

## 构建

推送到 `main` 后，GitHub Actions 在 `macos-15-intel` 上：

1. `xcodegen generate`
2. `xcodebuild` 无签名构建（`Probe`、`LiveProcess`、`ProbeHelper`、`GuestRunner`）
3. 复制 helper 与 `Tools/busybox.static` 进 `.app`
4. `ldid` + `codesign --entitlements` 预签
5. 产出 `LinuxProbe.ipa` 和 `LinuxProbe-unsigned.ipa`（artifact `LinuxProbe-ipas`）

版本号在 [project.yml](project.yml) 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`。

## 安装与使用

1. iPad 上用 TrollStore 覆盖安装 `LinuxProbe.ipa`。
2. 打开 App，三个按钮：
   - **Run Linux Test**：最小 ELF（`write` + `exit_group`）
   - **Run BusyBox**：`busybox uname -a`
   - **Run Probe**：历史能力探针（JIT / fork / task_for_pid / Mach 延迟）
3. 日志直接显示在 App 里。

关键日志：

```
[guest] before/after: flags=… debugged=0/1     JIT 状态
[guest] selftest=42                            匿名 RX 页可执行
[guest] island=0x…                             跳板岛
[guest] patch site=… word=0x94…                svc→bl 改写
[guest] loaded … base=… size=… patched=N      镜像映射
[guest] entry=… aligned=1 words=… argv0=…      入口
[guest] heap=0x…                               64MB guest 堆
[guest] svc N site=0x… x0=…                    syscall 调用点
[guest] stopped: signal=11 / thread N pc=…     父进程抓到的停止现场（0.17.0 起）
[guest] signalled: signal=9                    取证后父进程杀掉 guest
[guest] watchdog1/2: pc=… sp=…                 卡住时的现场
```

注意：`PT_TRACE_ME` 让 `guest-runner` 处于被调试状态，致命信号会**停住整个任务**，
所以进程内的 `sigaction`/watchdog 不会触发；现场由 App 侧
`waitpid(WUNTRACED)` + `task_for_pid` + `thread_get_state` 读取。

## 目录

```
project.yml                     XcodeGen 工程定义
.github/workflows/build.yml     CI
App/                            宿主 App（ProbeViewController、GuestLauncher）
Guest/GuestRunner.m             ★ ELF 加载器、svc 改写、syscall 分发、看门狗
Shared/                         Mach / 通道常量
LiveProcess/                    NSExtension 探针（历史遗留）
Helper/ProbeHelper.m            能力探针
Tools/busybox.static            自建 static-PIE busybox 1.36.1
tools/make_guest_elf.py         生成最小 aarch64 ELF
```

## 路线

- **M1（完成）**：原生执行最小 ELF。
- **M2（进行中）**：真实 busybox → 最小 rootfs + shell → 进程/线程/信号。
- **M3**：Alpine arm64 rootfs + `apk`（需要动态 ELF 加载），之后 Debian arm64 + `apt`。

详细任务和验收标准见工作区仓库的 `docs/ROADMAP.md`。

## 说明

- 使用私有 API，仅用于个人设备，不能上架。
- 不 boot Linux 内核，不支持内核模块 / systemd。
- 不支持 x86。
- 参考项目：iSH / ios-linuxkit / LinuxRunner（解释器路线）、
  [Kernarium](https://github.com/imxieyi/Kernarium)（原生 UML 内核 + 解释器用户态）。
  本项目只做 guest 用户态的原生执行，不复制它们的代码。
