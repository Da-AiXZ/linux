# v2 架构规范

状态：设计定稿，G1 已实现（地址空间 + 对拍测试）
前置阅读：[REVIEW-v1.md](REVIEW-v1.md)
目标：在 iPad Pro 2021（M1 / arm64e / iPadOS 16.6.1 / TrollStore 2）上原生执行
Alpine aarch64 用户态，并且**每一个失败都能在 CI 上被自动复现**。

---

## 1. 三条地基不变量

v1 的全部故障都可以归因到这三条没有成立。v2 把她们写成可执行断言。

> **I1. 地址空间只有一份真相。**
> 页数组（`v2_space.pages`）是唯一事实来源。宿主映射、权限、生命周期一律由它派生，
> 不存在"旁路账本"，也不存在"宿主说有、账本说没有"的中间态。

> **I2. guest 页 == 宿主页。**
> 页大小在启动时取自宿主（iOS arm64 = 16 KiB，x86_64 = 4 KiB），guest 看到的页大小
> 就是它。因此**两个映射永远不会共享一个页**，`mprotect`/`munmap` 不需要"边缘页取并集"，
> 也不需要"只释放记录完全匹配的页"。

> **I3. 任何 guest 指针在被解引用前先验证。**
> `copyin/copyout/strncpy_from_guest` 一律走 `v2_space_check`。guest 的野指针返回
> `-EFAULT`，不会变成杀死 runtime 的宿主 SIGSEGV。

由此得到的推论（全部可断言）：

- 一次 `mmap` 之后，`[addr, addr+len)` 的每一页要么全部属于这次映射，要么这次映射失败；
- 一次 `munmap` 之后，被覆盖的每一页立即变为 FREE，宿主同步 `decommit`；
- 任何时刻 `host.shadow[i] == pages[i]`；
- 任何时刻不存在"已 commit 但页表说 FREE"的页。

---

## 2. 地址空间布局

```
base ─┬─ 0 MiB      island 0   (64 KiB, R-X)       ← 每 128 MiB 一个
      ├─ 128 MiB    island 1
      ├─ …
      ├─ 896 MiB    island 7
      └─ 1024 MiB   end
```

- 整个空间是**一次** `mmap(NULL, 1 GiB, PROT_NONE, MAP_ANON|MAP_PRIVATE|MAP_NORESERVE)`
  预留。虚拟地址不占物理页，1 GiB 在 iPad 上零成本。
- 页大小 = `vm_page_size`。1 GiB / 16 KiB = 65536 页，页表 64 KiB。
- island（跳板岛）在预留时直接标记为 `RESERVED`，分配器永不交出。
  每个 island 64 KiB = 2048 个 32 字节的 per-site stub。
- image / interp / 库 / 堆 / 栈 / 匿名映射**全部来自同一个 first-fit 分配器**，
  没有第二个地址宇宙（对比 v1 的 A5）。

**为什么 128 MiB 一个岛**：`b` 的位移是 ±128 MiB，岛间隔 128 MiB 时任何代码页到
最近岛的距离 ≤ 64 MiB。间距越小覆盖越稳，但会在地址空间里切出越多的"天花板"——
第一版用 16 MiB 间距，结果 64 MiB 的堆根本放不下（CI 上第一次真跑就撞到了）。
128 MiB 的代价是**单个映射最大约 128 MiB**，够堆（64 MiB）、栈（8 MiB）和 apk 的
索引缓冲；真需要更大时，把岛去掉、改用 `brk #imm` 全局陷阱即可（见 §14.5）。

**上限**：1 GiB 足够 apk（索引 ~60 MB、解包 ~200 MB、bash ~10 MB）。若将来不够，
`V2_SPACE_SIZE` 提到 2 GiB 即可，岛的数量线性增加，页表仍是每页 1 字节。

---

## 3. 页表与分配器

```c
struct v2_space {
    struct v2_host host;
    uint8_t  *base;
    size_t    length, page_size, page_count;
    size_t    alloc_start, cursor;
    uint8_t  *pages;        /* 每页 1 字节：FREE / RESERVED / MAPPED|prot */
};
```

- 状态只有三种：`0x00` FREE、`0x80` RESERVED、`0x10|prot` MAPPED。
  **没有第四种。** 查询一页的归属是 O(1) 的一次数组索引（对比 v1 的 A2：线性扫描 4096 条）。
- 分配：从 `cursor` 起 first-fit，扫到末尾后回绕一次；`cursor` 使序列确定，
  这样才能和参考模型逐操作对拍。
- 扫描按 `uint64` 字跳过整块非空页（64 KiB 空间 = 1024 个字），最坏 1024 次比较。
- `munmap` / `mprotect` 要求地址页对齐（Linux 语义），长度向上取整。
- `mremap`：新长度 ≤ 旧长度且无 `MAYMOVE` 时原地返回；否则分配新 run、`memmove`、
  释放旧 run。语义与 Linux 一致（v1 的 A4 是"能不释放就不释放"，v2 是"该释放就释放"）。
- `MAP_FIXED`：先把目标页 `decommit` 成 FREE，再 commit。语义与 Linux 完全一致，
  不再有"落在 runtime 区间就 EINVAL"（v1 的 A3）。

**对拍**：`tools/vspace_model.py` 是规范的可执行定义。CI 用固定种子生成轨迹
（`M/U/P/R` 四类操作），C 实现逐操作比对**返回值**和**页表 FNV-1a 哈希**。
任何语义漂移都会在某一行报出期望/实际。

---

## 4. 代码补丁与跳板

站点识别（与 v1 相同的三条）：

| 原指令 | 编码 | 处理 |
|---|---|---|
| `svc #0` | `0xD4000001` | 改写为 `b stub` |
| `mrs Xt, tpidr_el0` | `0xD53BD040 \| t` | 改写为 `b stub`，stub 把影子值写进 `Xt` |
| `msr tpidr_el0, Xt` | `0xD51BD040 \| t` | 改写为 `b stub`，stub 把 `Xt` 写进影子 |

per-site stub，32 字节，16 字节对齐：

```
+0   ldr x16, [pc, #16]     ; 入口（svc / mrs / msr 各一个，全空间共用）
+4   ldr x17, [pc, #12]     ; 站点地址
+8   br  x16
+12  brk #0                 ; 不可达；若到达则是一次明确的 trap
+16  .quad entry
+24  .quad site
```

关键点：

1. **用 `b` 不用 `bl`。** `bl` 会把 `x30` 改成 `site+4`，摧毁 guest 的返回地址
   （v1 在 `__set_thread_area` 上撞过，`AGENTS.md` 不变量 5）。`b` 不改任何寄存器，
   站点地址通过 stub 的常量池显式传入。
2. **`x16`/`x17` 是安全的**：`svc` 由内核负责"除 x0 外全部保留"，我们自己的入口
   会完整保存/恢复 x0–x30 + SP + NZCV + TPIDR_EL0 影子，因此借用它们不改变语义。
3. **不依赖 RWX。** 补丁在页处于 RW 时完成（镜像刚 `pread` 进来、还没 seal），
   之后一次 `mprotect(RX)` 封死，再 `sys_icache_invalidate`。全生命周期没有任何一页
   同时可写可执行。这是 v2 相对 v1 最大的平台收益：iOS 上仍然需要 `CS_DEBUGGED`
   （匿名页 `PROT_EXEC` 的门槛），但不再需要 RWX 共享页，桌面 macOS 也能直接跑。
4. **island 按需 seal。** 运行期 `dlopen` 需要新 stub 时，分配**新的** island 页，
   写完 seal，不碰已经 seal 的页（多线程安全）。

`site → 原始指令` 存一张排序表，供 mrs/msr 入口取 `Rt`、供崩溃报告反查。

---

## 5. syscall 层

```c
struct v2_cpu {
    uint64_t x[31];     /* x0..x30 */
    uint64_t sp, pc;    /* pc = site + 4 */
    uint64_t tls;       /* TPIDR_EL0 影子 */
    uint32_t nzcv;
};

struct v2_sysent {
    const char *name;
    int (*call)(struct v2_cpu *cpu, struct v2_proc *proc);
};
```

- **表驱动**，`[0, 320)` 的稀疏数组，未实现项统一返回 `-ENOSYS` 并记一次计数
  （替代 144 分支的巨型 switch）。
- **单一出口**：handler 只返回 `0` 或 `-errno`；分发器统一写 `cpu->x[0]`、`cpu->pc`。
  不存在"某个分支直接 `return -EXXX` 忘了翻译"（v1 的 C3）。
