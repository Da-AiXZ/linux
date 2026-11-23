# v1 架构审查

对象：`Da-AiXZ/linux` @ `14073b3`（0.42.0 / build 147）
范围：全部 55 个受版本控制的文件，重点是 `Guest/GuestRunner.m`（8659 行）
结论日期：2026-11-23

---

## 0. 结论先行

1. **这个项目已经证明了最难的那部分**：在 iPadOS 16.6.1 上用 `ptrace(PT_TRACE_ME)` 拿到
   `CS_DEBUGGED`、把 guest 的 `svc #0` 改写成跳板、加载 musl 的 `ld.so`、让 Alpine 的
   `apk` 真正完成一次 `add`。这不是"玩具级"成果，`AGENTS.md` 第 349 节那 21 条约束是用
   几十次真机崩溃换来的，任何重写都必须继承它。

2. **但它没有"地址空间的事实来源"。** 运行时有四套互相独立的簿记在描述同一件事：
   宿主内核的 `vm_region`、`GuestMmapRecords[4096]`、`GuestFreedStart/End[64]`、
   以及 image/interp/stub/heap/stack 五个硬编码区间。任何一次 `mmap`/`munmap`/
   `MAP_FIXED` 都可能让这四套互相矛盾，而代码里没有任何机制能强制它们一致。

3. **zlib 的 `Z_DATA_ERROR` 不是 zlib 的 bug。** 已经证明的事实（输入逐字节正确、libz
   未被补丁、`inflate_state` 入场干净、两个 zlib 版本、16 KB 页、`read` 与 `pread`
   逐字节相同）合起来只有一个剩余解释：*inflate 运行期间，它引用的内存被 runtime 自己
   改掉了*。这类故障无法用"再给 zlib 加一个探针"收敛——探针只能看见 zlib 的读写，看不见
   "这一页在 zlib 脚下被换掉"。

4. **判决：不要修。** 需要替换的是"地址空间"这一层（约 1.5k 行），而不是在 8.6k 行里
   再改 200 行。v1 保留为只读参照实现。

5. 定量旁证：128 次提交、41 小时、**其中 43 次提交**（三分之一）在追同一个索引解析失败；
   仓库里**没有任何自动化测试**；唯一的验证手段是"构建 IPA 6–8 分钟 → 手动安装 → 点一次
   菜单"。迭代成本决定了每次只能验证一个假设，这就是为什么 6 个里程碑之后开始原地打转。

---

## 1. 项目实质

| 维度 | 事实 |
|---|---|
| 目标 | iPad Pro 2021（M1 / arm64e，iPadOS 16.6.1，TrollStore 2）上原生执行 Linux 用户态 |
| 方法 | guest 是 arm64 ELF，指令由 M1 直接执行；只改写 `svc #0` / `mrs` / `msr tpidr_el0` |
| 不是 | 虚拟机、模拟器、解释器（用户已明确否决） |
| 已达成 | M0 能力探针、M1 原生 ELF、M2 static-PIE busybox、M2.5 rootfs+shell、M3.1 musl `ld.so`、M3.2 本地 `apk add` |
| 未达成 | M3.3 网络 `apk update`（唯一阻塞项）、线程、guest 信号、动态 fork、PTY |
| 规模 | `GuestRunner.m` 8659 行；144 个 syscall case；55 个受控文件 |
| 依赖 | 无 Xcode 本地环境，全部构建走 GitHub Actions（macos-15-intel），产物 ipa 侧载 |

技术判定：**方向是对的，地基是错的。** 直接在 M1 上跑 guest 指令这条路线在 iPadOS 上
成立（已被 M1/M2 证明），但它对"内存语义"的要求比模拟器高一个数量级——模拟器可以把
guest 物理页放在任意宿主页里，而这里 guest 的虚拟地址**就是**宿主虚拟地址，于是
guest 页大小、对齐、权限、映射生命周期全部必须与宿主精确对齐。v1 没有建立这条对齐。

---

## 2. 现状架构与数据流

```
Probe.app ──posix_spawn──> Helpers/guest-runner <elf> [argv...]
                              │
                              ├─ ptrace(PT_TRACE_ME)        → CS_DEBUGGED
                              ├─ mmap 1MB 跳板岛（±112MB 内所有映射都要够得着）
                              ├─ GuestLoadAndRunInternal    → 读 ELF、mmap image、
                              │                                memcpy 段、打 svc/mrs/msr 补丁
                              ├─ 若 PT_INTERP：再加载 ld-musl，独立基址，同样打补丁
                              ├─ 构造 argv/envp/auxv（AT_PAGESZ=0x4000、AT_BASE、AT_ENTRY…）
                              └─ GuestJump(entry, sp)
                                     │
              guest 指令在 M1 上直接执行；遇到 svc → b island → GuestSyscallTrampoline
                                     │
                              GuestSyscallDispatchInner（144 个 case）
                                     │
                     mmap/munmap/mprotect/mremap → 四套簿记 + 宿主 syscall
```

