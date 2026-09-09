# Concurrent HTTP (0.4.0-dev)

`zcurl http` runs multiple HTTP/HTTPS requests on the owning shell thread.
Submit named requests, call `poll` to advance them, and `collect` their results.
No worker or thread drives requests while the shell runs other commands.

```zsh
typeset -A event response
zcurl http submit users --fail -- https://api.example.com/users
zcurl http submit teams --fail -- https://api.example.com/teams
integer remaining=2
while (( remaining )); do
    zcurl http poll -r event --timeout 100 || break
    [[ $event[event] == ready ]] || continue
    if zcurl http collect "$event[handle]" -r response; then
        print -r -- "$response[handle]: HTTP $response[http_status], $response[bytes] bytes"
    else
        print -ru2 -- "$response[handle]: ${(V)response[error]}"
    fi
    remaining=$(( remaining - 1 ))
done
```

An application should track every accepted name and drop outstanding requests
on early exit. [The runnable batch example](../examples/concurrent.zsh) includes
cleanup and continues collecting when individual requests fail.

## Operations

```text
zcurl http submit HANDLE [HTTP options] URL
zcurl http poll [-r ARRAY] [-t MS]
zcurl http collect HANDLE [-r ARRAY]
zcurl http cancel HANDLE [-r ARRAY]
zcurl http drop HANDLE [-r ARRAY]
zcurl http info HANDLE [-r ARRAY]
```

Handles use `[A-Za-z_][A-Za-z_0-9]*`, at most 64 ASCII characters. They occupy
a separate namespace from WebSocket handles. Duplicate submissions fail
without replacing the original request. After collection or drop, a name can
be reused; discard old references before doing so.

Every operation accepts `-r`/`--result ARRAY`. The ordinary writable associative
array rules and dynamic scope are the same as synchronous HTTP. Place this
option first after the operation/handle to capture subsequent validation
failures. Options take separate shell words; short clusters and `--option=value`
are not supported. Only submission headers can repeat.

| Operation | Behavior |
| --- | --- |
| `submit` | Accepts the existing HTTP request options, including methods, literal binary data, headers, CA file, `--fail`, timeouts, and `--max-body`. Copies request data and configuration, then attaches the request to the pool without network I/O. Returns `event=submitted`, `state=pending`. Its result array receives only this acknowledgment and is not remembered. |
| `poll` | Advances all pending HTTP jobs. `-t`/`--timeout` is 0..1000 ms, default 0. Returns one retained terminal handle as `event=ready`, or `event=idle` with an empty handle. It does not copy response payloads or consume a result. |
| `collect` | Copies a terminal response into global parameters and the optional array, returns its HTTP/transport status, then releases the handle. Returns `event=collected`, with `state=done` or `cancelled`. A pending request returns 2 and remains available. |
| `cancel` | Stops one pending request immediately, preserving any partial body/headers for collection. Returns 0 with `event=cancelled`, `state=cancelled`. Cancelling an already terminal request returns 2 without changing its result. |
| `drop` | Releases a pending or terminal request without collecting it; returns `event=dropped`, `state=dropped`. Unknown handles return 2. |
| `info` | Reports `event=info`, the current state, and buffered body byte count without driving I/O or copying the body. Terminal transfer errors are retrieved by `collect`. |

`poll` returns a ready handle even if its transfer failed. Collect it to inspect
the outcome. If several jobs are ready, the first in submission order is
reported. Until collected or dropped, that handle can be reported again.
Polling still gives pending jobs a network step before reporting retained
results, so an uncollected result does not prevent their progress.

## Results and ownership

Concurrent snapshots contain the 13 existing HTTP fields plus `handle`,
`event`, and `state` (16 keys). Synchronous HTTP snapshots keep 13 keys;
WebSocket snapshots keep their existing shape. The corresponding global
`zcurl_*` fields are shared and clear on ordinary invocations.

`collect` has the same transfer semantics as synchronous HTTP:

