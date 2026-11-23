# v2 —— 重写工程

v1（`../App`、`../Guest`、`../Helper`）已冻结为只读参照。新代码全部在 `v2/`。

- 为什么重写：[docs/REVIEW-v1.md](docs/REVIEW-v1.md)
- 怎么重写：[docs/ARCH-v2.md](docs/ARCH-v2.md)

## 现在有什么

| 文件 | 内容 |
|---|---|
| `include/v2/vspace.h` | 地址空间接口。guest 页 == 宿主页，页数组是唯一真相 |
| `src/vspace.c` | 页表、first-fit 分配器、mmap/munmap/mprotect/mremap/madvise |
| `tools/vspace_model.py` | 地址空间的**规范模型**，生成对拍轨迹 |
| `tools/vspace_c_port.py` | `src/vspace.c` 的逐行转写，没编译器时用它先跑一遍轨迹 |
| `tests/test_vspace.c` | 假宿主（断言"永不重复 commit"）+ 轨迹重放 + 随机不变量 |
| `tests/trace/*.tsv` | 模型生成的轨迹（返回值 + 页表哈希逐操作比对） |

模型先跑通、再移植成 C —— 语义先可执行，代码再跟上：

```
$ python3 tools/vspace_model.py --check 60 --ops 300 --pages 2048
model ok: 60 seeds, 18000 operations, invariants held
```

## 跑测试

```
make test      # Linux/macOS：ASan + UBSan；轨迹对拍 + 随机不变量
make model     # 只跑 Python 参考模型
make traces    # 重新生成轨迹（改了语义才需要）
```

测试全部在不依赖设备的情况下运行，CI 里 `ubuntu-latest` 与 `macos-latest` 各跑一遍。

本机（Windows，没有 make、没有 MSVC）用装在 F 盘的 zig 直接编译，见
`docs/BUILD-LOCAL.md`。同一份 C 也交叉编译通过 `aarch64-linux-musl`、
`x86_64-linux-musl`、`aarch64-macos` 三个目标，`-Werror -Wshadow` 零告警。

## 下一步

`docs/ARCH-v2.md` §12：G2 = 装载器 + 补丁 + 跳板 + 最小 syscall。
在此之前先做 §13 的 E0（macOS arm64 能否 `mprotect(anon, RX)`），它决定 L3
"桌面真跑"这条测试路径是否成立。