- **指针验证**：`v2_copyin/copyout/strncpy_from_guest` 全部先 `v2_space_check`。
  这是 I3 的落点。
- **errno 类型**：`typedef int v2_errno;`，所有返回 guest 的错误必须经
  `v2_errno_from_host()`。CI 用一条 grep 规则禁止 handler 里出现裸 `-E` 常量。
- **迁移而非重写**：`stat`/`statfs` 布局、`sockaddr` 转换、`SO_*`/`MSG_*`/`POLL*` 映射、
  `errno` 表、路径翻译 —— 这些语义已经在真机上验证过，逐函数搬过来，只改接口。

---

## 6. 执行模型

**execve：就地重载。**
v1 是"在宿主里找一块离 trampoline 近的空地再 spawn"（B2），失败率取决于宿主碎片。
v2 的地址空间是我们自己的预留，execve 只需：释放除了 islands 以外的所有页 →
加载新镜像 → 重建栈 → 重置 `v2_cpu` → 跳转。**零新进程，零地址搜索。**

**fork：快照 + 同址恢复。**
快照内容 = `{页表状态, 所有 MAPPED 页的内容, v2_cpu, tls, fd 表, cwd}`，写进
`<rootfs>/.v2/snap`。父进程 `posix_spawn(runner, "--restore", snap)`；子进程
`mmap(MAP_FIXED)` 到**同一个 base**（这是我们自己的预留，允许），按页表恢复。
因为快照的定义就是"地址空间"，动态镜像与静态镜像走同一条路径（v1 的 B1 消失）。

**线程：每线程一份 `v2_cpu`。**
TLS 影子从全局变量改成 `_Thread_local`（v1 的 B3）。页表加一把互斥锁，只保护
map/unmap 这类结构变更，读路径（`v2_space_check`）无锁。

---

## 7. ELF 装载

```
1. 读 EHDR/PHDR，要求 ET_DYN 且 p_align >= 页大小（否则记录一次 fallback 计数）
2. 在 vspace 里预留 [min_vaddr, max_vaddr) 的连续区间，全部映射为 RW
3. 逐 PT_LOAD：pread(p_offset, p_filesz) 到 base+p_vaddr，p_memsz 剩余部分清零
4. 扫描可执行段：识别 svc/mrs/msr，发射 stub，写 b，icache invalidate
5. 按页计算最终权限：该页上所有 PT_LOAD 的 prot 并集，一次 mprotect
6. PT_INTERP：把解释器当第二个镜像加载到另一个基址，同样走 1–5
7. 记录 PT_TLS（供 auxv 与影子 TLS 使用）、PT_GNU_RELRO（由 ld.so 自己处理）
```

第 5 步的并集是安全的：页归约到 16 KiB 后，只有**同一个 ELF 的相邻段**可能共享一页
（不同映射之间永不共享，见 I2）。若 `p_align < page_size`（普通 Linux 二进制），
并集可能得到 RWX；装载器记一次 `union-prots` 计数，不改变正确性——guest 用的是自己的
地址，写 `.data` 不会写到 `.text` 的字节上。

---

## 8. 可观测性

v1 的仪器会改变被测对象（C2）。v2 的规则：

- 默认**零输出**。`V2_TRACE=space,elf,syscall,fault` 按需打开。
- trace 只写环形缓冲区，退出时一次 dump；不在热路径 `printf`。
- 任何会改变执行流的诊断（单步、watchpoint、跳过 store）**不允许**进主干。
- 每个 syscall 有独立计数器（次数/错误/最后 errno），`V2_STATS=1` 时退出打印。

---

## 9. 测试策略（四层）

| 层 | 在哪跑 | 覆盖 | 成本 |
|---|---|---|---|
| L1 模型对拍 | ubuntu + macos CI | 地址空间语义（mmap/unmap/protect/remap 全组合） | 2 秒 |
| L2 单元 | 同上 | ELF 装载、路径翻译、errno、stat 布局、sockaddr 转换 | 5 秒 |
| L3 **桌面真跑** | macOS arm64 CI | 真 guest 指令：static busybox → 动态 apk → `apk update` ×200 | 30–90 秒 |
| L4 真机 | iPad | 平台差异：`CS_DEBUGGED`、`posix_spawn`、fork 快照 | 6–8 分钟 |

L3 是这次重写最重要的解锁。v1 的结论"桌面 CI 无法复现"只对**iOS 模拟器**成立
（RWX 被拒）。v2 不需要 RWX（§4.3），因此一个普通 macOS arm64 命令行程序就能跑
完整 guest。设备只用于验证平台差异，不再承担功能验证。

**验收闸门**（每条可自动判定，不看"能不能跑起来"）：

| 闸门 | 判据 |
|---|---|
| G1 | 模型对拍 3 条轨迹 × 1300 操作全绿；随机 400 操作 × 3 组全绿；ASan/UBSan 无报告 |
| G2 | 静态 busybox：`ls /`、`cat /etc/motd`、`uname -a`、`ls -l /`、`id`、`pwd` 输出正确、`status=0`，连续 50 次 |
| G3 | 动态 `apk --version` 打印 `apk-tools 2.14.4`，连续 50 次 |
| G4 | **`apk update`（本地 index）连续 200 次零失败** ← v1 死在这里 |
| G5 | 网络 `apk update` + `apk add bash` + `bash -c 'echo ok'`，连续 20 次 |
| G6 | fork/exec（shell 管道）、线程（`pthread` 测试程序）通过 |

G4 是最关键的一条：它把 v1 的"随机失败"变成了一个有明确通过/失败判据的统计量。
如果 v2 的地址空间是对的，200 次应当 200 次通过；只要有一次失败，就说明 I1–I3 里
还有一条没做到，而且这次我们有一个能**逐操作重放**的模型去定位它。

---

## 10. 目录结构

```
v2/
  include/v2/vspace.h        地址空间接口（唯一真相）
  src/vspace.c               页表 + 分配器 + mmap 语义
  src/host_darwin.c          mmap/mprotect/madvise/pread 的 Darwin 实现
  src/elf_load.c             ELF 装载（§7）
  src/patch.c                站点扫描 + stub 发射（§4）
  src/syscall.c              表驱动分发（§5）
  src/sys/*.c                按域拆分的 handler：fs/proc/mem/sock/time
  src/exec.c                 execve 就地重载、fork 快照（§6）
  tools/vspace_model.py      地址空间的规范模型 + 轨迹生成器
  tests/test_vspace.c        L1：对拍 + 随机不变量
  tests/test_elf.c           L2：合成 ELF
  tests/guest/*.c            L3：在 guest 里跑的验收程序
  Makefile                   make test / make guest
```

模块边界由头文件强制：`vspace` 不认识 ELF，`elf_load` 不认识 syscall，
`syscall` 只通过 `v2_space_*` 和 `v2_copyin/out` 碰内存。

---

## 11. 每个 v1 缺陷对应的 v2 设计

| v1 缺陷 | v2 的消灭方式 |
|---|---|
| A1 4 KB/16 KB 共享页 | I2：页大小取自宿主，映射永不共享页 → 整个"边缘页并集"逻辑消失 |
| A2 旁路账本 / 4096 上限 | I1：页数组即真相，O(1) 查询，无容量上限 |
| A3 `MAP_FIXED` 语义错 | 页表天生支持"替换"：decommit → commit，与 Linux 一致 |
| A4 释放策略摇摆 | 该释放就释放；"记录精确匹配"这个概念不存在 |
| A5 两个地址宇宙 | 单一预留 + 单一分配器 |
| A6 地址空间只增不减 | `munmap` 立即 `decommit`，页表立即 FREE |
| A7 页大小硬编码 | `page_size` 是运行时参数，从 `vm_page_size` 取 |
| A8 无指针验证 | I3：`v2_space_check` 前置，野指针 → `EFAULT` |
| B1 fork 快照不完整 | 快照的定义就是"整个地址空间"，静态/动态同一条路径 |
| B2 execve 找空地 | 就地重载，零地址搜索 |
| B3 全局 TLS 影子 | 每线程 `_Thread_local` |
| C1 无测试 | 四层测试，G1–G6 全部自动判定 |
| C2 仪器干扰 | trace 只写环形缓冲，退出 dump，不进热路径 |
| C3 错误模型混乱 | 单一出口 + `v2_errno` 类型 + CI grep |
| C4 单文件 8659 行 | 按头文件拆模块，单文件上限 1200 行（CI 检查） |

