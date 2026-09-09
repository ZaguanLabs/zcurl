ZSH_SRC ?= $(CURDIR)/.deps/zsh-5.9.2
CC ?= cc
CFLAGS ?= -O2 -g
CURL_CFLAGS := $(shell pkg-config --cflags libcurl)
CURL_LIBS := $(shell pkg-config --libs libcurl)

.PHONY: all test check benchmark memcheck clean
all: build/zcurl.so

ZSH_HEADERS := $(wildcard $(ZSH_SRC)/config.h $(ZSH_SRC)/Src/*.h $(ZSH_SRC)/Src/*.mdh $(ZSH_SRC)/Src/*.epro)

build/zcurl.so: src/zcurl.c src/websocket.c src/http_async.c $(ZSH_HEADERS) Makefile
	@pkg-config --atleast-version=8.16.0 libcurl || { echo 'libcurl development files >=8.16.0 are required.'; exit 1; }
	@test -f "$(ZSH_SRC)/Src/zsh.mdh" || { echo 'Prepare Zsh headers first; see README.md.'; exit 1; }
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c99 -Wall -Wextra -fPIC -shared \
	    -I"$(ZSH_SRC)/Src" -I"$(ZSH_SRC)" $(CURL_CFLAGS) $< \
	    $(LDFLAGS) $(CURL_LIBS) -o $@.tmp
	mv -f $@.tmp $@

check:
	@for file in zcurl.zsh scripts/*.zsh tests/*.zsh examples/*.zsh; do zsh -dfn "$$file" || exit; done

test: all check
	python3 tests/integration.py

benchmark: all check
	python3 tests/integration.py --benchmark

memcheck: all check
	python3 tests/integration.py --valgrind

clean:
	rm -f build/zcurl.so build/zcurl.so.tmp