关键在最后一行：**guest 的每一次内存操作都要经过一层"翻译"，而这层翻译没有唯一真相。**

---

## 3. 结构性缺陷

### A. 地址空间模型（致命，全部其它问题的根）

**A1. guest 页 4 KB、宿主页 16 KB，一个宿主页可能同时属于两个 guest 映射。**
Alpine 的 ELF 段按 4 KB 对齐，`ld.so` 的 `MAP_FIXED` 段长度常常是 4 KB；宿主只认 16 KB。
于是"改权限"必须变成"对完整覆盖的页给精确权限，对边缘共享页取并集"
（`GuestProtectRange`，`GuestRunner.m:6052`）。这条规则本身没错，但它需要知道
"这一页上还住着谁"——而 A2 的簿记给不出这个答案。同一个点在四个版本里被修了四次：
0.35.4、0.35.5、0.40.6、0.40.12，每次都是"边缘页/首尾页算错"。

**A2. 映射记录是旁路账本，与宿主状态没有强制一致性。**
`GuestRememberMmap` 只 append（`:6154`），`GuestForgetMmap` 只做区间裁剪（`:6257`），
容量 4096，满了就 `mmap records full, leaking` 静默丢弃（`:6176`）。它不参与任何
断言，也没有"重建/校验"路径——一旦某次裁剪写错，错误会一直留在表里。

**A3. `MAP_FIXED` 被改写成语义不同的操作。**
`GuestHandleFixedAnon`（`:6674`）做的是"确保可写 + `memset` + 记一笔"，既不 unmap，
也不处理记录重叠；目标落在 runtime 区间时直接返回 `-EINVAL`（`:6893`）。
而 musl 的 brk 尾部 trim 正好走这条路径——日志里每次运行都能看到
`mmap fixed overlaps runtime: … brk=… heap=…`，意味着 guest 每次启动都少执行了一次
合法操作，且它拿到的错误被 `ld.so` 当作"没事"吞掉。

**A4. 释放策略在"精确匹配"和"全部泄漏"之间摇摆。**
0.40.12 要求"记录精确等于请求"才释放（`GuestPageRecordsFitRequest`，`:7155`）；
0.41.5 干脆 `#define GUEST_LEAK_SMALL_MAPPINGS 1`（`:7188`），≤128 KB 一律不释放。
这两条互斥，且都是"用泄漏换不确定"。apk 一次运行会申请数十 MB 的 16–128 KB 映射，
泄漏不是可选项，而是定时炸弹。

**A5. guest 地址空间被切成两个不相交的宇宙。**
匿名映射走宿主 `mmap(NULL)`（`:6933`，可以落在任意地址）；文件/ELF 映射走 112 MB
跳板窗口（`GuestAllocateMmapAddress`，`:6401`）。补丁可达性只对后者成立，于是代码里
必须存在"落在窗口外就不打补丁"的分支（`:7037`）——一个 guest 库是否被打补丁，取决于
它被分配到哪里。

**A6. 地址空间只增不减。**
guard page 故意不登记（`:6929`），释放时只处理"请求完整覆盖且记录匹配"的页
（`:7212`），其余全部保留。112 MB 窗口里还要放 64 MB 堆 + 8 MB 栈 + interp，
这直接导致 0.38.3 的 `no free guest address near stub`。

**A7. 页大小硬编码。**
`GUEST_HOST_PAGE_SIZE 0x4000`（`:5974`）。在 4 KB 宿主（Intel Mac、iOS 模拟器）上
整套对齐逻辑失效——这是"桌面无法复现、只能真机迭代"的一半原因（另一半是 RWX 需要
`CS_DEBUGGED`）。

**A8. 没有"guest 指针是否合法"这个概念。**
每个 syscall 直接解引用 guest 指针。一旦 A1–A7 中任何一条产生错误地址，宿主收到
SIGSEGV，runtime 自己被杀死，现场只能靠信号处理器反推。v1 有 700 行信号/watchpoint
代码在处理这件事的后果。

### B. 执行模型