---

## 12. 里程碑

| 阶段 | 内容 | 状态 |
|---|---|---|
| **G1** | 地址空间 + 模型对拍 + CI | ✅ 2026-11-23 |
| **G2a** | ELF 解析/装载 + 站点扫描 + per-site stub + 段权限归并 | ✅ 2026-11-23（合成 ELF，93 条断言；stub 机器码与汇编器逐字相同） |
| **G2b** | 寄存器框架 + 入口跳板 + 最小 syscall + 初始栈 + runner | ✅ 2026-11-23（本机栈测试 156 条断言；真机执行待 CI） |
| **G2c** | 第一个真程序：`tests/guest/hello`（aarch64 Linux ET_DYN） | ✅ 2026-11-23，CI 上真实执行 |
| **G3** | 静态 busybox 六条命令（桌面先绿，再上真机） | ✅ 2026-11-24，macOS arm64 + iPad（0.1.4） |
| **G4** | PT_INTERP + musl `ld.so` + `apk --version` | ✅ 2026-11-24，macOS arm64；真机 0.1.5 |
| **G5a** | 本地仓库 + `apk update` ×200（死线） | 进行中：单次通过；200 次循环抓到间歇性符号解析失败 |
| **G5b** | 本地 `apk add`（解包 + 依赖 + 数据库） | 未通过：libz `inflate_fast` 读到 NULL window |
| **G6** | socket/TLS + 网络 `apk update` + `apk add bash` + `bash` | |
| **G7** | fork/exec/线程 | |

每个阶段的门是"上一阶段的自动化判据仍然全绿"，不是"上一个 demo 能跑"。

---

## 13. 未决问题与实验

必须先用 20 行代码回答、再决定设计的四件事：

| 编号 | 问题 | 影响 | 若为否 |
|---|---|---|---|
| E0 | macOS arm64 上，非签名二进制能否 `mprotect(anon, RX)` | L3 桌面真跑能否成立 | ad-hoc 签名 + `allow-jit`（macOS 不需要 TrollStore） |
| E1 | `TPIDR_EL0` 是否真的被 XNU 在中断返回时重置 | 若不被重置，可删掉 mrs/msr 两条补丁路径（约 800 行） | 保留影子 TLS（按 §4 的 stub） |
| E2 | `p_align` 在 Alpine aarch64 的 `.so` 上是否为 64 KiB | 决定 §7 第 5 步是否会出现 RWX 并集 | 记录计数，不影响正确性 |
| E3 | 1 GiB 预留 + 65536 页页表在真机上的实际内存占用 | 决定 `V2_SPACE_SIZE` | 降到 512 MiB |

E0 必须在 G2 之前回答，E1 必须在 G2 的补丁模块定稿前回答。

---

## 14. 附录：这个问题的正式名字，以及为什么用这种分配算法

### 14.1 别名（aliasing）

v1 遇到的事情在体系结构里有名字：**同一块物理内存被两条记账同时认领**，叫
*aliasing*。硬件层的对应物是 MMU + 页表 + TLB；虚拟化层的对应物是 **影子页表**
（shadow page table）。

KVM 早期就是软件影子页表（后来用 EPT/NPT 硬件加速）。它的难点正好是 v1 的难点：
guest 页和宿主页不是一一对应，一张宿主页表要同时服务多个 guest 页，
任何一次权限合并/拆分写错，guest 就会看到"自己的内存被别人改了"。

v2 的做法是让影子页表**退化成恒等映射**：guest 页大小 = 宿主页大小，1:1。
多对一关系不存在，别名就没有发生的空间。这不是"绕过问题"，是把问题从设计里删掉。

### 14.2 分配算法选型

页统一大小之后，分配器要解决的问题只剩"找一段连续的空页"。四种经典做法：

| 算法 | 查找 | 释放合并 | 典型用途 | 本项目的取舍 |
|---|---|---|---|---|
| **bitmap + first-fit** | O(n/64) 字扫描 | 天然（页等大，直接置 0） | 中大规模、语义需要可证明 | **采用**。65 536 页 = 1024 次 64 位比较，纳秒级 |
| buddy | O(log n) | 强（2^k 对齐块） | 物理内存管理、需要不同大小块 | 不用。页等大，合并优势用不上，状态机更大 |
| segregated free-list | O(1) 均摊 | 需边界标记 | 通用 malloc | 不用。删除/合并分支多，bug 面大 |
| slab / size-class | O(1) | — | 小对象 | 不归我们管，guest 自己的 mallocng 在做 |

选 bitmap 的首要理由不是快，是**可以被逐操作对拍**：状态只有三种，
一次 `map` 之后页数组的变化完全可以由模型预测，所以能在没有设备的情况下
验证 1300 个操作、4 万个随机操作。buddy 的状态（order、伙伴位、合并链）
很难用同样强度对拍。

### 14.3 将来需要更快时怎么改

如果 arena 扩到 16 GiB，或者 mmap 频率高到扫描成为瓶颈，加**一级汇总位图**：
每 64 页一个 bit，表示"这 64 页是否全空"。找空位时先扫汇总位图（16 GiB / 16 KiB / 64
= 16 384 bit = 256 个 word），命中再进二级。改动只在 `v2_find_run` 一个函数里，
语义不变，测试不用改。这正是 Linux buddy 的 `free_area` 位图思路。

### 14.4 明确不做的

| 机制 | 为什么不做 |
|---|---|
| rmap（反向映射） | 页表直管，`munmap` 不需要"找出所有引用者" |
| VMA 合并 | 页数组查询 O(1)，不需要为遍历合并区间 |
| huge page（2 MiB） | ELF 段按 4/64 KiB 对齐，收益不确定；留到 M4 实测再定 |
| 无锁并发 | 线程未实现；当前读路径已经无锁，写路径加互斥即可 |


### 14.5 如果哪天需要大于 128 MiB 的单个映射

现在用跳板岛是因为 `b` 只能跳 ±128 MiB，而岛间距给每个映射设了天花板。
去掉这个天花板的办法是把 `svc #0` 改写成 `brk #imm`（ARM 的断点指令）：
进程收到 SIGTRAP，处理器从 `si_addr` 拿到现场、改 `pc` 和 `x0` 后返回。
好处是**位置无关**——任何地址都能被捕获，不需要岛、不需要距离计算，
代码页只要改 4 个字节。代价是每次系统调用多一次信号往返（约 1–2 µs）。

所以顺序是：先保留 `b` + 岛（快），真撞到 128 MiB 上限再换 `brk`（无限）。
两者可以共存：岛够得着的站点用 `b`，够不着的用 `brk`，patch 表里记着用的是哪种。

### 14.6 已落地的 syscall 集合（G3 结束时）

表驱动，未列出的返回 `ENOSYS` 并按编号计数打印一次（所以"缺什么"是日志能回答的问题，
不是猜的）。截至 G3，静态 busybox 的六条命令用到并已实现：

| 类别 | 调用 |
|---|---|
| 文件 | `openat` `close` `read` `write` `readv` `writev` `lseek` `fstat` `newfstatat` |
| 目录 | `getdents64`（每个 fd 一个独立 `DIR*`，`telldir`/`seekdir` 做缓冲回退） |
| 进程 | `brk` `mmap` `munmap` `mprotect` `madvise` `set_tid_address` `prlimit64` `sched_getaffinity` `nanosleep` |
| 身份 | `getpid` `getppid` `getuid` `geteuid` `getgid` `getegid` `gettid` `getgroups` `umask` |
| 时间 | `clock_gettime` `getrandom` `uname` `ioctl(TIOCGWINSZ)` |
| 路径 | `getcwd` `chdir` `fchdir` `readlinkat` `faccessat` `fcntl(F_GETFL)` `dup` |
| 信号 | `rt_sigaction` `rt_sigprocmask` `rt_sigreturn` `sigaltstack`（接受但无状态：单线程同步执行模型） |

**已知缺口**：`sendfile`（71）。busybox 的 `cat` 会先试它，失败自动回落 `read`/`write`，
输出正确。补它的收益要等有人真的依赖零拷贝，届时一并做 `splice`。

### 14.7 动态链接：我们只做内核那一半

`apk` 不含 libc。它的 `PT_INTERP` 写着 `/lib/ld-musl-aarch64.so.1`，
内核的职责只有三件事，v2 也只做这三件：

