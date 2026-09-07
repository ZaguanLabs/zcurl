# Validation of 0.3.0-dev

Environment: installed Zsh 5.9.2, Mageia x86_64, libcurl 8.21.0 with OpenSSL
3.5.7. The module builds with `-std=c99 -Wall -Wextra`; an additional syntax
check treats warnings as errors. Other Zsh builds and platforms are untested.

## Reproduce

```zsh
make test
make memcheck
make benchmark
```

The Python fixture creates HTTP/1.1 loopback servers and a one-day localhost
certificate under a temporary directory, including a non-ASCII path. The
test shell has proxy variables removed and runs with `zsh -df`.
No public endpoints, account credentials or system certificate changes are used.

## Coverage

- Actual builtin load/unload/reload; repeated verified HTTPS requests using
  one connection independently counted by the server.
- Untrusted certificate rejection, hostname mismatch rejection and CA option
  reset; HTTP status separate from transport status.
- POST/PUT/PATCH/DELETE/HEAD, empty POST, literal `@` data, all 256 byte values,
  embedded NUL, trailing newlines, JSON/authentication/duplicate headers, and
  server-observed absence of request state on the following GET.
- Caller-owned associative results, full replacement, snapshots surviving
  later calls/unload, dynamic scope, and adverse caller options.
- Invalid names/subscripts, special/readonly/converting targets, bad methods,
  header control characters and invalid numeric/options syntax. These cases
  are checked to cause no HTTP requests.
- Bounded body/headers, timeout, truncated Content-Length, chunked bodies,
  response trailers, duplicate headers and interim response headers.
- `--fail` retains error bodies; `--reset` opens a new connection next time;
  invalid ordinary calls clear global result state.
- Project loader preserving module paths and aliases, idempotent loading,
  and the runnable example invoked outside the repository.
- A real PTY checks Ctrl-C recovery. SIGUSR1 traps change the result target,
  attempt request reentry and attempt active-module unload. The shell
  remains usable, the outer request remains coherent, and changed targets
  are not overwritten.

The synchronous multi driver queues Zsh signals around libcurl calls and
delivers them between calls. Tests establish these specific behaviors, not
every resolver, signal trap, job-control combination, or backend behavior.

## WebSocket coverage

`make test` and `make memcheck` also run a Python standard-library RFC 6455
fixture, independently encoding and checking wire frames. The 0.3.0-dev run
passed both targets and a C syntax check with `-Wall -Wextra -Werror`. The
memory-check output is recorded locally in `build/websocket-valgrind.log`.

- WS and verified WSS handles coexist with persistent HTTP requests; explicit
  handshake authentication headers, untrusted and mismatched TLS certificates,
  rejected upgrades, scheme restrictions and handshake deadlines.
- All 256 byte values, NUL/trailing newlines, empty frames, and a 4 MB frame
  round-trip through incremental receive and partial queued sends. The fixture
  delays reads to exercise sender backpressure and checks client masking.
- Text fragmented across UTF-8 character boundaries, interleaved PING/PONG,
  explicit unsolicited PONG, and automatically queued matching PONG payloads.
- One-byte receive chunks and offsets from a frame whose payload arrives in
  two network writes; frame/message completion metadata.
- Transactional queue rejection and retry, invalid fragment type rejection,
  256 empty-frame queue limit, duplicate names and the 32-handle limit.
- Local/peer close handshakes, close reasons, empty peer close, abrupt EOF,
  malformed UTF-8/close payloads, receive message bounds, retained terminal
  diagnoses, reset/unload cleanup, and snapshots/dynamic-scope destinations.
- A fork inheriting the module is rejected while the parent connection remains
  usable. PTY tests exercise Ctrl-C during WS poll and handshake, reentrant
  calls, unload attempts, and a signal trap replacing a result destination.

The stalled-upgrade fixture exposed a connect-only handshake that outlasted
`CURLOPT_TIMEOUT_MS` on this libcurl build. The module therefore enforces a
monotonic handshake deadline in addition to libcurl's configured timeouts.
Backend blocking caveats remain; this is not a hard real-time guarantee.

The WS build minimum is now libcurl 8.16.0; this environment's 8.21.0 is the
only version validated here. Proxy/subprotocol policy, other TLS backends,
platforms and libcurl versions, ZLE integration, and the Blade application
protocol still require integration testing. See [the API contract](websocket.md).

## Memory checks and dependency findings

`make memcheck` runs the scripted test shells under Valgrind with full leak
checking and an error exit for memory errors and definitely lost allocations.
PTY tests and the separately executed example remain uninstrumented.

Unfiltered Valgrind reports two allocation stacks after loading/unloading
this machine's libcurl: 16 bytes in libgpg-error and 192 bytes (144 direct,
48 indirect) in libgcrypt, both from a libssh constructor. One load/unload
of libcurl alone reproduces them, without Zsh, zcurl, curl initialization,
or networking:

```zsh
cc -g tests/libcurl-load.c -ldl -o build/libcurl-load
valgrind --keep-debuginfo=yes --leak-check=full \
    --show-leak-kinds=definite build/libcurl-load
```

The normal memory-check target excludes only those two exact allocation
stacks via `tests/valgrind-libcurl.supp`, including the observed Mageia shared
library versions and constructor frames. Module allocations and all memory
access errors remain checked. Repeated unload/reload repeats the dependency
allocations; the module does not attempt to alter those libraries' global
lifecycle. New library versions may require a fresh baseline investigation.

`build/valgrind.log` records the refinement-session run. The ignore-listed
build artifacts are local evidence, not prerequisites for running the tests.

## Performance scope

The benchmark compares the native module, one curl process per URL, and one
curl process receiving all URLs. It uses 100 sequential three-byte HTTPS
responses by default, three rounds, and rotated ordering. Times include shell
startup and the relevant module/process startup. Server connection counts are
reported separately. Run benchmarks without concurrent memory checks or other
heavy work. This is a loopback overhead experiment, not a WAN throughput test.

File/descriptor streaming, concurrent transfers, arbitrary fork inheritance,
automatic redirects, cookies, named sessions, HTTP/2/3-specific behavior,
proxy integration and cross-platform ABI compatibility still need their own
implementation and/or test coverage before being relied on.