**B1. fork 是 checkpoint/restore，但快照不含 interp 与补丁状态。**
动态镜像直接 `-ENOSYS`（`:7639`），恢复子进程靠"猜基址"（`:4993`）。这不是实现不全，
是快照的定义不完整：只有"image + heap + stack"，没有"地址空间"。

**B2. execve 靠"在宿主里找一块离 trampoline 近的空地"。**
找不到就 `no free address range near trampoline`（`:8025`）。成功率取决于宿主的
地址空间碎片，而不是 guest 的行为。

**B3. TLS 是全局影子变量。**
`GuestTlsPointer`（`:129`）单线程成立，线程必然互相踩。而线程（`clone` 带 `CLONE_VM`）
是 M4 的既定目标，等于地基提前挖空。

### C. 工程质量

**C1. 零自动化测试。** `find . -iname "*test*"` 为空。唯一的回归手段是人工点菜单。
128 次提交、6 个里程碑、43 次追同一个 bug，全部没有可重复的验证。

**C2. 观测仪器修改被测对象。** `GuestReadWatchCheck` 插在 mmap/munmap 主路径
（`:6864`、`:6678`、`:6799`）；硬件 watchpoint 需要单步并"重发被吞掉的 store"
（0.41.10）；作者在 0.42.0 的提交信息里承认最近四次实验有三次产生了无效数据。

**C3. 错误模型不统一。** `-EINVAL`、`GuestErrno()`、`-ENOEXEC`、裸 `errno` 混用，
没有单一返回出口，也没有"哪些 errno 需要翻译"的编译期保证。

**C4. 8.6k 行单文件 + 144 分支巨型 switch。** 没有模块边界，没有可替换接口，
任何改动都可能影响任意其它路径。这次审查中就能看到：一个"只加日志"的提交
（0.41.8）引入了"表在使用之后才定义"的编译错误，需要下一个提交修。

### D. 工程流程

**D1. 反馈环 6–8 分钟 + 手动安装一次。** 单次实验只能验证一个假设，且不可并行。
**D2. 结论沉淀在文档里但不可执行。** `AGENTS.md` 写着"不要再归因于网络/TLS/apk"，
代码里同时保留 zspy、zguard、watchpoint 三条仪器路径和 12 个诊断菜单项。

---

## 4. 关于那个"一直解决不了的问题"

### 4.1 已经被证明的事实（不再重复验证）

| # | 事实 | 证据 |
|---|---|---|
| 1 | 缓存索引与 CDN 逐字节一致（sha256、大小） | 0.38.8 真机 |
| 2 | 每一块 ≥64 KB 的 `read` 与同偏移 `pread` 逐字节相同、偏移严格递增 | 0.39.1 `jumps=0 mismatch=0` |
| 3 | libz 自身没有被补丁改写（`svc=0 mrs=0 msr=0`） | 0.40.x CI |
| 4 | `inflate_state` 入场逐字段干净 | 0.40.7 |
| 5 | zlib 1.2.13 与 1.3.1 同样失败 | 0.39.2 |
| 6 | `AT_PAGESZ=16 KB` 后故障依旧 | 0.39.0 |
| 7 | 输入缓冲逐页哈希不变（`changed=0`） | 0.38.9 / 0.39.0 |
| 8 | 不释放 ≤128 KB 映射后故障依旧 | build 143 的 20 连跑仍出现 `IO ERROR` |
| 9 | 故障点随机漂移（9262 / 10541 / 21459 / 24049 包） | 0.38.9–0.39.2 |
| 10 | 落点是一次 **4 字节写入**，写进 `inflate_state+0x20`；写入值是一条合法 CRC 链的种子（`0x3da750f2`），不是垃圾 | 0.41.0 `[zck]` 对账 |

### 4.2 逻辑推论

若 (1)(2)(7) 输入正确、(3) 代码未被改写、(4) 状态入场干净、(5)(6) 与版本/页大小无关、
(8) 与释放路径无关，则只剩一种可能：

> **inflate 运行期间，它引用的那些页被别人改掉了。**

宿主内核不会去改一个进程的私有匿名页。能改的只有 runtime 自己。runtime 能改 guest
内存的路径恰好五条：`mmap` 的 commit、`munmap`、`mprotect`、`GuestHandleFixedAnon`
的 `memset`、`GuestEnsureWritable` 新建页。这五条全部建立在 §3.A 的簿记之上。

### 4.3 为什么"再加一个探针"不可能收敛