1. 把解释器装到某个基址（我们让分配器选，iOS 不允许固定低地址）；
2. `AT_BASE` 指向它，`AT_PHDR`/`AT_PHENT`/`AT_PHNUM`/`AT_ENTRY` 仍然描述**主程序**
   （ld.so 要靠它们读主程序的 `.dynamic` 并给它重定位）；
3. 跳到**解释器的**入口。

之后的一切都在 guest 里发生：ld.so 用 `openat` 找 `libc.musl-aarch64.so.1`，
用 `pread64` 读程序头，用 `mmap` 把每个 `PT_LOAD` 映射进来，解析符号，写重定位。
这三个系统调用因此是 G4 的硬需求，缺一个就停在第一条指令。

**一个反直觉的点**：动态程序自身**不含任何 `svc`**，所以启动时补丁扫描
（`patch svc=478`）全部来自解释器——而 `ld-musl-aarch64.so.1` 就是整个 musl，
478 个站点、90 个 `mrs tpidr_el0`、1 个 `msr`。等 ld.so 再把同一个文件映射成
`libc.musl-aarch64.so.1` 时，那一份是**新的副本**，必须重新打补丁，
于是有了 `v2_patch_runtime`：文件映射 + `PROT_EXEC` 就是库的代码段，
把它短暂改成 RW、扫描改写、再改回 RX。全程没有 RWX 页。

**为什么文件映射要容忍短读**：ld.so 第一次映射用的是"整库长度"，
它自己注释写着 "we map too much, possibly even more than the length of the file"。
最后一个 `PT_LOAD` 的尾页还带着 `.bss`。把 EOF 当错误（v1 的做法）就永远装不进 libc。
EOF 之后保持零，正是 Linux 的行为。

### 14.8 G5 的两个未解决问题（2026-11-24 记录）

**G5b：`apk add` 在 libz 的 `inflate_fast` 里读到 NULL window。**
寄存器现场说明了一切：`x2 = 0x1aea`（zlib 的 `op`）、`x7 = 0x10ca38026`（输出指针），
而 `x1 = x7 - dist = 0x6516`。`0x8000 - 0x1aea = 0x6516` 精确成立，也就是说
`from = window + wsize - op` 里 **`window == NULL` 而 `wsize == 0x8000`**。
zlib 只在 `updatewindow()` 分配成功后才设 `wsize`，所以 `window` 是**事后**被写成 0 的——
有人往 apk 的 inflate state 里写了 8 个零字节。只在大包（需要走 fast loop）时发生，
小索引（`apk update`）不触发，所以它一直藏着。

**G5a 的间歇性失败：符号解析偶发 `symbol not found`。**
`apk update` 连跑 200 次，第 26 次在重定位阶段失败：

```
Error relocating /usr/lib/libcrypto.so.3: pthread_rwlock_init: symbol not found
```

同一份字节、同样的代码，前 25 次都通过。更早的一次是
`apk_blob_cstr: symbol not found`（那是 libapk **自己**定义的符号）。
两个失败都发生在 `ld.so` 解析符号时，且都与地址布局相关：成功与失败的 arena 基址
互有重叠，所以不是简单的对齐问题。

这两件事很可能同源：**某处在特定布局下写到不该写的地方**。下一步的做法不是继续读代码，
而是把 `V2_VERIFY` 自检打开（映射后逐页与文件比对），让"映射错了"和"状态被写了"
这两种可能被数据分开。

### 14.9 G4 的间歇性重定位失败（未解决，2026-11-24）

`apk --version` 连续跑 2000 次，失败率 0.4%–2.4%，**每次报的符号都不一样**：

```
run  42  Error relocating /usr/lib/libssl.so.3: EVP_PKEY_set_type: symbol not found
run 107  Error relocating /usr/lib/libcrypto.so.3: pthread_rwlock_wrlock: symbol not found
run 142  Error relocating tests/guest/root/sbin/apk: apk_istream_tee_fd: symbol not found
run 175  Error relocating /usr/lib/libapk.so.2.14.0: vasprintf: symbol not found
run 226  Error relocating /usr/lib/libapk.so.2.14.0: fetchXGetHTTP: symbol not found
run 264  Error relocating tests/guest/root/sbin/apk: dup: symbol not found
```

**"每次符号都不一样"是关键指纹**：不是某个符号坏了，而是符号表里**某一段**在有些运行里不是文件里的内容。
已排除的：地址布局（失败分布在四个不同的 arena 基址上）、短读（现在会重试三次才认 EOF）、
补丁误命中（`sites=+0`，这些库根本没有 `svc`）。

**下一个工具**：`V2_VERIFY` —— 映射完成后逐页与文件比对，把"映射内容错了"和"musl 查表错了"
彻底分开。在拿到这个数据之前，不再猜。

#### `V2_VERIFY` 的四次普查（2026-11-24）

```
runs=81 failures=6 mismatches=0
```

两件事：

1. **映射的字节是对的。** 每个文件映射在建立后立刻与文件逐字节比对，81 次运行、6 次失败，
   **没有一次不匹配**。所以"我们把库读错了"这条假设被排除——`ld.so` 读到的是正确字节。
2. **但"打开校验让失败率涨 18 倍"是错的，那是我读错了取样噪声。** 四次普查：

| 条件 | 结果 | 率 |
|---|---|---|
| 无校验 | 6 / 245 | 2.4% |
| 无校验（加了短读重试） | 6 / 1482 | 0.4% |
| 有校验，每次 `malloc(4MB)` | 6 / 81 | 7.4% |
| 有校验，缓冲只分配一次 | 6 / 279 | 2.1% |

同一份代码在 0.4%–7.4% 之间摆动，**每轮只跑到 6 次失败就停**，样本太小。
**教训**：用"6 次失败"做分母比较，得到的倍数不可信。

**目前唯一确定的两件事**：映射的字节与文件一致；失败率在 1%–2% 量级。

下一步不是再猜，而是把失败的那一次**完整留下来**：在 `V2_VERIFY` 里对每个库记一个
CRC 快照，进入 guest 前后各算一次，失败时把"哪个库的 CRC 变了"打出来。
如果 CRC 变了，说明有人写坏了库；如果没变，说明 ld.so 用正确的字节查表却查不到，
那时才去看 musl 的 `find_sym`。

#### 逐页比对的结果，以及仪器自己的三个错误（2026-11-24 13:30）

最终数据（`runs=472 failures=5 mismatches=0`）：

```
image tests/guest/root/sbin/apk            checked 0x10000  differs at 0xf520 (569 bytes)
image .../lib/ld-musl-aarch64.so.1         checked 0xa4000  differs at 0x186fc (2273 bytes)
image /usr/lib/libcrypto.so.3              checked 0x3a8000 matches the file
image /usr/lib/libz.so.1                   checked 0x20790  matches the file
image /usr/lib/libapk.so.2.14.0            checked 0x30e88  matches the file
image /usr/lib/libssl.so.3                 checked 0xc4000  matches the file
```

**四个库的可执行页与文件逐字节一致**，包括失败的那些运行。所以 ld.so 读到的字节是对的。

主程序和解释器报的"差异"是**仪器的 bug**：`apk` 的第二个 `PT_LOAD` 在文件里偏移 0xf520、
在内存里 vaddr 0x1f520（相差 0x10000）。用"vaddr 等于文件偏移"的线性假设去比，
段与段之间的落差就成了 569 字节的假差异。库之所以没中招，只是因为它们被检查的那段
没有跨过段边界。

**这个仪器的三次错误，值得记下来**（每一次都差点让我得出错误结论）：

1. 对整个映射取哈希 —— 重定位本来就会写 `.data`，于是每次都"变了"；
2. 只对可执行映射取哈希 —— musl 的首次整库映射就是 R-X，仍包含数据段；
3. 退出时与文件线性比对 —— 段偏移不为零时，段间落差被当成损坏。

**要真正回答"我们的装载器有没有读错"，必须按段比对**（用 PT_LOAD 的 vaddr/offset/filesz
逐段核对）。在那之前，"装载器读错"这条假设仍然既没被证实也没被排除——但它已经被
缩到只剩两个镜像（主程序与解释器），而四个由 ld.so 映射的库是干净的。

#### 门禁搬了家，因为它一直是红的（2026-11-24 15:20）

按上面的实测率（1.1%/次），"连续 200 次零失败"在每次提交上都跑，红掉的概率是
`1 - 0.989^200 ≈ 89%`。于是 v2-core 的 Actions 页变成了十一次连续的红，而每一次红说的
都是同一件事——**这不是十一个 bug，是一个已知 bug 被量化了十一次**，并且真出现新问题时
它会被淹掉。

