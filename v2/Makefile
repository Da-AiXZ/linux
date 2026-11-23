# v2 core -- address space, ELF loader, syscall layer.
#
# `make test` is the only command CI needs.  It builds with ASan/UBSan so a
# page-table mistake is reported at the operation that made it, not three
# thousand syscalls later on a device.

CC ?= cc
BUILD := build
CFLAGS := -std=c11 -O2 -g -Iinclude -Wall -Wextra -Werror -Wshadow
SANITIZE := -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all

SOURCES := src/vspace.c
TESTS := tests/test_vspace.c

all: $(BUILD)/test_vspace

$(BUILD)/test_vspace: $(SOURCES) $(TESTS) include/v2/vspace.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SANITIZE) -o $@ $(SOURCES) $(TESTS)

test: $(BUILD)/test_vspace
	@$(BUILD)/test_vspace --trace tests/trace/basic.tsv \
	                          tests/trace/tight.tsv \
	                          tests/trace/wide.tsv
	@$(BUILD)/test_vspace --random 400 1
	@$(BUILD)/test_vspace --random 400 99
	@$(BUILD)/test_vspace --random 400 12345

# Workstation build.  There is no MSVC and no Xcode on this machine, so zig cc
# (installed on F:) cross-links the same two files for Windows; the binary runs
# the identical code path as CI except for pread(), which is POSIX-only.
ZIG ?= F:/tools/ziglang/ziglang/zig.exe
ZIGCACHE ?= F:/tools/zig-cache

windows:
	@mkdir -p $(BUILD)
	ZIG_GLOBAL_CACHE_DIR=$(ZIGCACHE) ZIG_LOCAL_CACHE_DIR=$(ZIGCACHE)/local \
	  $(ZIG) cc -target x86_64-windows-gnu -std=c11 -O1 -g -Iinclude \
	  -Wall -Wextra -Werror -Wshadow -o $(BUILD)/test_vspace.exe \
	  $(SOURCES) $(TESTS)
	@$(BUILD)/test_vspace.exe --trace tests/trace/basic.tsv \
	                              tests/trace/tight.tsv \
	                              tests/trace/wide.tsv
	@$(BUILD)/test_vspace.exe --random 400 1

traces:
	@python3 tools/vspace_model.py --trace tests/trace/basic.tsv --seed 1  --ops 400 --pages 2048
	@python3 tools/vspace_model.py --trace tests/trace/tight.tsv --seed 7  --ops 300 --pages 256
	@python3 tools/vspace_model.py --trace tests/trace/wide.tsv  --seed 3  --ops 600 --pages 8192

model:
	@python3 tools/vspace_model.py --check 60 --ops 300 --pages 2048

# Pre-compiler check: a hand transcription of src/vspace.c replayed against
# the same traces.  Only useful where there is no C toolchain (the workstation
# that wrote the C had none); CI uses the real binary instead.
port:
	@python3 tools/vspace_c_port.py tests/trace/basic.tsv \
	                                tests/trace/tight.tsv \
	                                tests/trace/wide.tsv

clean:
	@rm -f $(BUILD)/test_vspace

.PHONY: all test windows traces model port clean