探针只能观测**读写**。而这里的故障形态是**页被替换/清零/解除映射**——一次
`MAP_FIXED` + `memset` 之后，zlib 的指针仍然合法、`far` 仍然落在"它以为自己拥有的
范围"里，但内容已经变了。`vm_region_64` 会告诉你"这页有映射"，`GuestMmapRecords`
会告诉你"这页有记录"（因为 0.40.12 补登记了），`state1/state2` 的偏移会保持稳定，
而 `inflate()` 照样返回 `Z_DATA_ERROR`。

v1 的日志里其实已经有直接证据：

```
[ovl-fixed] anon 0x105390000..0x105394000 overlaps a live record up to 0x105394000
[ovl-rec]   0x105390000..0x105394000 overlaps 0x104f2c000..0x105394000 (records=1)
```

这是 `ld.so` 给 libcrypto 的 bss 尾页做 `MAP_FIXED`，落在"整文件映射"的记录里。
此后这条记录既不能被 `GuestPageRecordsFitRequest` 精确匹配（所以永不释放），
又会被 `GuestForgetMmap` 在别的路径上裁剪。**同一条记录被两套规则同时作用，
结果不可预测**——这正是"故障点随机漂移"的来源。

而 0.41.0 的对账给出了写者的指纹：落点是 `inflate_state+0x20` 的一次 4 字节写入，
写进去的值 `0x3da750f2` 是一条**合法 CRC 链的种子**，不是随机垃圾。也就是说：
**写者当时正在写一个校验和**。一个"正在写校验和"的人，把值写进了另一个人的结构体里
——这不是野指针乱写，这是**两个人用同一个 4 KB**。别名（aliasing）的典型形态。

同一条 4 KB 页被两个活着的分配同时认领，一个把自己算出的 CRC 写进去，另一个把它
当成 `state->check` 读出来——后面所有的 `Z_DATA_ERROR`、`len=-1`、短流都从这里长出来。
这解释了为什么"输入正确、代码正确、状态入场干净"三者可以同时成立。

### 4.4 判决

不必再验证 4.3 的假设。它只需要证明一件事：**这个模型不满足守恒律**——无法回答
"地址 X 的这一页，现在属于谁、内容是什么、谁能写"。而这个事实已经由代码自己承认了
（0.41.5 的"永不释放小映射"开关就是承认）。

---

## 5. 可以保留的资产（重写时直接搬）

| 资产 | 位置 | 价值 |
|---|---|---|
| iOS 约束清单（21 条不变量） | `AGENTS.md` §"Guest 运行时不变量" | 几十次真机崩溃换来的，全部仍然成立 |
| 签名与 entitlement 组合 | `AGENTS.md` §"签名"、`App/Probe.entitlements` | 试错成本极高，直接复用 |
| CI 流水线骨架 | `.github/workflows/build.yml` | Alpine 下载、xcodegen、ldid+codesign、打包 |
| 日志回传与远程命令队列 | `Tools/log_server.py`、`App/ProbeRemote.m` | 真机迭代必需，保留 |
| apk 测试工具 | `Tools/make_hello_apk.py` | 625 B 的合法 apk，构造细节很难再得 |
| 补丁站点校验器 | `Tools/verify_patch_sites.py` | 与 C 侧同算法的独立实现 |
| syscall 语义细节 | `GuestSyscallDispatchInner` | `statfs` 布局、`sockaddr` 转换、errno 表可直接迁移 |
| 路径翻译与 rootfs 引导 | `GuestTranslatePath`、`GuestBootstrapRootfs` | 纯函数，语义已验证 |

## 6. 重写 / 迁移 / 删除

按函数体量估算（`GuestRunner.m` 8659 行）：

| 类别 | 行数（估） | 处理 |
|---|---|---|
| 地址空间、ELF 加载、补丁、跳板、fork/exec | ~3200 | **重写**（本次审查的核心结论） |
| syscall 语义（文件、目录、stat、socket、时间、进程） | ~4000 | **迁移**，改成表驱动 + 统一出口 |
| 仪器（canary、read-guard、watchpoint、zspy、dump） | ~1400 | **删除**，改为独立的可选 trace 层 |

---

## 7. 判决

1. 停止 v1 的一切调试。不再新增探针，不再改 zlib，不再动 `GuestMmapRecords`。
2. v1 冻结为只读参照（它证明了哪些 iOS 限制是真的）。
3. 新工程从**地址空间**开始，第一行代码就要有可执行的语义定义和对拍测试。
4. 验收标准不看"能不能跑起来"，看"同一个失败能不能被自动复现 200 次"。

具体设计见 [ARCH-v2.md](ARCH-v2.md)。