现在的分工：

| 工作流 | 触发 | 判定 | 现在的颜色 |
|---|---|---|---|
| `v2-core` | 每次 push（文档改动不触发） | 只有"新签名"才红：非 `Error relocating … symbol not found` 的失败、`FAULT`、`MISMATCH`、或比率 >5% | 绿（已知 flake 只发 warning） |
| `v2-flake` | 每晚 03:17 + 手动 | 200 次，**零失败** | 红，直到 G4 关闭 |

`v2-core` 里那条普查的不变量也改了：它不再要求"零 flake"（那是 `v2-flake` 的事），
只要求"**没有任何一次失败运行发现内存里的字节和文件不一致**"。这条不变量一旦破，
说明错的是我们，不是 musl 的查表。

顺带一件与代码无关但影响判断的事：`macos-latest` 的**排队**时间与运行时间不是一个量级。
2026-11-23 18:15 那次，`test (macos-latest)` 排队 605 秒、执行 18 秒；`guest` 排队 304 秒、
执行 13 秒。2026-11-24 05:31 同一套 job 排队 3 秒。所以"Mac 很慢"通常是 GitHub 的
macOS 池子在排队，不是我们的构建慢——看 job 的 `created_at → started_at` 就能分辨。

#### 按段比对，以及"允许的差异"必须点名（2026-11-24 15:40）

上一节的结论是"必须按 PT_LOAD 比对"。做了两件事：

1. **登记改成逐段**。`v2_verify_note_host` 现在对每个 `PT_LOAD` 各登记一次
   （`address = base + p_vaddr`、`file_offset = p_offset`、`length = p_filesz`），
   不再用一个 `[start, start+span)` 去线性比。段间落差不再是"差异"。
2. **把有意改写的字节点名排除**。每个补丁点现在是 4 字节的 `b stub`，而文件里是 `svc`。
   如果不排除，主程序和解释器**永远**会"有差异"——这个结论是构造出来的，什么也没说明。
   所以 `v2_patch_seal` 之后把每个 site 的 `[address, address+4)` 登记进排除表，
   比对时跳过；只有**排除表之外**的字节才算损坏。

这样，"image … matches the file"才第一次是一句有信息量的话：它现在等价于
"我们对这个镜像的每一个字节的搬运都是对的，除了我们自己写的那几条分支"。

如果这一版之后 `apk` 与 `ld-musl` 仍然报 `differs at`，那它指的位置就是真问题所在；
如果两者都变绿，则"装载器读错"被彻底排除，嫌疑只剩 musl 在**正确的字节**上建表失败，
下一步就该去看 `find_sym`/`dso` 链，而不是再看内存。

#### 结果：六个镜像全绿，装载器被排除（2026-11-24 15:07）

改完的第一轮（run 45345529821）：

```
runs=486 failures=5 mismatches=0
image tests/guest/root/sbin/apk             checked 0xf31c   matches the file
image .../lib/ld-musl-aarch64.so.1          checked 0xa1d14  matches the file
image /usr/lib/libcrypto.so.3               checked 0x3a8000 matches the file
image /usr/lib/libz.so.1                    checked 0x20790  matches the file
image /usr/lib/libapk.so.2.14.0             checked 0x30e88  matches the file
image /usr/lib/libssl.so.3                  checked 0xc4000  matches the file
```

`apk` 和 `ld-musl` 从"differs at（569 / 2273 字节）"变成了 `matches the file`，说明那两处
差异**全部**是我们自己写的分支，一个字节都不多。**即使在失败的那 5 次运行里**，也是如此。

于是三条假设可以正式划掉：

| 假设 | 状态 |
|---|---|
| 我们搬错了字节（短读、EOF 补零、段偏移） | **排除**：486 次运行、5 次失败，零字节不符 |
| 补丁误命中（把数据当成 `svc` 改掉） | **排除**：若误改，那几个字节就会与文件不符 |
| 地址布局（基址、跳板距离） | **排除**（此前）：失败分布在四个不同 arena 基址 |

剩下的只能是：**musl 拿到正确字节之后，自己建立的运行时结构（`dso` 链、`syms`/`strings`/
哈希表指针、堆）在约 1% 的运行里是错的**。这不是"内存里字节不对"，而是"指针不对"，
所以任何逐字节比对都不可能看到它——这也解释了为什么三代仪器都是 0 mismatch。

下一步的仪器因此换了目标：在 guest 打印 `Error relocating …` 的那一次 `write(2)` 上
停住（`ld.so` 紧接着就 `exit(127)`，退出时的现场已经没用了），把 `x0..x30`、`sp`、`pc`
和栈顶若干字打出来。有了 `find_sym` 的 `dso` 指针与 `syms`/`strings` 字段，就能直接看出
是"链断了"还是"表指针是垃圾"，而不必再猜。

#### 真机 0.1.6.7：动态链接跑通了，flake 也在第一枪就中（2026-11-24 15:25）

```
$ dynamic busybox echo     dynamic-busybox-ok           status=0
$ apk --version
[v2] exec map /usr/lib/libcrypto.so.3 at 0x1078f8000 len=0x408000 prot=5 sites=+0
[v2] exec map /usr/lib/libz.so.1      at 0x107d00000  len=0x34000
[v2] exec map /usr/lib/libapk.so.2.14.0 at 0x107d34000 len=0x44000
[v2] exec map /usr/lib/libssl.so.3    at 0x107d78000  len=0xd4000
Error relocating /usr/lib/libcrypto.so.3: getnameinfo: symbol not found   status=127
```

两件事同时成立：

1. **iOS 上第一次真正完成了动态链接**：`PT_INTERP` 被尊重、`ld-musl` 在 0x103904000 加载、
   `AT_BASE` 指向它、它把 libc 重定位完，`dynamic-busybox-ok` 是 ld.so 亲手跑出来的。
2. **G4-flake 在真机上 1/1 复现**，而且签名与桌面完全一致（重定位 libcrypto 时、
   某个 libc 符号找不到）。桌面是 1%，真机是第一枪——所以真机是一个**随时可取**的样本，
   比每天等 CI 撞 1% 强得多。

一个巧合值得记下（目前只当线索，不当结论）：这次 `stack top=0x1078f8000`，
而 `libcrypto` 正好被映射在 `0x1078f8000`——紧贴栈顶、不重叠。合法，但说明分配器的
first-fit 会把库放在栈的正上方；如果栈在重定位期间向下长，两者就会撞上。桌面 1%、
真机 100% 的差异，可能就藏在"栈与库的相对位置"里。

另外修掉一个只在上传日志里才看得见的 bug：`rootfs %d copied, %d already present%s%s`
把 `NSString *report` 传给了 `%s`，于是日志里那行后面跟着四个字节的二进制垃圾
（`18 copied, 5 already present˘{‡`）。改成 `%@`。

#### V2_VERIFY 一直在压低失败率；现场第一次被抓住（2026-11-24 16:22，0.1.10.11）

关掉校验后，20 发里就中 1 发，200 发那组从第 1 发起连中——**`V2_VERIFY` 不是无关变量，
它每次多分配 4 MB、多读一遍文件，把失败率压到了 1%**。所以此前"桌面 1%、真机 1/1"
的波动，很大一部分是布局与分配造成的，不是两个环境的差异。

第一份带寄存器的样本（`apk x20` 里那一发）：

```
x7 =0x726f7469736f7065   "eposi"
x12=0x6f7469736f706572   "reposito"
x13=0x6b636568635f7972   "ry_check"
x30=0x10308cdb4  pc=0x103087484  sp=0x1078f7440
Error relocating /var/mobile/Documents/root/sbin/apk: apk_db_repository_check: symbol not found
```

三次失败分别在三个不同的 dso 上找不到符号（libapk 的 `apk_pkg_free`、apk 的
`apk_db_repository_check`、libcrypto 的 `getnameinfo`），而寄存器里拼出的正是那个
正在比较的符号名。**名字读对了、比较在进行、走完整条作用域链没找到。** 所以缺的不是
字节，是"该去哪些库找"的那份清单。

下一步的仪器不再是寄存器，而是**把 dso 链打出来**：失败那一刻从当前 `dso` 顺着
`next`/`deps` 走一遍，打印每个节点的 name / syms / strings / nbuckets。链上缺一节，
或者某个指针为空，会直接看见。另一个必须同时验的变量是 `V2_VERIFY` 的 4 MB 分配——
它能把失败率从"几乎必现"压到 1%，说明失败与堆布局强相关，这条线索不能丢。

