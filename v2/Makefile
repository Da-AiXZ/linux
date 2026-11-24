# v2 core -- address space, ELF loader, patcher.
#
# `make test` is the only command CI needs.  It builds with ASan/UBSan so a
# page-table or loader mistake is reported at the operation that made it, not
# three thousand syscalls later on a device.

CC ?= cc
BUILD := build
CFLAGS := -std=c11 -O2 -g -Iinclude -Wall -Wextra -Werror -Wshadow
SANITIZE := -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all

SOURCES := src/vspace.c src/elf.c src/patch.c
HEADERS := include/v2/vspace.h include/v2/elf.h include/v2/patch.h \
           include/v2/cpu.h include/v2/proc.h include/v2/stack.h \
           include/v2/fsops.h include/v2/vmops.h include/v2/sysnames.h \
           include/v2/host_darwin.h

# The part that can execute guest code.  macOS on aarch64 only: the guest is
# aarch64 Linux, so the host has to be the same instruction set.
GUEST_SOURCES := src/vspace.c src/elf.c src/patch.c src/proc.c src/stack.c \
                 src/syscall.c src/fsops.c src/vmops.c src/sysnames.c \
                 src/entry_aarch64.c \
                 src/host_darwin.c src/runner.c

all: $(BUILD)/test_vspace $(BUILD)/test_elf $(BUILD)/test_stack

$(BUILD)/test_vspace: $(SOURCES) tests/test_vspace.c $(HEADERS)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SANITIZE) -o $@ $(SOURCES) tests/test_vspace.c

$(BUILD)/test_elf: $(SOURCES) tests/test_elf.c $(HEADERS)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SANITIZE) -o $@ $(SOURCES) tests/test_elf.c

$(BUILD)/test_stack: $(SOURCES) src/stack.c tests/test_stack.c $(HEADERS)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SANITIZE) -o $@ $(SOURCES) src/stack.c tests/test_stack.c

test: $(BUILD)/test_vspace $(BUILD)/test_elf $(BUILD)/test_stack
	@$(BUILD)/test_vspace --trace tests/trace/basic.tsv \
	                          tests/trace/tight.tsv \
	                          tests/trace/wide.tsv
	@$(BUILD)/test_vspace --random 400 1
	@$(BUILD)/test_vspace --random 400 99
	@$(BUILD)/test_vspace --random 400 12345
	@$(BUILD)/test_vspace --guard-random 400 7
	@$(BUILD)/test_elf
	@$(BUILD)/test_stack

# Workstation build.  There is no MSVC and no Xcode on this machine, so zig cc
# (installed on F:) cross-links the same files for Windows; the binaries run the
# identical code path as CI except for pread(), which is POSIX-only.
ZIG ?= F:/tools/ziglang/ziglang/zig.exe
ZIGCACHE ?= F:/tools/zig-cache

windows:
	@mkdir -p $(BUILD)
	ZIG_GLOBAL_CACHE_DIR=$(ZIGCACHE) ZIG_LOCAL_CACHE_DIR=$(ZIGCACHE)/local \
	  $(ZIG) cc -target x86_64-windows-gnu -std=c11 -O1 -g -Iinclude \
	  -Wall -Wextra -Werror -Wshadow -o $(BUILD)/test_vspace.exe \
	  $(SOURCES) tests/test_vspace.c
	ZIG_GLOBAL_CACHE_DIR=$(ZIGCACHE) ZIG_LOCAL_CACHE_DIR=$(ZIGCACHE)/local \
	  $(ZIG) cc -target x86_64-windows-gnu -std=c11 -O1 -g -Iinclude \
	  -Wall -Wextra -Werror -Wshadow -o $(BUILD)/test_elf.exe \
	  $(SOURCES) tests/test_elf.c
	ZIG_GLOBAL_CACHE_DIR=$(ZIGCACHE) ZIG_LOCAL_CACHE_DIR=$(ZIGCACHE)/local \
	  $(ZIG) cc -target x86_64-windows-gnu -std=c11 -O1 -g -Iinclude \
	  -Wall -Wextra -Werror -Wshadow -o $(BUILD)/test_stack.exe \
	  $(SOURCES) src/stack.c tests/test_stack.c
	@$(BUILD)/test_vspace.exe --trace tests/trace/basic.tsv \
	                              tests/trace/tight.tsv \
	                              tests/trace/wide.tsv
	@$(BUILD)/test_vspace.exe --random 400 1
	@$(BUILD)/test_vspace.exe --guard-random 400 1
	@$(BUILD)/test_elf.exe
	@$(BUILD)/test_stack.exe

traces:
	@python3 tools/vspace_model.py --trace tests/trace/basic.tsv --seed 1  --ops 400 --pages 2048
	@python3 tools/vspace_model.py --trace tests/trace/tight.tsv --seed 7  --ops 300 --pages 256
	@python3 tools/vspace_model.py --trace tests/trace/wide.tsv  --seed 3  --ops 600 --pages 8192

model:
	@python3 tools/vspace_model.py --check 60 --ops 300 --pages 2048

# Pre-compiler check: a hand transcription of src/vspace.c replayed against
# the same traces.  Only useful where there is no C toolchain.
port:
	@python3 tools/vspace_c_port.py tests/trace/basic.tsv \
	                                tests/trace/tight.tsv \
	                                tests/trace/wide.tsv

# ---------------------------------------------------------------- guest

$(BUILD)/guest-runner: $(GUEST_SOURCES) $(HEADERS)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ $(GUEST_SOURCES)

guest: $(BUILD)/guest-runner

# Runs a real Linux ELF on the host.  Only meaningful on macOS/aarch64.
guest-test: $(BUILD)/guest-runner
	@$(BUILD)/guest-runner --root . tests/guest/hello > $(BUILD)/guest.out 2>&1
	@grep -q "hello from guest" $(BUILD)/guest.out
	@echo "guest ok: $$(grep -c 'hello from guest' $(BUILD)/guest.out) line(s)"

clean:
	@rm -f $(BUILD)/test_vspace $(BUILD)/test_elf $(BUILD)/test_stack $(BUILD)/guest-runner

.PHONY: all test windows guest guest-test traces model port clean
