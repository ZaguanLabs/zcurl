ZSH_SRC ?= $(CURDIR)/.deps/zsh-5.9.2
CC ?= cc
CFLAGS ?= -O2 -g
CURL_CFLAGS := $(shell pkg-config --cflags libcurl)
CURL_LIBS := $(shell pkg-config --libs libcurl)
ASAN_RUNTIME ?= $(shell $(CC) -print-file-name=libasan.so)
TEST_TIMEOUT ?= 240s
TEST_WATCHDOG = timeout --verbose --kill-after=5s "$(TEST_TIMEOUT)"

.PHONY: all test check package test-package benchmark benchmark-headers memcheck ubsan asan clean FORCE
all: build/zcurl.so

ZSH_HEADERS := $(wildcard $(ZSH_SRC)/config.h $(ZSH_SRC)/Src/*.h $(ZSH_SRC)/Src/*.mdh $(ZSH_SRC)/Src/*.epro)
quote_setting = '$(subst ','"'"',$(1))'

# A different header tree or compiler flags must rebuild even when its files
# have older timestamps than the existing module.
build/.build-settings build/ubsan/.build-settings build/asan/.build-settings: FORCE
	mkdir -p "$(@D)"
	@printf '%s\n' $(call quote_setting,$(abspath $(ZSH_SRC))) $(call quote_setting,$(CC)) \
	    $(call quote_setting,$(CPPFLAGS)) $(call quote_setting,$(CFLAGS)) $(call quote_setting,$(CURL_CFLAGS)) \
	    $(call quote_setting,$(LDFLAGS)) $(call quote_setting,$(CURL_LIBS)) \
	    $(call quote_setting,$(MODULE_SANITIZER_FLAGS)) $(call quote_setting,$(MODULE_ASAN_RUNTIME)) > $@.tmp
	@if cmp -s $@.tmp $@; then rm -f $@.tmp; else mv -f $@.tmp $@; fi

build/ubsan/zcurl.so: MODULE_SANITIZER_FLAGS = -O1 -g -fno-omit-frame-pointer -fsanitize=undefined -fno-sanitize-recover=all
build/asan/zcurl.so: MODULE_SANITIZER_FLAGS = -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all -L"$(dir $(ASAN_RUNTIME))"
build/asan/zcurl.so: MODULE_ASAN_RUNTIME = $(ASAN_RUNTIME)

build/zcurl.so: build/.build-settings
build/ubsan/zcurl.so: build/ubsan/.build-settings
build/asan/zcurl.so: build/asan/.build-settings

build/zcurl.so build/ubsan/zcurl.so build/asan/zcurl.so: src/zcurl.c src/websocket.c src/http_async.c src/http_headers.c src/http_sessions.c src/polling.c $(ZSH_HEADERS) Makefile
	@pkg-config --atleast-version=8.16.0 libcurl || { echo 'libcurl development files >=8.16.0 are required.'; exit 1; }
	@test -f "$(ZSH_SRC)/Src/zsh.mdh" || { echo 'Prepare Zsh headers first; see README.md.'; exit 1; }
	@test -z "$(MODULE_ASAN_RUNTIME)" || test -f "$(MODULE_ASAN_RUNTIME)" || { echo 'ASan runtime missing; install the matching compiler runtime or set ASAN_RUNTIME.'; exit 1; }
	mkdir -p "$(@D)"
	$(CC) $(CPPFLAGS) $(CFLAGS) $(MODULE_SANITIZER_FLAGS) -std=c99 -Wall -Wextra -fPIC -shared \
	    -I"$(ZSH_SRC)/Src" -I"$(ZSH_SRC)" $(CURL_CFLAGS) src/zcurl.c \
	    $(LDFLAGS) $(CURL_LIBS) -o $@.tmp
	mv -f $@.tmp $@

check:
	@for file in zcurl.zsh completions/_zcurl scripts/*.zsh tests/*.zsh examples/*.zsh; do zsh -dfn "$$file" || exit; done

build/tests/ws-send-again.so: tests/ws-send-again.c
	mkdir -p "$(@D)"
	$(CC) $(CPPFLAGS) $(CFLAGS) -Wall -Wextra -fPIC -shared $(CURL_CFLAGS) $< -ldl -o $@

test: all check build/tests/ws-send-again.so
	$(TEST_WATCHDOG) python3 -u tests/integration.py

package: all check
	python3 scripts/package.py --zsh-source "$(ZSH_SRC)"

test-package: all check
	$(TEST_WATCHDOG) python3 -u tests/package.py "$(ZSH_SRC)"

benchmark: all check build/tests/ws-send-again.so
	$(TEST_WATCHDOG) python3 -u tests/integration.py --benchmark

benchmark-headers: all check
	$(TEST_WATCHDOG) zsh -df scripts/benchmark-headers.zsh

memcheck: all check build/tests/ws-send-again.so
	$(TEST_WATCHDOG) python3 -u tests/integration.py --valgrind

ubsan: build/ubsan/zcurl.so check build/tests/ws-send-again.so
	$(TEST_WATCHDOG) python3 -u tests/integration.py --module-dir build/ubsan --ubsan

asan: build/asan/zcurl.so check build/tests/ws-send-again.so
	$(TEST_WATCHDOG) python3 -u tests/integration.py --module-dir build/asan --asan --asan-runtime "$(ASAN_RUNTIME)"

clean:
	rm -f build/zcurl.so build/zcurl.so.tmp build/ubsan/zcurl.so build/ubsan/zcurl.so.tmp build/asan/zcurl.so build/asan/zcurl.so.tmp
	rm -f build/tests/ws-send-again.so
