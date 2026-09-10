# zcurl

A native Zsh module for persistent HTTP/HTTPS requests and WS/WSS connections
through libcurl.
`zcurl` is a builtin, so request data and response bytes stay in the shell
without spawning a curl process for every call. TLS certificate and hostname
verification remain enabled.

Version **0.10.0-dev** is intended for trying in a project: methods, request
bodies, repeated headers, caller-owned results, bounded responses, and
interruptible requests are implemented. The API is still experimental.
HTTP supports synchronous requests and named concurrent requests driven by
explicit polling, with file-backed uploads and downloads. Persistent WebSocket handles provide queued sends and
incremental receive through bounded polling. There is no autonomous background worker.

## Build and load

Tested with Zsh 5.9.2 on Mageia x86_64, libcurl 8.21.0, and OpenSSL 3.5.8.
Requirements: C compiler, make, pkg-config, libcurl development files >=8.16.0
(with WS/WSS enabled), and matching configured Zsh headers. Tests additionally use Python 3, openssl,
curl, and optional Valgrind.

```zsh
# From this checkout:
zsh scripts/prepare-zsh.zsh
make
make test
source "$PWD/zcurl.zsh"
zcurl --version
```

The preparation script downloads pinned upstream Zsh 5.9.2 source, configures
it and generates headers under `.deps/`. It needs curl, tar/xz, sha256sum, and
Zsh's configure tools. It does not install or replace your shell. It can be
rerun to finish interrupted header generation; failures identify the log file.
The archive checksum was recorded from the upstream HTTPS download; independent
signature verification has not been performed.

Use another configured, matching source tree with
`make ZSH_SRC=/absolute/path/to/zsh-source`. The module checks its build's Zsh
version on load. That check does **not** guarantee ABI compatibility across
build options, distribution patches, or operating systems.

In a project, source `/absolute/path/to/zcurl/zcurl.zsh`. The loader works
regardless of the current directory, is idempotent, and restores `module_path`.
It leaves an already-loaded `zcurl` module and its results alone. No startup
file installation or persistent shell configuration is needed.

After rebuilding, unload and reload the module in the shell where you are
trying it. Existing loaded code does not change just because the file changed:

```zsh
zmodload -u zcurl
source /absolute/path/to/zcurl/zcurl.zsh
```

The build replaces the `.so` atomically instead of overwriting a mapped file.

## Make API requests

Declare an associative array, then pass its name with `--result`:

```zsh
typeset -A response
if zcurl --result response --fail \
    --header 'Accept: application/json' \
    -- https://api.example.com/items; then
    print -r -- "HTTP $response[http_status], $response[bytes] bytes"
    # Parse response[body] as data, or write exact bytes to a file:
    print -rn -- "$response[body]" > response.json
else
    print -ru2 -- "${zcurl_error_kind}: ${(V)zcurl_error}"
fi
```

POST a JSON body; `--data` implies POST unless a method is specified:

```zsh
zcurl --result response --fail \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $api_token" \
    --data '{"name":"example"}' \
    -- https://api.example.com/items

# Other methods:
zcurl --result response --request PATCH --data "$payload" -- "$url"
zcurl --result response --request DELETE -- "$url"
zcurl --result response --head -- "$url"
```

Each call resets request options, including method, body, headers and CA file,
while retaining the connection pool. Supply authentication headers on each
request. No cookie engine is enabled. curl's CLI config files are not read;
libcurl's proxy environment settings still apply.

`--data` sends literal bytes, including NUL and trailing newlines. It does not
read `@filename`, URL-encode data, or infer JSON content types. Add the
appropriate `Content-Type` header. Zsh xtrace/history can expose credentials;
keep secret-bearing calls out of diagnostic traces.

See [examples/api-client.zsh](examples/api-client.zsh) for a runnable helper
that writes into its caller's result array through Zsh's dynamic scope.

## Upload directly from files

```zsh
typeset -A response
integer input_fd
exec {input_fd}<payload.bin || return
{
    zcurl -r response --request PUT --data-fd "$input_fd" \
        --header 'Content-Type: application/octet-stream' -- "$url"
} always {
    exec {input_fd}<&-
}
```

