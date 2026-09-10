# Undefined-behavior checks

```zsh
make ubsan
```

This builds `build/ubsan/zcurl.so` and runs the complete integration suite with
the instrumented module. The ordinary `build/zcurl.so` is left untouched. Both
variants share source/header dependencies and compiler/linker configuration;
the UBSan variant adds `-O1 -g -fno-omit-frame-pointer -fsanitize=undefined
-fno-sanitize-recover=all`. `make clean` removes both generated modules.

The target requires a compiler with UndefinedBehaviorSanitizer support, the
matching runtime library, and `nm` for checking the selected module. The current
run passed with GCC 15.2.0, installed Zsh 5.9.2, and the libcurl environment in
[validation notes](validation.md).

UBSan adds runtime checks for categories such as invalid shifts, signed integer
overflow, misalignment and selected bounds violations. Recovery is disabled so
a detected error terminates the affected process. See
[GCC's instrumentation options](https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html).

## Selecting the tested library

The harness prints the selected module path. To rerun an existing build:

```zsh
python3 tests/integration.py --ubsan
python3 tests/integration.py --module-dir build/ubsan --ubsan
```

`--ubsan` defaults to `build/ubsan`; ordinary runs default to `build`. An absent
module fails before fixtures start. A UBSan run rejects a library without UBSan
handler references, preventing accidental selection of an uninstrumented build.
This presence check does not prove every function is instrumented; use the
provided build target for the intended compiler flags.

`--module-dir` also supports other builds without sanitizer mode. For alternate
directories the harness copies the real loader and examples into a temporary
project whose `build/zcurl.so` points to the selected module. Thus their relative
loader paths cannot silently select the checkout's normal library. Completion
and signal PTYs use the same module directory directly.

## Failure reporting and scope

The fixture sets `UBSAN_OPTIONS` for fatal errors, stack traces and per-process
reports in its temporary directory. Reports from any child fail the suite,
including a subshell whose nonzero exit was expected by a test. Diagnostics are
included in the Python failure before the temporary directory is removed.
An independent signed-overflow probe was used to verify this failure path.

The instrumented code is zcurl's C module. This does not rebuild or instrument
the installed Zsh, libcurl, TLS libraries or other dependencies. Unlike the
Valgrind target, UBSan also covers module code executed by the examples and
interactive PTY tests. Neither run proves all C behavior is safe; coverage is
limited to executed paths and enabled sanitizer checks.

Run `make memcheck` separately for the existing memory-access and leak checks.
The harness rejects UBSan combined with `--valgrind` or `--benchmark`. Address,
thread and memory sanitizers, other compilers and other platforms remain
outside the demonstrated scope.
