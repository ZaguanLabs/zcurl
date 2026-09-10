# Where to push next

Updated for 0.10.0-dev. Persistent WS/WSS handles have queued sends and
explicit incremental receive/poll operations; see [the contract](websocket.md).
The synchronous HTTP implementation uses libcurl's multi interface to process
Zsh's queued signals between network steps. Named concurrent HTTP requests now
share a separate multi pool, with submission, polling, collection and cancellation;
see [the concurrency contract](concurrency.md). Autonomous background work is
not implemented.

Read-only native arrays now expose retained HTTP and WebSocket names for
script discovery and existing-handle completion without driving requests or
replacing results; see [handle discovery](handles.md).

HTTP requests now optionally negotiate and decode compressed responses for
scalar and file output, with body limits applied after expansion; see
[compression](compression.md).

The working path is `Zsh builtin → libcurl → TLS backend → network`. The C
module is the binding. A separate executable is an architectural option,
not a prerequisite for HTTPS.

Zsh's existing network modules expose useful sockets, but the bundled module
list does not provide a general libcurl HTTP/TLS client. Building HTTP framing,
certificate verification, proxies and TLS directly in shell code would spend
effort on problems libcurl already handles. The useful boundary is shell-native
request composition and results, with libcurl owning network protocols.

## Candidate architectures

| Design | Useful property | Boundary to test |
| --- | --- | --- |
| Synchronous native module | Persistent session; direct Zsh parameters; implemented here | Shell waits during the transfer; native faults affect the shell |
| Native libcurl multi interface | Concurrent transfers on the shell thread without network worker threads | Something must drive socket readiness and timers; arbitrary shell execution is not an event loop |
| Persistent libcurl worker plus Zsh client | Independent network progress and process isolation; session reuse across commands | Framing, cancellation, backpressure, result ownership, worker lifecycle |
| External curl invocation | Mature existing interface; excellent for known batches | Separate invocations do not retain one shared connection pool |

The explicit `zcurl http submit/poll/wait/collect/cancel/drop/info` API now exercises
libcurl's multi interface with retained request ownership and bounded storage.
Local HTTP and HTTPS barriers demonstrate overlapping requests; cancellation,
partial results, TLS pool reuse and PTY signals have regression coverage.
Waiting for one handle continues driving the pool and has an independent wait
deadline. Interactive integration remains open.

`zle -F` is a useful readiness hook while the line editor is active. The local
Zsh manual explicitly makes the caller responsible when ZLE is inactive.
It handles readable descriptors; libcurl's event API also requires writable
readiness and timer delivery. Treating `zle -F` as a complete, always-running
libcurl event loop would miss these requirements.

A worker can make progress while the shell runs other commands. A notification
descriptor can tell Zsh when results are available; shell parameter mutation
would still happen in the parent shell. A length-delimited protocol and bounded
reads would preserve arbitrary bytes and keep a partial message from blocking
the editor. This deserves a direct comparison if autonomous background
requests turn out to be the main need.

## What the first prototype deliberately leaves open

1. **Result API.** Caller-owned associative snapshots are implemented and tested
   through dynamic scope. Readonly/special/converting targets are rejected.
   Raw response headers preserve duplicates, informational blocks and trailers.
   [Header lookup](headers.md) now extracts individual values from saved
   snapshots, with duplicate preservation and separate trailer selection.
   Field-specific interpretation remains the consuming application's task.
2. **Streaming.** HTTP requests and responses can now stream through caller-opened
   regular-file descriptors without accumulating scalar bodies; see
   [file uploads](file-input.md) and [file output](file-output.md). Pipe/socket
   sources and sinks still need explicit backpressure. Scalars remain convenient
   for bounded API requests and responses.
3. **Session identity.** Named sessions could separate credentials, cookies,
   proxy settings and trust configuration. `curl_easy_reset` resets options
   but retains caches and other state; it is not a security isolation boundary.
4. **Forks and lifecycle.** The current PID guard is an experimental restriction.
   Children need explicitly independent state; merely duplicating a handle
   does not make shared TLS sockets safe. Connection sockets and retained file
   descriptors now have [private descriptor registration](descriptors.md),
   with close/duplication, exec inheritance and repeated cleanup tests.
   Libcurl auxiliary descriptors, other Zsh builds, signal traps, reentry and
   module feature toggles still need further stress testing.
5. **Concurrency.** Explicit overlapping transfers, cancellation and bounded
   storage are implemented. Next, measure real consuming workloads and determine
   whether they need scheduling independent of shell calls. Responsive typing
   and correct timers while ZLE is active and inactive still need separate work.
6. **Packaging.** Optional [native completion](completion.md) is implemented
   and exercised in a real ZLE session. A separate [UBSan build](sanitizers.md)
   now runs the full suite, including loaders, examples and PTYs. Multiple Zsh
   builds, distributions, other sanitizers and dependency combinations still
   need validation before promising a portable native module.

The next concurrency milestone is integration feedback on deadlines, collection
and admission limits. Whether to follow that with ZLE integration or a persistent
worker depends on the consuming project's actual request pattern.

## Sources used

Zsh documentation comes from the user-provided local 5.9.2 HTML manual:

- [Module model and bundled modules](/home/stig/dev/ai/zaguan/PowerHouse/inspiration/zsh/zsh_html/Zsh-Modules.html)
- [Command substitution](/home/stig/dev/ai/zaguan/PowerHouse/inspiration/zsh/zsh_html/Expansion.html#Command-Substitution)
- [ZLE descriptor handlers](/home/stig/dev/ai/zaguan/PowerHouse/inspiration/zsh/zsh_html/Zsh-Line-Editor.html)

Implementation details were checked against the downloaded upstream release:
`../.deps/zsh-5.9.2/Etc/zsh-development-guide`, `Src/Modules/example.c`,
`Src/module.c`, `Src/utils.c`, and the generated headers. In particular,
`metafy`/`unmetafy` mediate between raw bytes and Zsh's internal strings.

Primary libcurl references:

- [Easy-handle reset and retained state](https://curl.se/libcurl/c/curl_easy_reset.html)
- [Connection reuse in the API overview](https://curl.se/libcurl/c/libcurl.html)
- [Multi-interface concurrency, event integration and blocking exceptions](https://curl.se/libcurl/c/libcurl-multi.html)
- [Multi polling and timer behavior](https://curl.se/libcurl/c/curl_multi_poll.html)
- [Driving transfers and completion/error handling](https://curl.se/libcurl/c/curl_multi_perform.html)
- [Literal POST bodies and explicit lengths](https://curl.se/libcurl/c/CURLOPT_POSTFIELDS.html)
- [Custom methods versus transfer behavior](https://curl.se/libcurl/c/CURLOPT_CUSTOMREQUEST.html)
- [Header list lifetime and forwarding behavior](https://curl.se/libcurl/c/CURLOPT_HTTPHEADER.html)

The architecture comparisons and proposed next steps above are engineering
inferences; the synchronous HTTP, explicitly polled concurrent HTTP, WebSocket
implementations and reported tests have been demonstrated here.
