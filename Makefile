ZSH_SRC ?= $(CURDIR)/.deps/zsh-5.9.2
CC ?= cc
CFLAGS ?= -O2 -g
CURL_CFLAGS := $(shell pkg-config --cflags libcurl)
CURL_LIBS := $(shell pkg-config --libs libcurl)
ASAN_RUNTIME ?= $(shell $(CC) -print-file-name=libasan.so)

.PHONY: all test check benchmark memcheck ubsan asan clean
all: build/zcurl.so

ZSH_HEADERS := $(wildcard $(ZSH_SRC)/config.h $(ZSH_SRC)/Src/*.h $(ZSH_SRC)/Src/*.mdh $(ZSH_SRC)/Src/*.epro)

build/ubsan/zcurl.so: MODULE_SANITIZER_FLAGS = -O1 -g -fno-omit-frame-pointer -fsanitize=undefined -fno-sanitize-recover=all
build/asan/zcurl.so: MODULE_SANITIZER_FLAGS = -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all -L"$(dir $(ASAN_RUNTIME))"
build/asan/zcurl.so: MODULE_ASAN_RUNTIME = $(ASAN_RUNTIME)

build/zcurl.so build/ubsan/zcurl.so build/asan/zcurl.so: src/zcurl.c src/websocket.c src/http_async.c src/http_headers.c src/http_sessions.c $(ZSH_HEADERS) Makefile
	@pkg-config --atleast-version=8.16.0 libcurl || { echo 'libcurl development files >=8.16.0 are required.'; exit 1; }
	@test -f "$(ZSH_SRC)/Src/zsh.mdh" || { echo 'Prepare Zsh headers first; see README.md.'; exit 1; }
	@test -z "$(MODULE_ASAN_RUNTIME)" || test -f "$(MODULE_ASAN_RUNTIME)" || { echo 'ASan runtime missing; install the matching compiler runtime or set ASAN_RUNTIME.'; exit 1; }
	mkdir -p "$(@D)"
	$(CC) $(CPPFLAGS) $(CFLAGS) $(MODULE_SANITIZER_FLAGS) -std=c99 -Wall -Wextra -fPIC -shared \
	    -I"$(ZSH_SRC)/Src" -I"$(ZSH_SRC)" $(CURL_CFLAGS) $< \
	    $(LDFLAGS) $(CURL_LIBS) -o $@.tmp
	mv -f $@.tmp $@

check:
	@for file in zcurl.zsh completions/_zcurl scripts/*.zsh tests/*.zsh examples/*.zsh; do zsh -dfn "$$file" || exit; done

test: all check
	python3 tests/integration.py

benchmark: all check
	python3 tests/integration.py --benchmark

memcheck: all check
	python3 tests/integration.py --valgrind

ubsan: build/ubsan/zcurl.so check
	python3 tests/integration.py --module-dir build/ubsan --ubsan

asan: build/asan/zcurl.so check
	python3 tests/integration.py --module-dir build/asan --asan --asan-runtime "$(ASAN_RUNTIME)"

clean:
	rm -f build/zcurl.so build/zcurl.so.tmp build/ubsan/zcurl.so build/ubsan/zcurl.so.tmp build/asan/zcurl.so build/asan/zcurl.so.tmp
