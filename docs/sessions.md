# Named HTTP sessions (0.24.0-dev)

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
| `zcurl session create NAME --from SOURCE` | Reserve a new name with owned copies of an existing session's defaults and fresh pools |
| `zcurl session reset NAME` | Close that session's connections and destroy both its synchronous and concurrent handles, retaining the name, configuration and creation order |
| `zcurl session configure NAME [options]` | Update defaults for future requests without closing connections |
| `zcurl session configure NAME --defaults` | Restore standard request defaults without closing connections |
| `zcurl session info NAME --result ARRAY` | Copy defaults and the retained-job count into a declared associative array without I/O |
| `zcurl session jobs NAME --result ARRAY [--state STATE]` | Copy this session's retained request names into an indexed array without I/O |
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

All management commands preserve the complete last transfer result,
including on failure. `info` and `jobs` require `--result`; the other management commands
use only their exit status and do not accept a result destination.
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

## Copying configuration

Create independent sessions from a configured template:

```zsh
zcurl session create template
zcurl session configure template --timeout 2000 --max-body 65536 --cacert /path/to/ca.pem
zcurl session create foreground --from template
zcurl session create batch --from template
zcurl session configure batch --timeout 30000
zcurl session drop template
```

`--from SOURCE` copies the source's current timeout, connection timeout, response
limit, both CA-file paths and proxy/bypass defaults (including explicit empty
strings). The source must be an existing named session;
the unnamed default pool cannot be a source. The destination must be a new name.
All allocations finish before the destination enters the registry, so failure
leaves existing sessions and creation order intact. The ordinary 16-session cap
applies. `--from` is accepted once, after the new name, with a separate source word.
No other creation options are accepted; use `configure` to customize the copy.

Copying performs no I/O, opens no CA files and preserves transfer results.
Connections, caches and retained jobs remain with the source. A source with
pending, completed or cancelled jobs may be copied; the new session starts with
zero jobs and lazily creates independent synchronous and concurrent pools.
Changing, resetting or dropping either session does not change the other's
configuration. CA path strings are copied, but the files they reference remain
external resources; their contents and relative-path resolution are unchanged.
`configure --defaults` restores the standard values, not the copied template.

## Request defaults

Configure a named session's timeouts, response limit, TLS CA files and routing:

```zsh
zcurl session configure inventory --timeout 2000 --connect-timeout 500 --max-body 65536
zcurl session configure inventory --cacert /path/to/origin-ca.pem --proxy-cacert /path/to/proxy-ca.pem
zcurl --session inventory -- https://api.example.com/status
zcurl http submit batch --session inventory --max-body 1048576 -- https://api.example.com/batch
zcurl session configure inventory --defaults
```

| Setting | Standard value | Accepted values |
| --- | --- | --- |
| `-t` / `--timeout` | 10000 ms | 1..600000 ms |
| `--connect-timeout` | 3000 ms | 1..600000 ms |
| `--max-body` | 8388608 bytes | 1..67108864 bytes |
| `-c` / `--cacert` | No configured override | Origin CA-file path, at most 4096 decoded bytes; empty clears |
| `--proxy-cacert` | No configured override | HTTPS proxy CA-file path, at most 4096 decoded bytes; empty clears |
| `-x` / `--proxy` | Inherit environment proxy | Proxy string, at most 4096 decoded bytes; empty disables proxies |
| `--noproxy` | Inherit environment bypass list | Bypass string, at most 4096 decoded bytes; empty bypasses no hosts |

Supply at least one setting. Unmentioned settings retain their previous values.
The entire update is validated before applying it; an invalid value, repeated
setting (including aliases), unsupported option or missing value returns 2
without changing configuration or transfer results. `--defaults` must appear
alone and restores the numeric standard values, clears both CA-file defaults
and removes both routing overrides so requests inherit environment routing.
Numeric values are decimal integers; all values occupy separate shell words.
Configuration requires an existing named session.

