# Validation of 0.14.0-dev

Environment: installed Zsh 5.9.2, Mageia x86_64, libcurl 8.21.0 with OpenSSL
3.5.8. The module builds with `-std=c99 -Wall -Wextra`; an additional syntax
check treats warnings as errors. Other Zsh builds and platforms are untested.

## Reproduce

```zsh
make test
make memcheck
make ubsan
make benchmark
```

The Python fixture creates HTTP/1.1 loopback servers and a one-day localhost
certificate under a temporary directory, including a non-ASCII path. The
test shell has inherited proxy variables removed and runs with `zsh -df`.
Proxy-specific tests install their own loopback proxy environment.
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

## Descriptor-ownership coverage

- Six simultaneous synchronous/concurrent HTTP/HTTPS and WS/WSS connection
  sockets, all at descriptor numbers >=10. Ordinary `{fd}` closure and
  duplication attempts fail; subsequent HTTP reuse and WS/WSS binary I/O work.
- Actual socket close-on-exec flags checked through Linux `/proc`, with no
  connection identities inherited by an executed child.
- Private input/output duplicates rejecting closure and duplication, while
  closing their caller-owned originals still permits an exact binary transfer.
- Reset, WS drop, and three unload/reload cycles releasing sockets. Cached
  HTTP sockets outlive their creating easy handles and still close correctly.
- Caller-owned descriptors occupying 3..9 before connection creation, with
  registration and cleanup of sockets opened above that range.

These checks cover connection sockets and retained file duplicates, not every
descriptor opened internally by libcurl backends. See [the scope](descriptors.md).

## HTTP and WebSocket proxy coverage

- Environment defaults, explicit direct routing, host/list/wildcard/CIDR
  bypasses, empty-list overrides and per-request reset without environment edits.
- Concurrent direct and proxied requests crossing an origin response barrier;
  copied proxy/bypass strings surviving submitting-function scope.
- HTTP forwarding, HTTPS CONNECT and connection reuse; origin certificate and
  hostname rejection, refused tunnels and refused proxy connections with no
  direct fallback.
- Origin authorization/custom headers absent from CONNECT, Basic proxy URL
  credentials, credential reset and no proxy authorization in tunneled requests.
- Exact binary concurrent file output through CONNECT, and invalid options
  rejected before either proxy or origin requests.
- WS/WSS CONNECT routing, explicit and inherited settings, bypass overrides,
  mixed direct/proxied handles and function-local option strings.
- Authenticated WebSocket tunnels with origin authentication kept out of CONNECT
  and proxy credentials kept out of the origin handshake; binary frames,
  fragmented UTF-8, interleaved ping/pong, graceful close and reset/unload.
- WebSocket TLS, authentication, refused tunnel and connection failures retain
  no handle; invalid routing options are rejected before I/O.

- HTTPS proxy forwarding and CONNECT with a separate proxy certificate; proxy
  and origin trust remain independent, including hostname verification.
- Proxy CA path ownership in concurrent jobs, option reset, binary bodies through
  nested TLS, authenticated WS/WSS tunnels and proxy CA filename completion.

Loopback HTTP and HTTPS proxies are covered with OpenSSL. See [routing and limitations](proxy.md).

## HTTP compression coverage

- Gzip and zlib deflate generated independently by the loopback fixture; all
  byte values and trailing newlines preserved in scalars and output files.
- HTTP and verified HTTPS, concurrent scalar/file output, mixed decoding
  policies, unchanged snapshot shapes, file upload and uncompressed responses.
- Server-observed negotiation, literal header override/suppression, raw default
  behavior, and synchronous option reset on a reused connection.
- HEAD and decoded HTTP error bodies; unknown encodings and corrupt gzip in
  synchronous/concurrent requests, followed by successful requests.
- An inclusive scalar limit and decoded expansion limits for scalars and files;
  Python independently checks actual output bytes. Invalid/duplicate flags and
  non-HTTP use cause no network requests.

Gzip/deflate support in the linked libcurl is required for these tests. Other
decoders and every form of damaged stream are not covered; see
[compression behavior](compression.md).

## Handle-discovery coverage

- Empty arrays, creation order, separate namespaces, duplicate rejection,
  cancellation/completion/closure retention, collection/drop, and name reuse.
- Unchanged result fields and no server-observed I/O from reads; an expired
  submission stays pending until explicitly driven.
- Readonly enforcement, inherited child arrays empty while parent arrays remain
  intact, and indexing under `KSH_ARRAYS`.
