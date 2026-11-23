# 本机构建（Windows，无 make / 无 MSVC / 无 Xcode）

工具链放在 **F 盘**，不占 C 盘：

```
F:\tools\ziglang\ziglang\zig.exe       zig 0.17.1（pip 装的 wheel）
F:\tools\zig-cache\                    zig 的全局缓存（默认会写 C 盘，这里改到 F）
```

安装方式（走本机系统代理，不走 WorkBuddy 通道）：

```bash
HTTP_PROXY=http://127.0.0.1:7993 HTTPS_PROXY=http://127.0.0.1:7993 \
TMP=F:/tools/tmp TEMP=F:/tools/tmp \
python -m pip install --no-cache-dir --proxy http://127.0.0.1:7993 \
  --target F:/tools/ziglang ziglang
```

## 编译并运行

```bash
cd F:/wb-workspace/linux/v2
export ZIG_GLOBAL_CACHE_DIR=F:/tools/zig-cache
export ZIG_LOCAL_CACHE_DIR=F:/tools/zig-cache/local
Z=/f/tools/ziglang/ziglang/zig.exe

$Z cc -target x86_64-windows-gnu -std=c11 -O1 -g -Iinclude \
      -Wall -Wextra -Werror -Wshadow \
      -o build/test_vspace.exe src/vspace.c tests/test_vspace.c

./build/test_vspace.exe --trace tests/trace/basic.tsv \
                            tests/trace/tight.tsv \
                            tests/trace/wide.tsv
./build/test_vspace.exe --random 400 1
```

预期输出：

```
trace tests/trace/basic.tsv     400 operations ok
trace tests/trace/tight.tsv     300 operations ok
trace tests/trace/wide.tsv      600 operations ok
all checks passed (20125 assertions)
```

## 交叉编译（验证 POSIX 分支能过 CI）

```bash
$Z cc -target aarch64-linux-musl -std=c11 -O2 -static -Iinclude \
      -Wall -Wextra -Werror -Wshadow -o build/t-aarch64 src/vspace.c tests/test_vspace.c
$Z cc -target x86_64-linux-musl  -std=c11 -O2 -static -Iinclude \
      -Wall -Wextra -Werror -Wshadow -o build/t-x86_64  src/vspace.c tests/test_vspace.c
$Z cc -target aarch64-macos      -std=c11 -O2 -Iinclude \
      -Wall -Wextra -Werror -Wshadow -o build/t-macos   src/vspace.c tests/test_vspace.c
```

三个目标都零告警。Windows 版与 CI 版除 `pread()`（POSIX 专有，测试里只有一处调用）
之外是同一份代码路径。

## 为什么要装编译器

v1 唯一的验证方式是"改代码 → 推 GitHub → 等 8 分钟构建 → 装到 iPad → 点一次菜单"。
有了本机编译器，地址空间这一层的每次改动 **1 秒**就能验证，不需要设备、不需要网络。