Explicit request options override configured values regardless of their position
relative to `--session`. Overrides apply only to that request. Both synchronous
calls and concurrent submissions use defaults; calls without `--session` retain
the standard values. Connection timeout covers TLS negotiation as well as TCP
connection setup; see [libcurl's connection budget](https://curl.se/libcurl/c/CURLOPT_CONNECTTIMEOUT_MS.html).

A submitted job captures its effective limits and deadline. Reconfiguring its
session is allowed while jobs are retained and does not change existing jobs,
reserved storage or wait/poll timeouts. Future submissions reserve storage using
their effective response limit, under the same global 128-MiB cap. File output
and decoded compressed bodies use the effective response limit too.

Configuration performs no network I/O and retains warm connections. Session
reset retains configuration while closing pools; drop/recreate, global reset
and unload discard it. Restoring `--defaults` changes configuration while
retaining connections. The 13-/16-field HTTP result shapes are unchanged.

### Proxy and bypass defaults

```zsh
zcurl session configure inventory --proxy http://127.0.0.1:8080 --noproxy ''
zcurl --session inventory -- https://api.example.com/status
# Override routing for one call while keeping the configured defaults.
zcurl --session inventory --proxy '' -- https://api.example.com/status
```

Session routing follows the [per-request proxy rules](proxy.md). Each setting is
independent: an unset proxy uses the environment proxy; an unset bypass list uses
the environment bypass list. Explicit `--proxy ''` disables proxy use, while
`--noproxy ''` bypasses no hosts and `--noproxy '*'` bypasses every host. Configure
both values to make a request's routing independent of environment changes.
An empty routing value remains an override, unlike an empty configured CA path.
To return to environment routing, use `configure --defaults`, which also resets
all other defaults, then reapply any wanted timeout, size or CA settings.

The settings apply to synchronous HTTP and concurrent submissions; explicit
request options win in either position relative to `--session`. Accepted jobs
own their effective strings, counted in their storage reservation, so later
reconfiguration or changes to function locals cannot change their route. Unset
routing still follows libcurl's environment behavior; it is not an environment
snapshot. Session reset retains both routing values. `create --from` copies them,
including the distinction between unset and explicit empty, into fresh pools.

Configuration copies literal text without interpreting proxy syntax, matching
bypass entries or contacting a server. Each string is limited to 4096 decoded
bytes and embedded NUL is rejected. Libcurl interprets it when a request runs.
Proxy credentials in a configured URL are retained and copied with that URL;
`session info` publishes the configured text verbatim, including credentials.
WebSocket opens continue to use their own per-open routing options.

### CA-file defaults

Origin and HTTPS proxy trust remain independent. A default `--cacert` supplies
origin trust only, while `--proxy-cacert` supplies HTTPS proxy trust only. Explicit
request options override the corresponding default in either argument order.
Certificate and hostname verification retain the ordinary HTTP behavior.
WebSockets continue to take CA files on each open.

`session configure NAME --cacert ''` clears just the origin CA default; an empty
`--proxy-cacert` clears just the proxy default. Subsequent requests then use the
normal libcurl trust configuration. Empty CA paths on individual requests remain
invalid. `session reset` closes pools and retains configured paths; `--defaults`
clears configured paths and numeric overrides while retaining pools. Drop,
global reset and unload release the configuration.

Configuration copies path strings without opening, resolving or validating the
files. Paths may contain spaces, Unicode and newlines, but no NUL, and each is
limited to 4096 decoded bytes. Nonempty paths are validated by libcurl when used.
Relative paths resolve in the shell's working directory when the transfer uses
them; use absolute paths for defaults shared across directory changes. The files'
contents must remain available and stable through the transfer.

Concurrent submission captures the effective path strings and counts them in
its existing storage reservation. Reconfiguring or clearing session defaults
does not change those submitted jobs. This follows libcurl's copying contract
for [origin CA paths](https://curl.se/libcurl/c/CURLOPT_CAINFO.html) and
[proxy CA paths](https://curl.se/libcurl/c/CURLOPT_PROXY_CAINFO.html). The CA files
and parsed TLS trust data are not snapshotted by this module.

## Inspecting a session

```zsh
typeset -A session_state
zcurl session info inventory --result session_state
print -r -- "$session_state[timeout] ms; $session_state[retained_jobs] retained jobs"
```

`info NAME -r ARRAY` and `info NAME --result ARRAY` replace the entire declared,
writable ordinary associative array with these eleven fields:

| Field | Meaning |
| --- | --- |
| `name` | The existing named session |
| `timeout` | Default total request timeout in milliseconds |
| `connect_timeout` | Default connection timeout in milliseconds |
| `max_body` | Default response limit in bytes |
| `retained_jobs` | Pending, completed and cancelled concurrent jobs still owned by this session |
| `cacert` | Configured origin CA-file path, or empty when unset |
| `proxy_cacert` | Configured HTTPS proxy CA-file path, or empty when unset |
| `proxy` | Configured proxy string, or empty when unset |
| `noproxy` | Configured bypass string, or empty when unset |
| `proxy_set` | `1` when proxy is configured (including empty), otherwise `0` |
| `noproxy_set` | `1` when bypass is configured (including empty), otherwise `0` |

The two CA-path fields were added in 0.22.0-dev; four routing fields were added
in 0.24.0-dev. HTTP transfer snapshots remain
13/16 fields. The defaults describe future requests. Individual requests may override them,
and already submitted jobs keep their captured settings. The count excludes
jobs in other sessions and the unnamed pool, synchronous calls and WebSockets.
Collection or drop removes a job from the count. A nonzero count explains why
session reset/drop rejects the operation.

Inspection does not drive requests, expire jobs, create handles or change
connection reuse. It preserves every `zcurl_*` transfer parameter, including
previous errors. It prints no data to stdout; use the destination array and exit
status. The array owns a snapshot that survives reconfiguration, drop and unload.
Locally declared arrays follow Zsh dynamic scope.

Unknown sessions, missing or repeated result options, extra arguments and
invalid result destinations return 2 with a diagnostic. Errors leave the
supplied array and transfer parameters unchanged. Scalars, indexed arrays,
readonly/special/tied/converting associations, subscripts, undeclared names and
non-ASCII identifiers are rejected, using the ordinary HTTP result rules.
Inspection still works when session discovery is disabled. The owning-shell and
reentry guards apply, so an inherited child cannot inspect the parent's session.

## Finding and cleaning up a session's jobs

`session jobs` copies request names into a declared ordinary indexed array:

```zsh
typeset -a requests
zcurl session jobs inventory --result requests
for request in "${requests[@]}"; do
    zcurl http drop "$request"
done
zcurl session drop inventory
```

Names are returned in submission order within the named session. The default
selection includes all retained jobs and agrees with `info`'s `retained_jobs`
count when the registry has not changed. An empty selection replaces the target
with an empty array. Jobs in other sessions, the unnamed pool and WebSocket
handles are excluded. The example releases only the selected session's jobs.

Use optional `--state all|pending|done|cancelled` to narrow the selection.
`done` includes successful and failed transfers, but excludes explicitly
cancelled jobs. `pending` reflects the recorded state: inspection does not
process deadlines, so an overdue job stays pending until a driver call expires
it. Result and state options may appear in either order, at most once each.
`-r` is an alias for `--result`. No filter means `all`.

```zsh
zcurl session jobs inventory --state done --result requests
if (( ${#requests} )); then
    zcurl http wait-any "${requests[@]}"
fi
```

The command performs no network I/O, does not collect anything, and preserves
all last-transfer globals even on error. Snapshots own their name strings and
survive later collection, drop, reset and unload. They do not keep jobs alive;
names can become stale or be reused. Refresh the selection after consuming
results, and track accepted names when callers share a session.

Unknown sessions, invalid states/options and invalid destinations return 2
without changing the destination or transfer results. Destinations must be
declared writable ordinary indexed arrays, without unique or converting
attributes; associative, readonly, special, tied and subscript targets are
rejected. Dynamic scope and owner/reentry guards match the other session
commands. Listing works even when the discovery-array features are disabled.

## What a session retains

Each session owns a synchronous easy/multi pair and a separate concurrent multi
handle, allocated as needed, with no libcurl share handle between pools.
Connections and libcurl DNS/TLS caches can be reused inside each pool.
Resetting or dropping one session does not discard another session's warm pool.
See libcurl's [multi interface](https://curl.se/libcurl/c/libcurl-multi.html) and
[option reset semantics](https://curl.se/libcurl/c/curl_easy_reset.html).

Request options still reset after every call. Supply headers and origin credentials
on each request. Timeouts, response size, CA-file paths and proxy routing have
configurable defaults. Creating a session does not scope it to a hostname,
enable cookies, or start a background worker.
Environment defaults continue to be read through libcurl's normal behavior.

These are separate client cache objects in one process, not process isolation.
Within a session, option reset alone does not erase the connection and TLS caches;
use `session reset` or a distinct name when a separate pool is needed. Cookie handling and
default headers and separate credential options are outside this milestone.

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

Default-setting tests check atomic updates, option ordering, partial patches,
connection reuse, independent sessions, reset/recreate semantics, saved job
limits/deadlines, storage admission and bounded file output. A local TCP peer
that accepts TLS bytes without replying checks connection budgets. Validation,
feature toggles, inherited shells and caller options are covered without public
network access.

Inspection tests cover configured and restored defaults, the complete retained-job
lifecycle, independent snapshots, dynamic scope and strict destination validation.
Origin connection and request counts check absence of I/O and preserved reuse;
previous transfer errors and pending-job snapshots remain unchanged.

Session job-list tests cover state filters, HTTP failure versus cancellation,
submission order, foreign/default-session exclusion, selected waits, scoped
cleanup, snapshot lifetime, caller options, inherited shells and feature toggles.
Origin request counters verify that discovery and validation do not drive jobs.

CA-default tests check verified HTTPS and HTTPS proxies, independent trust and
hostname checks, request overrides in both orders, copied paths after submission,
Unicode/newline metadata, bounded path storage, atomic validation, reset/clear
semantics and repeated drop/unload cleanup. Session inspection now has eleven
fields; existing HTTP result shapes remain unchanged.

Configuration-copy tests check all defaults, Unicode/newline CA paths, independent
synchronous/concurrent TLS pools, copying with retained jobs, source changes and
drop, capacity/order, invalid syntax, hidden discovery and repeated cleanup.
Origin counters require exactly four connections for eight requests across the
source and copy; creation and validation must add no network activity.

Routing-default tests independently count nine forwarded proxy requests and
eighteen origin requests, covering explicit empty values, partial environment
inheritance, overrides in both orders, owned submissions and copied sessions.
HTTPS proxy tests verify retained routing alongside independent origin/proxy CA
paths. Metadata distinguishes unset values; invalid patches, 4096-byte bounds,
Unicode/newline strings and repeated cleanup exercise ownership without I/O.
