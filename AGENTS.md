# AGENTS.md

代码仓库。项目背景、当前卡点、决策与路线在私有工作区
[Da-AiXZ/linux-workspace](https://github.com/Da-AiXZ/linux-workspace)，动手前先读那里的
`docs/STATUS.md` 与 `docs/DECISIONS.md`。

## 构建与验证

没有本地 Xcode。所有构建走 GitHub Actions：

```bash
# 改完并 push main 后
gh run watch <run-id> --exit-status
gh run download <run-id> -n LinuxProbe-ipas -D /workspace/dlN
unzip -p /workspace/dlN/LinuxProbe.ipa Payload/Probe.app/Info.plist | plutil -p -
```

交付给用户时：复制成 `/workspace/LinuxProbe-X.Y.Z.ipa`，给出 `computer://` 链接和 sha256。

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
- 不要缩小 `__PAGEZERO`，不要给主程序设置 `-pagezero_size`（`posix_spawn` 会报 88）。

## Guest 运行时不变量（`Guest/GuestRunner.m`）

1. guest 必须是 **ET_DYN / static-PIE**；iOS 不允许映射 4GB 以下。
2. 固定映射与 `mprotect` 一律 16KB 对齐（M1 iPad 页大小）。
3. guest 初始 `sp` 必须 16 字节对齐。
4. 改写代码页后调用 `sys_icache_invalidate`。
5. `svc #0` 改写目标：镜像附近的跳板岛（`ldr x16,#8; br x16; .quad trampoline`），
   由跳板岛绝对跳转，避免 `bl` ±128MB 限制。
6. 入口栈上的 argv/envp/auxv 必须完整（`AT_PHDR/AT_PHNUM/AT_PHENT/AT_PAGESZ/AT_RANDOM/AT_HWCAP/AT_EXECFN/AT_ENTRY`）。
7. `brk` 返回**当前 break**，初始为堆起始；堆是预映射的 64MB。
8. syscall 返回必须保留 `x1–x17`、`TPIDR_EL0`、`NZCV`（glibc 依赖）。
9. JIT 只靠 `ptrace(PT_TRACE_ME)`；**不要**加 `PT_SIGEXC` + 自建 Mach 异常端口——实测收不到故障。
   故障诊断用 `sigaction`，输出 `addr/pc/lr/sp/far/esr` 与 `pc - base`。
10. `PT_TRACE_ME` 下进程处于被调试状态（`P_LTRACED`）：**致命信号会停住整个任务**，
    进程内的 `sigaction` 和 watchdog 都不会执行。现场必须由父进程
    `waitpid(WUNTRACED)` + `task_for_pid` + `thread_get_state` 读取（0.17.0 起，App 侧 `GuestLauncher`）。
11. **TPIDR_EL0 不可依赖**：XNU 会在中断/调度返回时把它重置成 0x4。装载时必须把 guest 里
    每条 `mrs xN, tpidr_el0` / `msr tpidr_el0, xN` 改写为 `bl` 到按寄存器号索引的 stub，
    读写影子变量 `GuestTlsPointer`；否则 glibc 第一次 TLS 访问就会崩。
12. TLS stub 的栈保存只用 `str x30, [sp, #-16]!` / `ldr x30, [sp], #16`；
    **不要**用 `ldp/stp ..., xzr` 形式（0.19.0 真机上会触发 SIGILL，ESR EC=0）。

## 调试

沙箱内可用交叉工具链反汇编 guest：

```bash
aarch64-linux-gnu-objdump -d Tools/busybox.static | less
# offset = pc - base（日志里有 base 和 pc）
```

App 日志的关键行含义见工作区 `AGENTS.md` 第 6 节。

## 当前优先级

1. 0.20.1 真机验证：`tls stubs: … code=…` 应打印出 `f81f0ffe …` 等字；
   若仍 `guest stopped: signal=4`，看 `guest thread 0 code:` 的第 5 个 word 到底是什么指令。
2. 通过 TLS 后再看新的故障 `pc - base`，继续定位 glibc 启动。
3. 若启动推进到文件/进程 syscall，补 `openat/newfstatat/getdents64` 等 + rootfs 映射。
4. 若 glibc 仍收敛不了，换 musl static-PIE 对照。

## 不要做

- 不要引入 QEMU / 虚拟机 / 解释器（用户已否决，性能目标不符）。
- 不要复制 LinuxRunner / iSH 的 GPL 代码。
- 不要为了让某个程序跑起来而加封禁 entitlement 或改动主程序 Mach-O 布局。