`--data-fd` accepts a readable regular file for synchronous or concurrent HTTP.
It captures the range from the current offset to EOF without moving the caller's
offset or copying the file into a scalar. It implies POST unless a method is
specified, and can be combined with `--output-fd`. Keep the file contents stable
until completion. See [file uploads](docs/file-input.md) for ownership and errors.

## Write responses directly to files

```zsh
typeset -A response
integer output_fd
exec {output_fd}>response.bin || return
{
    zcurl -r response --output-fd "$output_fd" -- "$url"
} always {
    exec {output_fd}>&-
}
```

`--output-fd` accepts a writable regular-file descriptor for synchronous or
concurrent HTTP. Response bytes go directly to the file; `body` is empty and
`bytes` reports bytes written. The module owns a duplicate during the transfer.
See [file output](docs/file-output.md) for offsets, limits and partial failures.

## Interactive completion

Add the completion directory to `fpath` before your existing completion setup:

```zsh
fpath=( /absolute/path/to/zcurl/completions $fpath )
autoload -Uz compinit
compinit
```

Tab completion covers synchronous HTTP, concurrent operations, WebSockets and
header lookup, including method/frame types, CA-file paths and result arrays.
It works without loading the module and never invokes `zcurl`. The project
loader does not change completion settings. See [completion setup and behavior](docs/completion.md).

## Read response headers

```zsh
typeset -a cookies
zcurl headers Set-Cookie --from "$response[headers]" --result cookies
for cookie in "${cookies[@]}"; do
    # Each occurrence remains a separate value, in response order.
    print -r -- "$cookie"
done
```

Lookup is case-insensitive and selects the last response block, excluding
informational responses. Use `--trailers` to query its trailers instead.
The command works on saved snapshots and preserves all `zcurl_*` transfer
results. See [header lookup](docs/headers.md) for normalization, validation
and the distinction between absent fields and empty values.

## Concurrent HTTP

```zsh
typeset -A event response
zcurl http submit users --fail -- https://api.example.com/users
zcurl http submit teams --fail -- https://api.example.com/teams
zcurl http poll -r event --timeout 100
if [[ $event[event] == ready ]]; then
    zcurl http collect "$event[handle]" -r response
fi
# Keep polling and collecting until both requests finish.
```

One poll advances every pending HTTP request. Submission copies the request;
collection publishes the response and releases the handle. `cancel` preserves
a partial response for collection; `drop` discards a request. Up to 32 named
requests can coexist, within a shared 128 MiB storage reservation limit.

Use `zcurl http wait users --timeout 1000` to wait for one named request while
the entire HTTP pool advances. A wait timeout preserves the request; a successful
wait leaves its result ready for collection.

See the [concurrency contract](docs/concurrency.md) for deadlines, result fields,
error handling and lifecycle, or run [examples/concurrent.zsh](examples/concurrent.zsh)
with several URLs. The existing `zcurl [options] URL` API remains synchronous.

## Persistent WebSockets

```zsh
typeset -A event
zcurl ws open blade --result event -- "$blade_url"
zcurl ws send blade --data "$request_json"
zcurl ws poll blade --result event --timeout 100
# Inspect event[event], event[body], and event[message_end].
# Continue polling to send queued frames and receive further chunks.
zcurl ws close blade --code 1000
# Poll until closed, with an application deadline; then release the handle.
zcurl ws drop blade
```

See the [WebSocket contract](docs/websocket.md) for all operations, fragmentation,
backpressure, ping/pong, result fields and close/error lifecycle. Each handle
belongs to the shell that loaded the module. An inherited forked worker cannot
use it; a worker must exec a fresh Zsh process and load its own module.

## Options

```text
zcurl [options] URL
zcurl --help
zcurl --version
zcurl --reset
```