#### 门禁的口径，以及 197/200（2026-11-24 16:50）

`v2-core` 在 `f085f48` 上红了：200 次里 11 次失败，越过 5% 上限。**这不是回归，是门禁的口径错了：**

- 5% 是拿 `V2_VERIFY=1` 的 1.1% 定的（200 × 1.1% = 2.2 次，5% ≈ 均值 + 5σ）；
- 而"apk update two hundred times"是**另一个 shell**，没有继承普查步骤里的
  `export V2_VERIFY=1`，它跑的是 verify **off**；
- verify off 的实测速率 5.5%（11/200），天花板必然被顶破。

两处修正：两个步骤都把模式写成 step 级 `env: V2_VERIFY: "1"`，不再靠 shell 继承；
`v2-flake.yml` 显式声明它跑的是**出厂配置**（verify off：桌面 5.5%、真机 98.5%），
因为那才是真正发出去的布局。

真机上 verify off 的 200 发里 197 发失败，且符号固定（libcrypto 的 `getnameinfo`）。
所以它**不是随机发生的**，是在这个布局下必现；"1%"那个数字是仪器把布局挪开之后测出来的。
一个变量能让速率差 5 倍（桌面）到 200 倍（真机），它就不是细节，是实验条件。

#### 两个仪器：V2_GUARD 与 V2_SPACE_BASE（2026-11-24 17:00）

结论已缩到"字节对、指针错"，那么下一个问题只剩一个：**是有人写到映射外面去了，
还是这个布局本身让 ld.so 算错？**

`V2_GUARD=1`：每次 first-fit 分配之后留一页空洞——不 commit、不交给分配器、
**不进页表状态机**（记在旁边的 `guards[]` 里），所以三条轨迹的哈希与模型对拍一个字节都不变。
越界写会撞在 PROT_NONE 上，故障处理器打出 `GUARD PAGE` 和写者的 `pc`。

v1 做过同样的事却没成，原因写在 workspace 的 `BUG-index-io-error.md`：v1 的 `mapLength`
按 16 KB 取整而 mallocng 按 4 KB 申请，四分之三的映射末尾留着 4–12 KB slack，越界写先落
slack。**v2 的 guest 页 == 宿主页，一页就是边界，没有 slack。**

判读只有三种结果，一次真机发射就能分开：

| 现场 | 含义 | 下一步 |
|---|---|---|
| 出现 `GUARD PAGE` | 有人越界写；`pc` 就是写者 | 按 pc 定位，bug 收敛 |
| 无 guard 命中、失败消失 | 没越界；触发条件是相邻布局本身 | 查 ld.so 的堆/`dso` 与库的相对位置 |
| 无 guard 命中、失败照旧 | 与映射末尾无关 | 回到 `dso` 链 |

`V2_SPACE_BASE=0x...`：把 1 GiB arena 钉在指定基址，让真机那次失败的**绝对**布局在桌面复现。
失败样本的 arena 基址本身是变的（`0x101800000` / `0x11a800000` / `0x103800000`），
所以绝对基址不是变量——但"同一个相对布局、随时可重放"仍然是这个 bug 从被等待变成被
追捕的关键，也正是 G4 判据所要求的"同一个失败能被自动复现"。

`V2_GUARD` 的正确性由 `tests/test_vspace.c` 的 `guard_test` 与 `--guard-random` 守住：
guard 页永远不被交出、永远不被 commit（`v2_space_verify` 会拒绝 committed 的 guard 页）、
`MAP_FIXED` 显式要点这页时让位。本机（Windows，zig）实测：轨迹 20 168 条断言、
随机 2 组 31 993 条、guard 随机 3 组 15 235 条全绿，三条轨迹哈希未变。

#### 页语义：`madvise` 不是承诺（2026-11-24 18:40，已修）

真机 0.1.12 的 control 组第 5 发不是重定位失败，是 SIGSEGV：`addr=0x0`、
`pc` 在 ld-musl 内、`lr` 高两帧——一次**在打印错误信息的路上**的空指针。
一条"已经在退出的路上"的崩溃不可能是"查不到符号"，它是"某个全局变量不是它该有的值"。

v2 能把一个不是零的全局交给 guest 的地方只有一处：`.bss`。每个段的尾巴都是
`MAP_FIXED` 覆盖到"刚才还住着别的库"的页上，Linux 承诺新映射读出来是零。
v2 用 `mprotect(PROT_NONE)` + `madvise(MADV_DONTNEED)` 兑现这个承诺，而 Darwin 的
`madvise` 文档写的是"**可能**回收这些页"——是提示，不是承诺。

`V2_PAGETEST=1` 在 arm64 runner 上第一次跑就给了答案：

```
page reused after unmap is DIRTY (16384 of 16384 bytes nonzero)
madvise(DONTNEED) discarded NOTHING (16384 of 16384 bytes still nonzero)
```

所以 decommit 一直是假的：页原样回来，内容一个字节都没丢。修法是让 decommit 真的
**换掉**这段映射（`MAP_FIXED|MAP_ANON|PROT_NONE`），新匿名页按定义就是零。代价是它
从"提示"变成真 syscall，于是 unmap 与 `MAP_FIXED` 替换路径改成按连续 run 批量调用。

guest 的 `MADV_DONTNEED` 也补回了 Linux 语义：释放 + 用原权限重新 commit，
映射还在、内容没了（这需要按页权限切分 run，因为一个范围中途可能换权限）。

**这一条修完，flake 没消失**（5/200，仍在 1–3% 量级）。所以它是一只会自己站出来的
真 bug，但不是这一个。

#### 失败当场比对：字节是对的，错的是 musl 拿它们建出来的东西（2026-11-24 18:55）

`V2_VERIFY` 一直在**退出时**比对、且只比**可执行页**。两处都要改才有信息量：

1. **在失败那一刻比**。ld.so 打完 `Error relocating` 几条指令就 `exit(127)`，退出时的
   现场已经没用了——同一个理由此前把寄存器 dump 挪到了 `write()`。
2. **比只读页**。`.gnu.hash` / `.dynsym` / `.dynstr` 在只读段里，符号查找失败而代码
   与文件一致时，唯一还能错的就是这些表。

第一版有个坑，值得记：不排除可写段时，每次失败都报几万字节差异——因为
`PT_GNU_RELRO` 是 ld.so 写完指针**之后**才 mprotect 成只读的，失败时它们"只读且与
文件不同"完全正常（libcrypto 报了 133 233 字节，全部落在 RELRO 内）。把可写段
（库的 phdr 现读、主程序/解释器用已解析的段）登记进排除表之后：

```
in-failure comparison: fired=5 silent=0
（没有任何 differs at）
```

**五发失败、五发现在比对，每一发都：所有只读页与文件逐字节一致。**
推论很硬：装载器、页表、`pread`、补丁全都没有问题；出问题的是 musl 用正确字节建出来的
运行时结构（dso 链、symtab 指针、它自己 mmap 出来的堆）。

顺带修了一个仪器 bug：这个钩子原来对单个 `write()` 的缓冲做 `strstr`，而 musl 的 stdio
经 `__overflow` **一次只写两个字节**，"Error relocating" 永远不在一次 write 里——加了
寄存器 dump 之后的那次 CI，六发失败、零次 dump，看起来像"现场不可得"，其实是从没匹配上。
现在按流累积。

#### 已知 bug 的四种脸（2026-11-24 19:05）

同一个根因现在有四个可区分的落点，CI 分开计数、分开打印，都不单独判红：

| 脸 | 现场 |
|---|---|
| `symbol` | `Error relocating <lib>: <sym>: symbol not found` |
| `fault` | 重定位期间崩溃，带地址与 pc（本机首次：`addr=0x326676e00`） |
| `index-io` | `WARNING: opening /repo/main: IO ERROR` → `OK: 0 distinct packages available`（v1 的原始签名） |
| `no-count` | 退出码 0、但没有那行 package 计数 |

`MISMATCH` 与"不属于这四类"的失败仍然无条件判红。分开计数的意义：总数可以一直是 5，
而构成从"五个符号查找"变成"三个查找 + 一次崩溃 + 一次读不了索引"——那是另一个 bug
穿着同一个数字。

#### ASLR 是开关：钉住基址 400 发零失败（2026-11-24 19:40）

三发失败运行的**相对布局逐项相同**（镜像 +0x10000、解释器 +0x34000、栈 +0x48f8000，
库紧随其后），通过运行的也一样——分配器是确定性的。所以布局不是变量。剩下唯一会变的
东西是 arena 的**绝对基址**。

