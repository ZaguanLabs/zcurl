# Address and undefined-behavior checks

```zsh
make ubsan
```

This builds `build/ubsan/zcurl.so` and runs the complete integration suite with
the instrumented module. The ordinary `build/zcurl.so` is left untouched. Both
variants share source/header dependencies and compiler/linker configuration;
the UBSan variant adds `-O1 -g -fno-omit-frame-pointer -fsanitize=undefined
-fno-sanitize-recover=all`.

The target requires a compiler with UndefinedBehaviorSanitizer support, the
matching runtime library, and `nm` for checking the selected module. The current
run passed with GCC 15.2.0, installed Zsh 5.9.2, and the libcurl environment in
[validation notes](validation.md).

UBSan adds runtime checks for categories such as invalid shifts, signed integer
overflow, misalignment and selected bounds violations. Recovery is disabled so
a detected error terminates the affected process. See
[GCC's instrumentation options](https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html).

## AddressSanitizer

```zsh
make asan
```

This builds `build/asan/zcurl.so` with `-O1 -g -fno-omit-frame-pointer
-fsanitize=address,undefined -fno-sanitize-recover=all` and runs the complete
suite, including the loader, examples, completion and signal PTYs. It adds
checks for memory access errors such as heap buffer overflows and use after
free. Normal and UBSan-only modules remain separate. `make clean` removes all
three module variants and their temporary output files.

The demonstrated setup is GCC on Linux. Install the matching ASan runtime and
development linker files alongside the compiler. The Makefile asks the selected
`CC` for `libasan.so`; an unavailable runtime fails the build with a diagnostic.
For a runtime outside the compiler's search path:

```zsh
make asan ASAN_RUNTIME=/absolute/path/to/libasan.so
```

The directory must contain the matching `libasan.so` linker file and its runtime
library. The target adds that directory to the ASan build's library search path.
This session used verified Mageia GCC 15.2.0 `libasan8` and `libasan-devel` RPMs
extracted locally under `.deps/asan-runtime`, without installing packages:

```zsh
make asan ASAN_RUNTIME="$PWD/.deps/asan-runtime/usr/lib64/libasan.so"
```

That local extraction is ignored by Git and is not a dependency download step
performed by the target. Other developers need their own matching runtime.

The installed Zsh executable is not ASan-linked, so the harness puts the runtime
first in `LD_PRELOAD` for test children. It does not change the invoking shell,
Python harness or system loader configuration. Existing preload entries follow
the runtime. Paths containing whitespace or colons are rejected because they
cannot be represented as one `LD_PRELOAD` entry. Use the same compiler/runtime
pair for building and testing; this setup does not claim Clang or non-Linux support.

`ASAN_OPTIONS` enables fatal errors and per-process reports. LeakSanitizer is
disabled (`detect_leaks=0`); the existing Valgrind target remains the leak check.
The module has compiler instrumentation. Zsh, libcurl and TLS libraries are not
rebuilt with it, although ASan's allocator and library interceptors can also
observe operations outside the module. Zsh's internal heap allocation boundaries
are not individually instrumented. See the [ASan overview](https://github.com/google/sanitizers/wiki/AddressSanitizer).

## Selecting the tested library

The harness prints the selected module path. To rerun an existing build:

```zsh
python3 tests/integration.py --ubsan
python3 tests/integration.py --module-dir build/ubsan --ubsan
python3 tests/integration.py --asan --asan-runtime /absolute/path/to/libasan.so
```

`--ubsan` defaults to `build/ubsan`, `--asan` to `build/asan`, and ordinary runs
to `build`. `--asan` and `--asan-runtime` must be supplied together. An absent
module fails before fixtures start. A UBSan run rejects a library without UBSan
handler references, preventing accidental selection of an uninstrumented build.
This presence check does not prove every function is instrumented; use the
provided build target for the intended compiler flags.
ASan selection requires both ASan and UBSan handler references; selecting an
ASan module in UBSan-only mode is also rejected.

`--module-dir` also supports other builds without sanitizer mode. For alternate
directories the harness copies the real loader and examples into a temporary
project whose `build/zcurl.so` points to the selected module. Thus their relative
loader paths cannot silently select the checkout's normal library. Completion
and signal PTYs use the same module directory directly.

## Failure reporting and scope

The fixture sets `UBSAN_OPTIONS` for fatal errors, stack traces and per-process
reports in its temporary directory; ASan mode also sets `ASAN_OPTIONS` and
collects both report types. Reports from any child fail the suite,
including a subshell whose nonzero exit was expected by a test. Diagnostics are
included in the Python failure before the temporary directory is removed.
Independent signed-overflow and heap-buffer-overflow probes verified this
failure path. The ASan probe's parent shell deliberately ignored its child's
failure and exited successfully; the collected report still failed the fixture.

The instrumented code is zcurl's C module. This does not rebuild or instrument
the installed Zsh, libcurl, TLS libraries or other dependencies. Unlike the
Valgrind target, both sanitizer targets cover module code executed by the examples
and interactive PTY tests. These runs do not prove all C behavior is safe; coverage is
limited to executed paths and enabled sanitizer checks.

Run `make memcheck` separately for the existing memory-access and leak checks.
The harness rejects sanitizer modes combined with `--valgrind` or `--benchmark`,
and rejects `--asan` combined with `--ubsan` (ASan already includes UBSan).
Thread and memory sanitizers, other compilers and other platforms remain
outside the demonstrated scope.