- `--fail` returns 22 for HTTP >=400, retaining the body, `code=0`, and
  `complete=1`.
- Timeouts return 28; body/header limits return 23 with their specific
  `error_kind`. Partial response bytes and headers are retained.
- Explicit cancellation returns 42 with `error_kind=cancelled`, `code=42`,
  and `complete=0`.

Successfully publishing an error response also consumes its handle. An invalid
result destination does not consume it. If publication fails, the global result
remains available and collection can be retried. A `poll` destination changed
by a signal trap returns 2 with `error_kind=result`; all jobs remain available.

For control operations, status/code describe the operation rather than the
transfer. Successful controls set `code=0`; `complete` remains 0. Body, headers,
HTTP status, URL, type, connection count and timing are populated on collection.
`bytes` also reports buffered body bytes on `info`, `ready`, and `cancelled`.
Request timeout and cancellation before the first network step have no response
metadata. Completed snapshots survive subsequent calls, reset, and unload.

## Scheduling, deadlines and storage

Each `poll` stops at a completion, its deadline, or 64 driver iterations.
Timeout zero performs one immediate driver iteration. Socket waits are capped
at 100 ms and libcurl can shorten them for its timers. An empty pool returns
`idle` immediately. The poll timeout limits waiting; resolver/TLS blocking,
OS scheduling, trap execution and work within a libcurl call can exceed it.
It is not a hard real-time or per-byte work limit.

The request `--timeout` is 1..600000 ms (default 10000) and starts when submission
is accepted. Time spent between polls counts. Expiration is enforced at the
next poll, including before the first network step. An expired request can
therefore return 28 without contacting its server. `info` does not update
deadlines. `--connect-timeout` retains its normal libcurl meaning, with the
submission deadline also applying.

At most 32 handles, including completed and cancelled records, can coexist.
Admission also reserves at most 128 MiB across jobs, counting each configured
response-body limit, 256 KiB for response headers, literal upload bytes,
request header bytes, and copied URL/CA/method strings. Reservation lasts until
collection or drop, even after cancellation. This conservative accounting
rejects work before response storage is needed. Lower `--max-body` when
submitting many small requests. Rejection returns 2 with
`error_kind=queue-limit` and changes no existing job.

The reservation bounds application payload storage, not whole-process memory.
Allocator overhead, libcurl/TLS caches, Zsh's encoded strings, transient
publication copies and caller-owned snapshots use additional memory. Request
configuration and upload copies remain owned until collection/drop/reset/unload.

The concurrent pool retains connections between requests. It is separate from
the synchronous HTTP pool and WebSocket connections. Synchronous requests and
WS polling do not advance concurrent HTTP jobs. Concurrent HTTP polling does
not advance WebSockets. TLS verification, protocol restrictions, redirect
behavior, proxy environment handling and absence of a cookie engine match the
existing HTTP API; named jobs are not isolated credential sessions.

Signals are queued around libcurl and publication, then delivered between
driver steps. Ctrl-C stops polling and preserves outstanding jobs when Zsh's
signal semantics allow subsequent execution. A returned interrupted poll uses
status 42 and `error_kind=interrupted`. Traps cannot reenter `zcurl`, change its
module features, or unload it while a command is active.

Only the shell that loaded the module may operate on its requests. Inherited
forks, command substitutions, and background subshells remain rejected.
`zcurl --reset` or module unload discards all HTTP and WS state, including
pending and uncollected requests. There is no `wait` command, automatic event
loop, ZLE integration, or worker in this milestone.

## References

- [Driving all easy handles and handling multi-stack failures](https://curl.se/libcurl/c/curl_multi_perform.html)
- [Removing an active handle cancels its transfer](https://curl.se/libcurl/c/curl_multi_remove_handle.html)
- [Copying literal upload bytes and their explicit length](https://curl.se/libcurl/c/CURLOPT_COPYPOSTFIELDS.html)
- [Transfer timeout](https://curl.se/libcurl/c/CURLOPT_TIMEOUT_MS.html)