| Option | Meaning |
| --- | --- |
| `-r`, `--result ARRAY` | Replace a declared writable ordinary associative array |
| `-X`, `--request METHOD` | HTTP method; default GET, or POST with data |
| `-I`, `--head` | HEAD semantics, with no response body |
| `-H`, `--header FIELD` | One request header; may be repeated |
| `-d`, `--data BYTES` | Literal request body |
| `--data-fd FD` | Upload the captured remaining range of an open readable regular file |
| `-f`, `--fail` | Return status 22 for HTTP >=400, retaining the body |
| `--compressed` | Negotiate supported HTTP content encodings and decode response bytes |
| `-c`, `--cacert FILE` | PEM trust file, with hostname verification still enabled |
| `-t`, `--timeout MS` | Total timeout, 1..600000; default 10000 |
| `--connect-timeout MS` | Connection timeout, 1..600000; default 3000; total timeout also applies |
| `--max-body BYTES` | Response body limit, 1..67108864; default 8388608 (8 MiB) |
| `--output-fd FD` | Write response bytes to an open writable regular file, leaving `body` empty |
| `--` | End of options |
| `--reset` | Close HTTP and all WebSocket handles and clear the last result |

Option values must be separate shell words. Short-option clustering and
`--option=value` are not supported. Only `--header` can be repeated. Options
may appear before or after the single URL until `--`.

Header names and methods must be HTTP tokens; header values may not contain
CR, LF, NUL or other controls except tab. Combined request headers are capped
at 256 KiB. A header like `Accept:` suppresses libcurl's default header, as
in libcurl. Semicolon syntax for empty headers is not implemented.

`--head` and `--request HEAD` use libcurl's HEAD behavior, not just a changed
method string. HEAD cannot be combined with data or a different method.
`--data` and `--data-fd` are mutually exclusive.
For ordinary HTTP requests, only HTTP/HTTPS are permitted; a URL without a
scheme defaults to HTTPS.
Redirects are returned to the caller and are not followed. There is no
insecure TLS option.

`--compressed` enables response decompression for synchronous requests and
`http submit`, including file output. `--max-body` and `bytes` then count decoded
bytes; response headers retain the server's encoded `Content-Length` and
`Content-Encoding`. Without the flag, content remains encoded. See
[compression behavior and limits](docs/compression.md).

## Handle discovery

`zcurl_http_handles` and `zcurl_ws_handles` are read-only indexed arrays of
retained names in creation order. They include terminal records until collection
or drop releases them. Reading either array preserves transfer results and does
not drive network I/O. For example, copy the current HTTP names directly:

```zsh
typeset -a requests=( "${zcurl_http_handles[@]}" )
```

Completion uses these arrays for operations on existing handles. Reset empties
them; unload removes them. Inherited child shells see empty arrays because
handles belong to the parent. See [the discovery contract](docs/handles.md).

## Results and errors

No response body is printed automatically. Each field below is available as a
read-only module parameter named `zcurl_FIELD`. With `--result response`, the
same value is copied into `response[FIELD]`; that snapshot survives subsequent
requests and module unload.

| Field | Meaning |
| --- | --- |
| `body` | Response bytes (decoded with `--compressed`), preserving NUL and trailing newlines; empty with `--output-fd` |
| `headers` | Raw headers, preserving CRLF, duplicates, interim blocks and trailers |
| `http_status` | HTTP status; zero if none was received |
| `code` | libcurl result; zero on transfer success; -1 if no transfer was attempted |
| `status` | zcurl's shell return status |
| `error_kind` | `none`, `usage`, `transport`, `http`, `body-limit`, `header-limit`, `input`, `output`, `memory`, or `result` |
| `error` | Diagnostic text; empty on success |
| `complete` | 1 if the transfer completed successfully, even for an HTTP error response |
| `bytes` | Body bytes stored, or successfully written with `--output-fd`; decoded with `--compressed` |
| `effective_url` | URL reported by libcurl |
| `content_type` | Content type reported by libcurl, or empty |
| `new_connections` | Newly opened connections during the transfer |
| `total_us` | libcurl's total transfer time in microseconds |

