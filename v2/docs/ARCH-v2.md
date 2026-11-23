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
base ─┬─ 0 MiB      island 0   (64 KiB, R-X)       ← 每 16 MiB 一个
      ├─ 16 MiB     island 1
      ├─ …
      ├─ 1008 MiB   island 63
      └─ 1024 MiB   end
```

- 整个空间是**一次** `mmap(NULL, 1 GiB, PROT_NONE, MAP_ANON|MAP_PRIVATE|MAP_NORESERVE)`
  预留。虚拟地址不占物理页，1 GiB 在 iPad 上零成本。
- 页大小 = `vm_page_size`。1 GiB / 16 KiB = 65536 页，页表 64 KiB。
- island（跳板岛）在预留时直接标记为 `RESERVED`，分配器永不交出。
  每个 island 64 KiB = 2048 个 32 字节的 per-site stub。
- image / interp / 库 / 堆 / 栈 / 匿名映射**全部来自同一个 first-fit 分配器**，
  没有第二个地址宇宙（对比 v1 的 A5）。

**为什么 16 MiB 一个岛**：`b` 的位移是 ±128 MiB。岛间隔 16 MiB 时，任何代码页到最近
岛的距离 ≤ 8 MiB。装载器把任何含可执行页的映射切成 ≤96 MiB 的块（对 guest 透明，
地址连续、一次 `munmap` 仍然整体生效），因此最坏距离 8 + 96 = 104 MiB < 128 MiB。
这条约束由装载器断言，不靠运气。

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
| **G1** | 地址空间 + 模型对拍 + CI | 已提交（本次） |
| **G2** | 装载器 + 补丁 + 跳板 + 最小 syscall（write/exit/mmap/brk/open/read） | 下一步 |
| **G3** | 静态 busybox 六条命令（桌面 arm64 先绿，再上真机） | |
| **G4** | PT_INTERP + musl `ld.so` + `apk --version` | |
| **G5** | rootfs + `apk add` 本地 + `apk update` 本地 index ×200 | |
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

