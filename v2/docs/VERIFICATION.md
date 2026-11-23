# 验证状态（截至 2026-11-23 22:00）

这份文件只为回答一个问题：**哪些结论是真跑出来的，哪些只是编译通过。**
v1 的教训之一是"日志看着像证据，其实仪器本身坏了"，所以这里把仪器和结论分开写。

## 一、真跑（有进程、有退出码）

运行平台：**Windows x86_64**（本机），二进制由 zig 交叉编译成
`x86_64-windows-gnu`，代码与 CI 版本完全相同（唯一差异是测试里的 `pread()`
在 Windows 上走 `_lseeki64` + `_read`）。

| 项目 | 数量 | 结果 |
|---|---|---|
| 轨迹对拍 `basic/tight/wide` | 1300 个操作 | 全部通过，20 125 条断言 |
| 随机不变量 `--random 400 1` | 3 组 × 400 操作 | 通过，15 804 条断言 |
| 随机不变量 `--random 400 99` | 3 组 × 400 操作 | 通过，16 189 条断言 |
| ELF 装载 + 补丁（合成 ELF） | 2 段 / 3 个站点 | 通过，93 条断言 |
| 初始栈 argv/envp/auxv | 2 参数 / 2 环境变量 | 通过，156 条断言 |
| stub 机器码与汇编器逐字比对 | 4 条指令 + 2 个字面量 | 与 `zig cc -target aarch64` 输出完全相同 |
| **真执行 guest**：`hello`（aarch64 Linux，ET_DYN） | GitHub `macos-latest`（arm64），7 s | ✅ 打印 `hello from guest`，走完整装载→补丁→syscall→exit |
| **真机执行 guest**：同一份 `hello` | iPad（iOS 16.6.1，TrollStore），0.05 s | ✅ 打印 `hello from guest`（0.1.1）；退出码在 0.1.2 修好跳板偏移后复测 |
| 跳板偏移（`ldr` 字面量） | 汇编器 + 解码断言 | ✅ `58000090 580000b1 d61f0200 d4200000`，读 +16 / +24 |

断言内容包括：每一步之后"宿主视角"与"页表"逐页相等、永不重复 commit、
地址对齐与边界、`check()` 与保护位一致、`munmap` 后必然 `EFAULT`。

## 二、Python 层（不涉及编译产物）

| 项目 | 数量 | 结果 |
|---|---|---|
| 规范模型自身不变量 | 60 种子 × 300 操作 = 18 000 | 通过 |
| 模型 ↔ C 逐行转写（轨迹） | 1300 | 0 差异（返回值 + 页表哈希） |
| 模型 ↔ C 逐行转写（边界模糊） | 200 种子 × 200 操作 = 40 000 | 0 差异 |

注意：这 40 000 次是 **Python 对 Python** 的差分，不是编译产物跑出来的。
它的作用是发现"语义转写错误"，不能替代真跑。

## 三、只编译，未运行

| 目标 | 用途 | 状态 |
|---|---|---|
| `aarch64-linux-musl` | 真机/guest 架构 | 编译通过，`-Werror -Wshadow` 零告警 |
| `x86_64-linux-musl` | GitHub Actions ubuntu | 编译通过，零告警 |
| `aarch64-macos` | GitHub Actions macOS / 桌面真跑 | 编译通过，零告警 |

这三项目前**没有运行记录**。Windows 跑不了 ELF 和 Mach-O，交叉编译只能证明
"类型、头文件、POSIX 调用在目标平台上能编过"，不能证明运行期行为。

## 四、完全没有验证

- iOS 真机（`ptrace` / `CS_DEBUGGED` / `posix_spawn` 限制）
- macOS / Linux 上的实际运行（等 CI 或桌面）
- 大内存、长时间运行、多线程
- ELF 装载器、补丁、跳板、syscall 层（还没写）

## 五、怎么复现

```bash
cd F:/wb-workspace/linux/v2
export ZIG_GLOBAL_CACHE_DIR=F:/tools/zig-cache
Z=/f/tools/ziglang/ziglang/zig.exe
$Z cc -target x86_64-windows-gnu -std=c11 -O1 -g -Iinclude \
      -Wall -Wextra -Werror -Wshadow \
      -o build/test_vspace.exe src/vspace.c tests/test_vspace.c
./build/test_vspace.exe --trace tests/trace/basic.tsv tests/trace/tight.tsv tests/trace/wide.tsv
./build/test_vspace.exe --random 400 1
```

CI（`.github/workflows/v2-core.yml`）在 push 后会在 `ubuntu-latest` 与
`macos-latest` 上跑同一份测试；届时第三节的三个目标会第一次变成"真跑"。