- Feature disable/enable preserving handles, reset emptying arrays, and three
  unload/reload cycles with copied arrays surviving teardown.

## Completion coverage

An isolated Zsh PTY initializes actual compsys and invokes the registered ZLE
completion widget. The test checks 112 resulting command buffers, including:

- HTTP, WebSocket and header-lookup subcommands; operation-specific flags;
  handle positions and the handle-free `http poll` grammar.
- Variadic `wait-any` handle positions, interspersed options, `--`, namespace
  filtering and fallback when discovery is disabled or the module is unloaded.
- Live names for every existing-handle operation, namespace separation, no
  suggestions for new names, and updates after drop and feature toggling.
- Methods, frame types, body/HEAD exclusions, repeated headers, options after
  a URL, end-of-options handling, and unsupported attached argument forms.
- HTTP-only `--compressed` suggestions and suppression after use.
- HTTP and WebSocket-open proxy/bypass flags, short aliases, duplicate suppression
  and scheme prefixes; routing options are absent from other operations.
- Associative versus indexed result arrays; filtering readonly, converting,
  unique and non-ASCII names.
- CA filenames containing spaces and brackets, URL scheme prefixes, mid-word
  insertion with `COMPLETE_IN_WORD`, aliases and a custom matcher style.
- Completion after module unload, unchanged HTTP result parameters, and no
  invocation of `zcurl` or server-observed network requests during completion.

These are interactive completion checks on installed Zsh 5.9.2. They do not
validate every framework or third-party completer. See [setup and behavior](completion.md).

## Header-lookup coverage

`zcurl headers` is tested with actual HTTP responses and synthetic libcurl-style
callback transcripts. Coverage includes:

- Case-insensitive lookup, repeated `Set-Cookie`, identical duplicates, empty
  values and missing fields, with stable order and no comma splitting.
- Informational, proxy CONNECT and authentication blocks; HTTP/2 and HTTP/3
  status-line forms; 101 upgrades; separate chunked-trailer lookup.
- CRLF and LF lines, outer whitespace, legacy folding (including empty folds),
  bytes above ASCII, and literal shell-looking values.
- Synchronous and saved concurrent snapshots, lookup while a completed job is
  retained, and preservation of transfer metadata and errors on both success
  and failure. Arrays remain available after unload.
- Partial header sections consisting of complete lines; malformed status/field
  lines, orphan folds, NUL/control bytes and unterminated lines; the inclusive
  256 KiB input boundary and rejection above it without partial publication.
- Indexed-array validation, rejecting subscripts, absent/scalar/associative,
  special, readonly, converting and unique targets. Dynamic scope works under
  adverse caller options, including `KSH_ARRAYS`.

The lookup does not establish transfer completeness or interpret field-specific
semantics. HTTP/2/3 parsing fixtures validate their rendered status-line forms,
not network negotiation of those protocols. See [the contract](headers.md).

## File-output coverage

`--output-fd` is tested for synchronous HTTP and concurrent HTTPS with ordinary
regular files. Binary file contents are checked independently in Python.

- All 256 byte values, NUL and trailing newlines; an 8 MiB-plus response written
  without a scalar body; raw byte counts and unchanged result shapes.
- Existing file offsets and append mode; original descriptors still writable
  after synchronous transfers; closing/reusing originals after submission.
- Private duplicates absent in executed children, released before collection,
  and released by cancellation, drop, reset and unload. Linux `/proc` checks
  count descriptors for the specific fixture files.
- Invalid, read-only and nonregular destinations rejected before HTTP I/O;
  body-limit and HTTP-error responses; a cancelled response retaining its prefix.
- A per-shell file-size limit forcing a short write followed by a write error,
  with status 23, `error_kind=output`, and the exact byte count checked on disk.
- All 32 file-output jobs fitting without scalar-body reservations even with
  large response limits; reset releasing their duplicate descriptors.

File output remains bounded by `--max-body`. Pipe/socket backpressure and
filesystem durability are outside this milestone; see [the contract](file-output.md).

## File-upload coverage

`--data-fd` is tested for synchronous and concurrent HTTP/HTTPS, including a
combined upload/download through file descriptors.

- All 256 byte values, NUL and trailing newlines, default POST, explicit PUT and
  PATCH, empty files, and offsets beyond EOF. Python independently checks bytes.
- Captured start offsets without changing the caller's position; two jobs
  reading independent ranges from the same descriptor despite later seeks,
  closure and reuse of the original descriptor.