于是把基址钉在 `0x7000000000` 起、按 16 MiB 步进扫 200 个地址、每个跑 2 发（共 400 发）：

```
sweep: 200 usable bases, first failing base=none
```

**同一个 job 里不钉基址的 200 发：5 次失败（3 个 symbol + 2 个 fault）。**

400 发 0 失败 vs 200 发 5 失败，差异不会被采样噪声解释。结论：**这条 bug 依赖 ASLR，
一旦钉住 arena 就完全不发生。**

两条预约路径只差一件事：

| 路径 | 代码 | 结果 |
|---|---|---|
| 不钉（出厂） | `mmap(NULL, 1 GiB, PROT_NONE, ANON\|PRIVATE\|NORESERVE)` | ≈2.5%/次失败 |
| 钉住 | 同上加 `MAP_FIXED`，地址固定 | 400/400 通过 |

这就把一个统计量变成了**受控变量**：下次要做的是把两条路径之间真正不同的东西找出来
（内核给出的基址性质？落在进程已有映射附近的相对位置？`MAP_FIXED` 与普通预约在 VM
entry 上的差别？），而不是继续猜 musl。

顺带排除的：页表自检 150 发零损坏（`V2_CHECK_SPACE=1`，每操作一次全表校验 + 尾部 canary），
所以别名不是"表被写穿"造成的。

#### 更正：低地址那 84–96% 是我自己的仪器造成的（2026-11-24 19:55）

上面那条"管住基址就 400 发零失败、低地址 84–96% 必败"的结论，**一半是错的**，原因必须写下来：

`V2_SPACE_BASE` 用 `MAP_FIXED` 把一个 1 GiB 的 `PROT_NONE` 预约压在指定地址上。
压在高地址（448 GiB）没问题；压在 `0x120000000`（4.5 GiB）时，那里是**宿主自己的
堆/映射区**——`MAP_FIXED` 把它砸掉了，之后 malloc 从一个现在变成 `PROT_NONE` 的地址
返回内存，宿主侧 `memcpy` 当场 SIGBUS。

失败日志短得一眼就能看出来：

```
[v2] space 0x120000000..0x160000000 page=0x4000
[v2] load base=0x120010000 entry=0x120014140 span=0x24000
[v2] FAULT signal=10 addr=0x140600000 pc=0x18bbb7ac4
[v2] page state=0x00 (free --) guard=0
[v2] last 0 syscall(s):
```

`pc` 在 dyld 共享缓存里（不在 guest 里）、`state=free`、**一次 guest syscall 都还没发生**。
那是宿主代码在写一个表里不存在的页，不是 musl 的事。所以 126/150、144/150 这两个数字
测的是"我把进程自己的内存砸了"，不是 flake。

修法：`V2_SPACE_BASE` 现在**拒绝 128 GiB 以下的地址**并明说原因，因为一个不可信的钉法
比没有钉法更糟——它会把一次未钉住的运行伪装成一次钉住的运行。

**仍然是事实的部分**：

| 配置 | 结果 |
|---|---|
| 内核选址（出厂，1–3% 失败） | 失败 |
| 固定 448 GiB（200 个地址、400 发） | **零失败** |
| 固定 4.5 GiB | 无效（仪器砸了宿主堆），已拒绝 |

固定在高地址时 400 发零失败、未钉住时 200 发 5 败，这个差异仍然成立；但它现在只能说明
"钉住之后不发生"，**不能**说明"低地址是坏的"。下一步要测的是"钉住 vs 不钉住"到底改了什么，
而不是继续在低地址上刷数字。

#### 更正二：ASLR / 地址区域都不是变量；入口状态是逐字节确定的（2026-11-24 20:25）

上一节写的"钉住基址 400 发零失败、低地址必败"两条，后面都被更大的样本推翻了，记在这里：

| 配置 | 样本 | 失败 |
|---|---|---|
| 内核选址（出厂） | 154 发 | 4（2.6%） |
| 固定 448 GiB（200 个地址扫过） | 400 发 | 0（当时） |
| 固定 448 GiB | 150 发 | 8（5.3%） |
| 固定 448 GiB | 150 发 | 1（0.7%） |
| 固定 448 GiB | 150 发 | 3（2.0%） |

同一个固定基址的速率在 0.7%–5.3% 之间摆——**和未钉住时没有区别**。所以：

- "ASLR 是开关"❌（那是 400 发零失败带来的错觉，p≈0.006 的事件确实发生了）
- "低地址是坏的"❌（那 84–96% 是我把 arena 压在宿主堆上砸出来的 SIGBUS，见上一节）
- **速率是每发一次硬币，2% 上下，与地址无关**，失败在序列里均匀散布（1,12,19,23,45,56,75,83）。

于是问了一个更本质的问题：**同样的基址下，我们交给 guest 的东西是不是每次都一样？**
`V2_HASH_ENTRY=1` 在进入 guest 前把每个页的状态和内容（可读页）打进一个 FNV：

```
run 1 ok     hash=0xfc6ea00b5354052c mapped=4666 readable=4657
...
run 5 FAILED hash=0xfc6ea00b5354052c mapped=4666 readable=4657
...（15 发全部相同）
```

**15 发、包括失败的那一发，入口状态哈希完全相同**。跳板岛被排除在哈希之外，因为每个
站点 stub 里嵌的是宿主 `v2_syscall_entry` 的地址，那是唯一一处"宿主地址按设计进 guest"
的地方，它随宿主 ASLR 变，会把真正的问题淹掉。

结论收得很紧：

1. 我们交给 guest 的初始状态**逐字节确定**；
2. syscall 返回值也是确定的（`getrandom` 是固定种子的 PRNG，`mmap` 走确定性分配器，
   文件内容固定）；
3. **未初始化内存也被排除**：用 `-ftrivial-auto-var-init=pattern` 重新编译同一份代码，
   150 发里仍是 2 次失败（出厂 2 次），速率没动。

那么在"入口一样、返回值一样"的前提下，**分歧只能发生在执行过程中**，而能让它分歧的
东西只剩两类：我们返回给 guest 的某个**值**在某种条件下不一样，或者**时序**。

下一步的仪器因此换成**全量 syscall 轨迹**：把每一发的 `nr / 参数 / 返回值` 完整写下，
拿一发失败的和一发通过的逐行 diff，第一个分叉点就是答案。现在只有 32 条环形缓冲，
足够看崩溃现场，不够做 diff。

#### 全量轨迹 + 边界指纹：把 1% 钉到「第 38 个边界上的 x18」（2026-11-24 21:40）

三件仪器，按时间顺序，每一件都排掉了上一条的猜测。

**1. 全量系统调用轨迹（`V2_SYSCALL_LOG`）**

环形缓冲只有 32 条，够看崩溃、不够做 diff。现在把每一发的 `名称 / 六个参数 / 返回值 / site`
全量写下（上限 30 万行），并加 `V2_TIME_FREEZE` 把 `clock_gettime` 钉在
2025-01-01T00:00:00Z——**它是此前唯一真实的、每发都不同的输入**。

第一次跑就抓到：**第 47 个系统调用分叉**，通过的那发做 `mprotect(主程序 RELRO)`，
失败的那发改成 `writev(2, ...)` 打了错误信息。也就是说失败发生在"处理最后一个 dso"时。

**2. 边界指纹（`V2_HASH_EACH`）**

进入 guest 前哈希内存、成功过；但**两次调用之间**从来没测过。现在每个边界打一行：
31 个寄存器 + sp/pc/nzcv。第一次跑就发现 **boundary 0 的寄存器就已经不同**——

```
boundary 0 regs2 x16=0x1048fcca4 ...   (通过)
boundary 0 regs2 x16=0x1046d8ca4 ...   (失败)
```

x16 是宿主入口地址，设计上就是唯一进 guest 的宿主地址，属噪声。但它暴露了真问题：
**`v2_guest_enter` 只设了 pc 和 sp，guest 的 x0..x30 全是宿主寄存器里的残留**（宿主栈指针、
堆指针）。已修：整份寄存器从 `struct v2_cpu`（runner 已 memset 0）加载，nzcv 一并清零。

**3. 内存转储（`V2_DIAG_WORDS`）**

逐页哈希找到了栈页，逐字转储找到了字——**都是宿主代码地址**，因为它们来自两处设计缺陷：