Without `--fail`, a completed HTTP 404 returns zero. With `--fail`, it returns
22, with `code=0`, `http_status=404`, `complete=1`, and the response body intact.
A timeout returns 28, with `code=28` and `complete=0`. Body/header callback
limits return 23 with a specific `error_kind`. Native usage/result-publication
errors return 2. File read failures or premature EOF return 42 with
`error_kind=input`. The shell may apply its own signal termination semantics.

Transfer invocations clear the global result first, including invalid calls and
`--help`, `--version`, and `--reset`. Once a valid `--result ARRAY` option has
been parsed, subsequent validation errors are also written there. If parsing
fails before that option, the array is untouched; use the global error fields.
Place `--result` first when building a wrapper, and always check exit status.
`zcurl headers` is a lookup operation: it preserves the transfer result even
when lookup fails, and reports errors on stderr with a nonzero exit status.
Inherited-child and reentrant calls are rejected without replacing the active
owner's result.

Transfer results require an existing ordinary writable associative array (`typeset -A`
at top level, `local -A` in a function). Scalars, readonly/special/tied arrays,
case-converting arrays, and subscript expressions are rejected before HTTP.
The destination is checked again after the transfer, because a signal trap
can change it. If publication then fails, the global result remains available
with `error_kind=result`. Array assignment replaces all existing keys.

Failed transfers can retain **partial** bodies and headers. The body limit
applies to raw stored bytes, not total process memory: Zsh's internal encoding,
publication copies, and a caller-owned snapshot use additional space. Received
headers are bounded at 256 KiB, with libcurl's own limits also applying.

Response data must never be `eval`ed or sourced. NUL survives inside a Zsh
scalar but cannot be passed in an external program's argv; use `print -rn`
into a pipe or file for a binary consumer.

## Session and execution model

Connection sockets and retained file descriptors are registered as private
Zsh descriptors above the single-digit redirection range and marked close-on-exec.
Ordinary `{fd}` closure and duplication are rejected. See
[descriptor ownership](docs/descriptors.md) for cleanup and scope.

The following describes synchronous HTTP. Explicit polling is documented in
the [concurrent HTTP contract](docs/concurrency.md) and
[WebSocket contract](docs/websocket.md#scheduling-and-ownership).

The module owns one persistent easy handle and multi handle. A synchronous
request is driven with `curl_multi_perform` and `curl_multi_poll`; poll waits
are capped at 100 ms and libcurl can shorten them for its own timers. Zsh
signals are queued during libcurl calls and result publication, then processed
between network steps. This avoids running shell traps inside libcurl calls.
Some libcurl backends can still block, including synchronous DNS resolvers;
100 ms is a poll bound, not a universal cancellation guarantee.

For both HTTP and WebSockets, call `zcurl` directly, then read its parameters.
`$(zcurl ...)`, background calls, and children inheriting the loaded module are deliberately rejected.
A fork duplicates handles and socket descriptors; it does not create an
independent TLS session. Start a fresh Zsh process to own a separate module.
Normal fork/pipeline composition and autonomous background work remain future
work. Do not call the synchronous request API from a prompt/ZLE
callback when you need uninterrupted typing.

## Validation and next steps

```zsh
make test        # HTTP/TLS fixtures, API/scoping tests, project loader, PTY signals
make memcheck    # Valgrind on scripted tests; requires Valgrind
make benchmark   # local HTTPS comparison with external curl
```

Tests use temporary local certificates and loopback servers, with proxies
removed from their environment. No public service or system trust-store
changes are needed. The memory check uses two exact dependency-constructor
suppressions reproduced independently of zcurl; see
[validation notes](docs/validation.md).

The original prototype's 100-request local HTTPS benchmark measured 15.63 ms
for the module, 576.91 ms for separate curl processes, and 19.59 ms for one
curl process given all URLs (medians of three rounds). Persistent cases used
one connection; separate processes used 100. Those are historical measurements
of tiny loopback requests, not predictions for real API latency. Use
`make benchmark` to measure this revision on your machine.

[Exploration notes](docs/exploration.md) cover the architectural options.
Next: integration feedback on the concurrent HTTP and WebSocket APIs,
pipe/socket streaming with backpressure, named HTTP sessions, and scheduling beyond explicit polling.
