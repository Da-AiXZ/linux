# v2 —— 重写工程

v1（`../App`、`../Guest`、`../Helper`）已冻结为只读参照。新代码全部在 `v2/`。

- 为什么重写：[docs/REVIEW-v1.md](docs/REVIEW-v1.md)
- 怎么重写：[docs/ARCH-v2.md](docs/ARCH-v2.md)
- 哪些结论是真跑出来的：[docs/VERIFICATION.md](docs/VERIFICATION.md)
- 设备回传链路：[docs/DEVICE-LOOP.md](docs/DEVICE-LOOP.md)

## 现在有什么

| 文件 | 内容 |
|---|---|
| `include/v2/vspace.h` | 地址空间接口。guest 页 == 宿主页，页数组是唯一真相 |
| `src/vspace.c` | 页表、first-fit 分配器、mmap/munmap/mprotect/mremap/madvise/claim |
| `include/v2/elf.h` · `src/elf.c` | ELF64 解析、段映射、按页归并权限、装入后一次性封权 |
| `include/v2/patch.h` · `src/patch.c` | `svc`/`mrs`/`msr` 扫描、per-site 32B stub、跳板岛分配与封装 |
| `include/v2/cpu.h` · `src/entry_aarch64.c` | 272 字节寄存器帧 + 裸入口：保存 31 个寄存器、调调度器、`br` 回 guest |
| `src/syscall.c` | 表驱动 syscall：文件、目录、stat、内存、时间、身份、`writev`/`readv` |
| `include/v2/stack.h` · `src/stack.c` | 初始栈：argv/envp/auxv 向下构造，最后只平移指针数组以对齐 16 |
| `include/v2/proc.h` · `src/proc.c` | fd 表、按 fd 记住规范化路径的**词法**翻译（`..` 爬不出 root） |
| `src/host_darwin.c` | 唯一知道自己是 Darwin 的文件（`mmap`/`mprotect`/`vm_page_size`） |
| `src/runner.c` | 预留 → 装载 RW → 打补丁 → 按页封权 → 建栈 → 进入；带故障报告 |
| `app/` | iOS App：装完自动跑 → 自动上传 → 长轮询命令；右上角「…」菜单 |
| `tools/vspace_model.py` | 地址空间的**规范模型**，生成对拍轨迹 |
| `tools/vspace_c_port.py` | `src/vspace.c` 的逐行转写，没编译器时先跑一遍轨迹 |
| `tests/test_vspace.c` | 假宿主（断言"永不重复 commit"）+ 轨迹重放 + 随机不变量 |
| `tests/test_elf.c` | 合成 aarch64 ELF：解析 → 装载 → 打补丁 → 封权 → 检查 stub |
| `tests/test_stack.c` | 按内核的方式读回 argc/argv/envp/auxv，断言 tag 的**编号**与值 |
| `tests/guest/hello` | 2.5 KB 的 aarch64 Linux ET_DYN（纯汇编，write + exit） |
| `tests/guest/busybox` | 1.3 MB 的静态 PIE busybox（zig + musl 构建，见 `BUSYBOX.md`） |
| `tests/trace/*.tsv` | 模型生成的轨迹（返回值 + 页表哈希逐操作比对） |

模型先跑通、再移植成 C —— 语义先可执行，代码再跟上：

```
$ python3 tools/vspace_model.py --check 60 --ops 300 --pages 2048
model ok: 60 seeds, 18000 operations, invariants held
```

## 跑测试

```
make test        # Linux/macOS：ASan + UBSan；地址空间 + ELF/补丁 + 栈
make guest-test  # macOS/aarch64：真的执行一个 aarch64 Linux ELF
make model       # 只跑 Python 参考模型
make traces      # 重新生成轨迹（改了语义才需要）
```

测试全部在不依赖设备的情况下运行，CI 里 `ubuntu-latest` 与 `macos-latest` 各跑一遍。

本机（Windows，没有 make、没有 MSVC）用装在 F 盘的 zig 直接编译，见
`docs/BUILD-LOCAL.md`。同一份 C 也交叉编译通过 `aarch64-linux-musl`、
`x86_64-linux-musl`、`aarch64-macos` 三个目标，`-Werror -Wshadow` 零告警。

当前本机结果（真跑，不是只编译）：

```
trace basic/tight/wide        1300 operations ok, 20125 assertions
random 400 x3                 15804 assertions
test_elf                      93 assertions
stub 机器码                    与 zig 汇编器输出逐字相同
```

## 下一步

`docs/ARCH-v2.md` §12 的 G2b：最小 syscall（`write`/`exit`/`mmap`/`brk`/`open`/
`read`/`close`）+ 栈与 auxv，然后跑通第一个真程序 `pie-hello`。

设备侧：`V2Remote`（自动上传 + 长轮询）随 v2 App target 一起落地，协议与工作站侧
已经用假设备验证过，见 `docs/DEVICE-LOOP.md`。