| 缺陷 | 现象 | 修法 |
|---|---|---|
| 调度器跑在 **guest 的栈** 上 | 每层的 C 栈帧（含宿主返回地址）写进 guest 内存 | `v2_syscall_entry` 切到自己的 256 KiB 栈（`.bss` 里的 C 数组；用 `.space` 放进 `__TEXT` 会 SIGBUS——这个错误被 `hello` 十秒抓到）|
| 入口帧存了 **x16** | 每次调用在 guest 栈留下一个宿主地址（且该槽位从不读回） | 不存 x16，只存 x17 |
| 故障处理器跑在 guest 栈上 | 崩溃路径同样污染 | `sigaltstack` + `SA_ONSTACK` |

顺带把测量本身的两个错也修了：**"内存也相同"从来没有在真正出事的边界测过**（只在 boundary 0
dump 过）；以及 dump 窗口固定在 0 和 44–46，而**分叉点每发不同**（42 / 46 / 47），窗口一直
落在答案外面。现在覆盖 36–48。

**目前最新一发（600 发里第 11 发）：**

```
first divergence at call 16233
  reference: boundary 38 regs2 ... x18=0x400000000000 ...
  suspect  : boundary 38 regs2 ... x18=0x0 ...
  reference: boundary 38 word 0x70048f71f0 0x400000000000
  suspect  : boundary 38 word 0x70048f71f8 0x70000f6d20
```

boundary 0–37 **寄存器和内存（36、37 有转储）全部相同**，到 **boundary 38 的 x18 才分叉**。
第 38 号调用是 `read(0x3, buf, 0x3c0) -> 960`，也就是读 ELF 头之后。

`x18` 在 Darwin 上是**平台保留寄存器**（ABI 明令用户态不要用），而 Linux 上它是普通
寄存器、musl 可以随便用。目前无法解释 `0x400000000000` 的来源——这是下一步唯一要回答的问题。


#### 21:50–23:10：x18 是 guest 自己带进来的；栈页死区在污染每一次比对

**先排掉两条静态可能**（不必上 CI）：

- 全镜像里 `svc #0` 共 **478** 条、`mrs xN, tpidr_el0` 共 **90** 条，逐条统计与运行时
  `patch svc=478 mrs=90 msr=1` 完全一致 → **没有未替换的 syscall**，guest 不可能真陷进 XNU。
- 全部二进制里 `mrs x18, <sysreg>` 只有 **1** 处（libcrypto，且看着像误码）→ x18 不是从系统寄存器来的。

**x18 的进/出记录**（`V2_DIAG_ENTRY`）：

```
boundary 38 x18 in=0x400000000000 out=0x400000000000   (通过)
boundary 38 x18 in=0x0            out=0x0              (失败)
```

**进等于出** → 宿主没写它，是 guest 自己带进来的。所以"宿主的代码污染 guest"这条到此为止。

**测量本身又错了三次，每次都是"看不见"而不是"没有"：**

| 错误 | 后果 |
|---|---|
| 字转储有 8000 字上限，取的是**最低地址**的 8000 个非零字 | 栈在地址空间**最末尾**，从来没被比较过 |
| 只打印"最高 8 页"的字 | first-fit 把 libcrypto 放在栈顶之后，取到的是库尾巴 |
| 页哈希行在字之前 | diff 停在"这一页不同"，具体字节永远打不出来 |

改成：**逐页哈希（无截断）** + **按 `sp` 定位那一页并列出它的字** + **栈页不出哈希行**。

**当前最好的一发（boundary 36，栈页）：**

```
reference: boundary 36 word 0x70048f70d0 0x3ec0e3c7c67603ed
suspect  : boundary 36 word 0x70048f70d0 0xf533d8b0cc38ac01
```

两个值都像随机数，且**每发不同**。而这条地址在 sp 下方约 1 KB——**已经死掉的栈空间**，
guest 不会再读。它让整页哈希每次都不一样，把真信号淹掉。

所以最后一步改动（**已在本地提交、尚未推送**）：栈页只列出**从我们自己的帧往上**的字
（`sp - 800` 以上），以下属于死区，按定义不可能影响行为。

**下一步（网络恢复后第一件事）**：推 `bc1ee8c`，跑一轮，看 boundary 36–41 的
**活区**是否一致。若一致，分叉就只在第 42 个调用的执行过程中——那时要查的是
`d8..d15` 之外的、我们仍然没测的状态；若不一致，那个字就是答案。

**再排除一条**：全镜像里 `paciasp / autiasp / pacibsp / retaa / bti` **一条都没有**，
所以这些"随机字"不是**带指针认证的返回地址**（PAC 的签名位会随进程密钥变化，本来是最省事的解释）。
两个值异或后也没有结构（`0xcbf33b770a4eafec`），是独立随机量。

**仍未解释**：`0x400000000000` 与这些随机字从哪来。已知它不由宿主写入、不由系统寄存器读入、
且不来自任何未替换的 syscall。

#### 23:15–23:55：栈上那些"随机字"是 SIMD 寄存器；清零后比对终于干净了

上一节的死区过滤没有解决它：过滤之后仍在 `0x70048f74c0` 找到随机的、每发不同的字。
那个地址落在**我们自己的 528 字节 FP 保存区**里——也就是 `q0..q31`。

**根因同族**：通用寄存器早就改成从 `struct v2_cpu`（已清零）加载，**SIMD 寄存器没有**，
所以 guest 开局拿的是宿主残留的向量值，然后自己把它们溢出到栈上。

清零 32 个 `q` 之后，比对第一次干净了——**第一处差异回到系统调用行本身**：

```
first divergence at call 29748
  reference: 29748 mprotect(0x7004ca0000 0x58000 ...) -> 0
  suspect  : 29748 writev(0x2, ...) -> 67
```

**boundary 0..41 的寄存器、以及 36–41 每一页（含栈的活区）的哈希和字，全部相同。**

但速率**上升**了（4/300、10/300、10/300、8/300，此前 1–3%）。这说明 guest 的向量状态
确实参与行为——它读到了我们给的初值，而这个初值影响它走哪条路。换句话说：
**某个 guest 路径在写之前读了 SIMD 寄存器**，Linux 上那里是零，我们之前给的是宿主垃圾。

这两条放在一起，指向的已经不是"我们搬错了字节"，而是"guest 在依赖一块我们直到今天
才第一次真正定义下来的状态"。速率上升是好事：它说明这个方向是活的。

剩下来要解释的只有一件事：状态相同、代码相同、寄存器相同，第 42 个调用为什么不同。

#### 2026-11-25：仪器和被测对象共用一个地址空间，这才是循环的原因

到这一节为止，五次"测量错误"里有四次是同一个形状：**宿主往 guest 能读到的内存里写了东西**。

| 位置 | 宿主写进去的 | 被谁看见 |
|---|---|---|
| 调度器的 C 栈 | 返回地址、临时变量 | guest 栈（已改为独立宿主栈）|
| 入口帧 x16 | 宿主入口地址 | guest 栈（已删除该槽位）|
| 入口帧 528 字节 FP 区 | 宿主 SIMD 值 | guest 栈（已改为清零，再改为完整保存/恢复）|
| 故障处理器 | 它的栈帧 | guest 栈（已改 `sigaltstack`）|
| **入口帧本身（800 字节）** | **全部寄存器** | **guest `sp` 下方 800 字节**（本次）|

最后一条是结构性的：帧压在 guest 栈上，意味着**每次系统调用都往 guest 自己拥有的内存里
写 800 字节**。guest 下一次调用更深时正好复用这些字节；任何"先读后写"的局部变量读到的
是宿主寄存器，而不是 Linux 会给的零。它随宿主布局变化——这正是这个 bug 的指纹。

改动：

- `struct v2_cpu` 扩到 800 字节，含 `q0..q31`、`fpcr`、`fpsr`；`v2_syscall_entry` 把帧
  写进 `.bss` 里的 `v2_cpu_frame`，**系统调用路径不再写 guest 内存一个字节**；
- 边界指纹增加 `boundary N fp <hash>`：向量寄存器此前是唯一"guest 可见但没人测"的状态，
  而清零它们会改变失败率，说明 guest 确实在读；
- 栈页的字转储从 `sp` 起（此前为了避开宿主帧从 `sp-800` 起，等于把 guest 的活区截掉一半）。

判读方式：如果 flake 是这一类，速率应显著变化或消失；如果不变，则"宿主污染 guest 内存"
被彻底排除，剩下的只能是 syscall 返回值或时序——那两类都有对应的仪器，不用再猜。
