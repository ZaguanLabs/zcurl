# Named HTTP sessions (0.18.0-dev)

Named sessions give HTTP callers independent libcurl connection pools.
Create a session explicitly, then select it on each request:

```zsh
typeset -A response
zcurl session create inventory
zcurl --session inventory -r response -- https://api.example.com/items
zcurl --session inventory -r response -- https://api.example.com/status
zcurl http submit batch --session inventory -- https://api.example.com/batch
zcurl http wait batch
zcurl http collect batch
zcurl session reset inventory  # close its connections and clear its caches
zcurl session drop inventory   # release the session name as well
```

Requests without `--session` retain the default pools. Each named session owns
separate synchronous and concurrent pools: a synchronous request never advances
queued jobs, even when they share a session name. `http poll`, `wait` and
`wait-any` advance jobs across all concurrent pools. WebSocket operations reject
`--session` and each WebSocket keeps its own connection. Job, session and
WebSocket names occupy independent namespaces.

## Ownership and lifecycle

| Command | Effect |
| --- | --- |
| `zcurl session create NAME` | Reserve a new name; libcurl handles are allocated lazily on its first request |
| `zcurl session reset NAME` | Close that session's connections and destroy both its synchronous and concurrent handles, retaining the name and creation order |
| `zcurl session drop NAME` | Close the pool and release the name |
| `zcurl --session NAME [options] URL` | Execute a synchronous request in the existing named session |
| `zcurl http submit HANDLE --session NAME [options] URL` | Submit a job to the session's concurrent pool |

Up to 16 names may exist, in addition to the unnamed default session. Names are
ASCII identifiers of at most 64 bytes, like request/WS handles. Duplicate creates,
unknown names, invalid identifiers and extra management arguments fail with
status 2. Reset/drop also returns 2 while the session has retained concurrent
jobs, including completed or cancelled jobs. Collect or drop every such job first;
failed submissions do not pin sessions. The global 32-job/128-MiB limits apply
across all sessions. Allocation failures return 27. Management errors print a diagnostic.
Unknown request sessions fail with `error_kind=state` before opening or duplicating
caller file descriptors; requests never create sessions implicitly or fall back
to the default pool.

All three management commands preserve the complete last transfer result,
including on failure. They do not accept `--result`; use their exit status.
Requests keep the ordinary 13-field synchronous or 16-field concurrent snapshot
shape and accept the existing HTTP options, including proxy controls, compression and file I/O.

`zcurl_http_sessions` is a read-only special indexed array of names in creation
order. Reading it performs no I/O and preserves transfer results. A copy survives
drop/reset/unload but does not keep a session alive. Drop and recreate places a
name at the end. Disabling the `p:zcurl_http_sessions` module feature hides discovery
without destroying sessions; reenabling exposes the current registry.

`zcurl --reset` and module unload release every named session as well as the
default pool and other handles. An inherited child sees an empty session array
and cannot use or manage the parent's sessions. The ordinary owner/reentry guard
also rejects session management inside a trap during an active transfer.
Interrupting a named request leaves the session usable for subsequent requests.

## What a session retains

Each session owns a synchronous easy/multi pair and a separate concurrent multi
handle, allocated as needed, with no libcurl share handle between pools.
Connections and libcurl DNS/TLS caches can be reused inside each pool.
Resetting or dropping one session does not discard another session's warm pool.
See libcurl's [multi interface](https://curl.se/libcurl/c/libcurl-multi.html) and
[option reset semantics](https://curl.se/libcurl/c/curl_easy_reset.html).

Request options still reset after every call. Supply headers, credentials, proxy
settings, CA files and timeouts on each request. Creating a session does not set
defaults, scope it to a hostname, enable cookies, or start a background worker.
Environment defaults continue to be read through libcurl's normal behavior.

These are separate client cache objects in one process, not process isolation.
Within a session, option reset alone does not erase the connection and TLS caches;
use `session reset` or a distinct name when a separate pool is needed. Cookies and
per-session configuration are outside this milestone.

## Validation

Loopback HTTP/TLS tests check connection reuse inside each session, separate
connections across two names and the default pool, targeted reset/drop, header
and method reset, TLS verification, exact binary file transfers and unchanged
snapshots. Origin connection/request counts independently check isolation and
rejection before I/O. Other cases cover registry limits/order, feature toggles,
forks, caller options, unload/reload, descriptor protection and interactive
interruption/reentry. Completion reads discovery without invoking the builtin.

Concurrent cases verify cross-pool HTTP/TLS response barriers, independent reuse using origin connection
counts, selected waits, all 17 pools under the shared 32-job cap, binary file I/O,
failed-admission cleanup and retained-job reset/drop guards. Reset/unload with
pending and completed jobs exercise pool ownership under ASan and Valgrind.