- An 8 MiB-plus binary file-to-file HTTPS round trip with an empty result body.
- File growth excluded from a captured range; truncation producing status/code
  42, `error_kind=input`, and a specific premature-EOF diagnostic.
- Private duplicates absent in executed children and released before collection,
  on cancellation, drop, reset, unload, expired submission deadlines, TLS failure,
  and invalid output setup. Read-only and read/write sources are exercised.
- Invalid/write-only/nonregular sources and conflicting options rejected before
  HTTP I/O; following literal POST and GET requests restoring ordinary behavior.
- All 32 jobs accepting a 160 MiB sparse source without payload reservations;
  reset closes the duplicates without uploading those files.

Pipe/socket sources, filesystem blocking bounds and application-level upload
acknowledgments remain outside the contract. See [file uploads](file-input.md).

## Concurrent HTTP coverage

The 0.4.0-dev implementation and existing transports pass `make test`,
`make memcheck`, and a C syntax check with `-Wall -Wextra -Werror` on the
environment above. Tests run in fresh shells and include:

- HTTP and verified HTTPS response barriers that require two requests to arrive
  before either can complete, establishing overlap without a speed threshold.
- Submission and cancellation before polling causing no server-observed I/O;
  binary upload, methods, headers, URL and CA configuration surviving the
  submitting function's scope; exact bytes checked independently in Python.
- Connection reuse after collection, retained snapshots, and dynamic-scope
  collection under adverse shell options.
- A fast response completing while a partial response is held by a server gate;
  cancelling that partial response retains its bytes and status. A WS handle
  with the same name remains usable.
- Independent HTTP failure, TLS trust failure, timeout, truncation and response
  limits; submission deadlines expiring before the first network step.
- Pending/duplicate/unknown handles, rejected destinations preserving results,
  repeated ready events and continued progress with an uncollected completion.
- Named waits driving both sides of HTTP/HTTPS response barriers, preserving
  unrelated ready results, and continuing when another request times out.
  Wait timeouts preserve pending requests for later completion; already failed
  or cancelled targets remain collectable with their original outcome.
- The 32-handle and 128 MiB reservation limits, rejection before response
  allocation, release on collection/drop, and reset/unload of outstanding jobs.
- Selected `wait-any` calls ignoring unrelated retained results while driving
  unselected HTTP/HTTPS barrier dependencies; submission-order selection,
  cancelled/failed/expired requests, timeout snapshots and dynamic scope.
- Empty, duplicate, unknown, malformed and oversized selections and bad options
  causing no HTTP I/O; the inclusive 32-handle bound accepting all names.
- PTY Ctrl-C in poll, wait and wait-any preserving pending jobs; trap attempts to cancel/reenter/unload
  being rejected; a trap changing a poll or wait destination without
  losing the completed response.

This is explicit cooperative HTTP concurrency. Autonomous background progress,
ZLE scheduling, cross-platform behavior and other libcurl versions remain outside
the validated scope. See [the contract](concurrency.md).

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
  checks client masking and the send work bound for a zero-timeout poll.
- An 8 MiB frame saturates a peer whose receive window is bounded and whose
  reads wait for an explicit HTTP release. The test requires a partial send
  with stalled queue progress, checks that each 100 ms poll returns within a
  generous 2 s scheduling allowance, and verifies that retained frame storage
  still counts against queue admission. Another WebSocket and HTTP remain
  usable during the stall. Releasing the peer delivers the exact payload,
  permits a new send, and allows a graceful close. This checks WS on loopback;
  it does not establish bounds for every TLS backend or network condition.
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

## Undefined-behavior checks

`make ubsan` builds a separate instrumented module and runs the entire suite,
including the loader, examples, completion and signal PTYs. GCC 15.2.0 with
`-fsanitize=undefined -fno-sanitize-recover=all` passed on the environment above.
Every child-process report fails the suite, even for expected-failure subshells.

A deliberate signed-overflow probe verified failure propagation. Process maps
also confirmed that the staged loader loaded the instrumented library rather
than the normal module. Missing or uninstrumented selections are rejected.
See [reproduction, artifact selection and limits](sanitizers.md). The shell and
third-party libraries themselves are not instrumented by this target.

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

Pipe/socket streaming, autonomous background transfers, arbitrary fork inheritance,
automatic redirects, cookies, named sessions, HTTP/2/3-specific behavior,
broader proxy integration and cross-platform ABI compatibility still need their own
implementation and/or test coverage before being relied on.
