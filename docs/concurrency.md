# Concurrent HTTP (0.20.0-dev)

`zcurl http` runs multiple HTTP/HTTPS requests on the owning shell thread.
Submit named requests, call `poll` or `wait` to advance them, and `collect` their results.
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
zcurl http wait HANDLE [-r ARRAY] [-t MS]
zcurl http wait-any HANDLE [HANDLE ...] [-r ARRAY] [-t MS]
zcurl http collect HANDLE [-r ARRAY]
zcurl http cancel HANDLE [-r ARRAY]
zcurl http drop HANDLE [-r ARRAY]
zcurl http info HANDLE [-r ARRAY]
```

Handles use `[A-Za-z_][A-Za-z_0-9]*`, at most 64 ASCII characters. They occupy
a separate namespace from WebSocket handles. Duplicate submissions fail
without replacing the original request. After collection or drop, a name can
be reused; discard old references before doing so.

The read-only `zcurl_http_handles` array lists all retained request names in
submission order without driving I/O or changing results. Completed and
cancelled names remain until released; see [handle discovery](handles.md).

Every operation accepts `-r`/`--result ARRAY`. The ordinary writable associative
array rules and dynamic scope are the same as synchronous HTTP. Place this
option first after the operation/handle to capture subsequent validation
failures. Options take separate shell words; short clusters and `--option=value`
are not supported. Only submission headers can repeat.

| Operation | Behavior |
| --- | --- |
| `submit` | Accepts the HTTP request options, including methods, literal binary data, file input/output, headers, CA file, `--session`, `--fail`, timeouts, and `--max-body`. Copies literal data and configuration, retains any file descriptors, then attaches the request to the pool without network I/O. Returns `event=submitted`, `state=pending`. Its result array receives only this acknowledgment and is not remembered. |
| `poll` | Advances all pending HTTP jobs. `-t`/`--timeout` is 0..1000 ms, default 0. Returns one retained terminal handle as `event=ready`, or `event=idle` with an empty handle. It does not copy response payloads or consume a result. |
| `wait` | Advances all pending jobs until the named request is terminal or the wait expires. `-t`/`--timeout` is 0..600000 ms, default 10000. Returns 0 with `event=ready` for the target, even if its transfer failed. A wait timeout returns 28 with `event=timeout`, `error_kind=wait-timeout`, and `code=0`, preserving the request. No response is consumed. |
| `wait-any` | Advances all pending jobs until any selected handle is terminal. Accepts 1..32 distinct existing HTTP names and the same timeout/result options as `wait`. Returns the first selected completion in submission order without consuming it. A wait timeout returns 28 and preserves every request. |
| `collect` | Copies a terminal response into global parameters and the optional array, returns its HTTP/transport status, then releases the handle. Returns `event=collected`, with `state=done` or `cancelled`. A pending request returns 2 and remains available. |
| `cancel` | Stops one pending request immediately, preserving any partial body/headers for collection. Returns 0 with `event=cancelled`, `state=cancelled`. Cancelling an already terminal request returns 2 without changing its result. |
| `drop` | Releases a pending or terminal request without collecting it; returns `event=dropped`, `state=dropped`. Unknown handles return 2. |
| `info` | Reports `event=info`, the current state, and buffered body byte count without driving I/O or copying the body. Terminal transfer errors are retrieved by `collect`. |

`poll` returns a ready handle even if its transfer failed. Collect it to inspect
the outcome. If several jobs are ready, the first in submission order is
reported. Until collected or dropped, that handle can be reported again.
Polling still gives pending jobs a network step before reporting retained
results, so an uncollected result does not prevent their progress.

Use `wait` when the next operation needs one particular response. Other ready
results do not end the wait, and other pending requests continue to progress.
This also works when requests depend on each other making network progress.

```zsh
# After submitting users and teams:
if zcurl http wait users -r event --timeout 1000; then
    zcurl http collect users -r response
elif [[ $event[error_kind] == wait-timeout ]]; then
    # users is still pending. Wait/poll again, or cancel/drop it.
    print -r -- 'Still waiting for users'
fi
# teams remains available for its own wait/collection.
```

## Waiting for a selected set

Use `wait-any` when a batch shares the HTTP job registry with other callers. Unlike
unfiltered `poll`, it only reports a handle from the supplied selection. Every
pending job still gets network progress, including unselected dependencies.

```zsh
typeset -A pending=( users 1 teams 1 ) event response
# After successfully submitting these two requests:
while (( ${#pending} )); do
    zcurl http wait-any "${(@k)pending}" -r event --timeout 1000 || break
    handle=$event[handle]
    if zcurl http collect "$handle" -r response; then
        print -r -- "$handle: HTTP $response[http_status]"
    else
        print -ru2 -- "$handle: ${(V)response[error]}"
    fi
    unset "pending[$handle]"
done
# On early exit, pending still identifies requests this caller must clean up.
```

The [runnable batch example](../examples/concurrent.zsh) uses this operation
and includes cleanup. Keep the selected names under the caller's control;
the discovery array contains every caller's retained requests.

The selection must contain 1..32 distinct existing HTTP handles. Unknown names,
duplicates, invalid identifiers and invalid options/results fail before driving
any request. A name belonging only to a WebSocket is not an HTTP handle.
Options can precede, follow or appear between names; `--` ends option parsing.
Put `-r ARRAY` first to capture subsequent parsing errors. Short clusters and
attached option values remain unsupported.

`--timeout` is 0..600000 ms, default 10000, independent of submission deadlines.
Zero performs one drive step without waiting. A completed, cancelled or failed
selected request returns 0 with `event=ready` and its `handle`, `state` and byte
count. Collect it to obtain its transfer status and payload. When several are
ready, submission order wins over selection order. Until collected or dropped,
the same handle can be reported again; remove released names from future calls.

A wait timeout returns 28 with `event=timeout`, `error_kind=wait-timeout`, and
`code=0`. There is no selected result: `handle` and `state` are empty and `bytes`
is zero. All requests remain available. Driver interruption/failure also leaves
the selection unconsumed. A result array changed by a signal trap causes the
usual publication error; a ready response remains collectable. These calls
retain the existing 16-field concurrent result shape.

## Results and ownership

Submission accepts [`--compressed`](compression.md) to negotiate and decode
response content. Each job owns its decoding policy; body limits and byte
counts apply after decoding, including file output. Headers remain unchanged.

[`--proxy` and `--noproxy`](proxy.md) select per-request routing without changing
the shell environment. Explicit strings are copied and count toward the shared
storage reservation, so requests can use different routes in the same pool.

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
remains available and collection can be retried. A `poll` or `wait` destination changed
by a signal trap returns 2 with `error_kind=result`; all jobs remain available.

For control operations, status/code describe the operation rather than the
transfer. Successful controls set `code=0`; `complete` remains 0. Body, headers,
HTTP status, URL, type, connection count and timing are populated on collection.
`bytes` also reports buffered body bytes on `info`, `ready`, `cancelled`, and
wait timeout/interruption events. A wait result includes the target's handle
and state even when the wait times out or is interrupted.
Request timeout and cancellation before the first network step have no response
metadata. Completed snapshots survive subsequent calls, reset, and unload.
Use [header lookup](headers.md) to extract duplicate field values from a saved
`headers` snapshot without changing the current handle/event or driving the pool.

With `submit --output-fd FD`, response bytes go directly to a writable regular
file. `body` stays empty; `bytes` reports written bytes. The owned duplicate is
closed at transfer completion/cancellation, before collection. Partial file
writes survive failures and result-publication errors. See [file output](file-output.md).

With `submit --data-fd FD`, a private duplicate supplies a captured file range
without retaining a request scalar or changing the caller's offset. Keep its
contents stable until completion. It can be combined with file output, and its
duplicate is also closed before collection. See [file uploads](file-input.md).

## Scheduling, deadlines and storage

Each `poll` stops at a completion, its deadline, or 64 driver iterations.
Timeout zero performs one immediate driver iteration. Socket waits are capped
at 100 ms and libcurl can shorten them for its timers. An empty pool returns
`idle` immediately. The poll timeout limits waiting; resolver/TLS blocking,
OS scheduling, trap execution and work within a libcurl call can exceed it.
It is not a hard real-time or per-byte work limit.

`wait` uses the same driver and 100 ms socket-wait bound, but continues beyond
the poll iteration limit until the target finishes, the wait deadline expires,
or a signal interrupts it. Timeout zero performs one immediate driver iteration;
if the target is still pending, it returns a wait timeout. The same backend
blocking and scheduling caveats apply to `wait`.

The request `--timeout` is 1..600000 ms (default 10000) and starts when submission
is accepted. Time spent between driver calls counts. Expiration is enforced by
polling or waiting, including before the first network step. An expired request can
therefore return 28 without contacting its server. `info` does not update
deadlines. `--connect-timeout` retains its normal libcurl meaning, with the
submission deadline also applying.

The wait deadline is independent of the request deadline. Expiring the wait
does not cancel or extend the request. If the request deadline expires first,
`wait` reports a ready result with status 0; `collect` then returns 28 with
`error_kind=transport`. If the wait deadline expires first, `wait` itself returns
28 with `error_kind=wait-timeout` and `code=0`. Subsequent operations can still
finish or cancel that request. A cancelled or failed target is also ready for
collection, so waiting for it succeeds without erasing its original outcome.

At most 32 handles across all sessions, including completed and cancelled
records, can coexist.
Admission also reserves at most 128 MiB across jobs, counting each configured
response-body limit (except for file output), 256 KiB for response headers,
literal upload bytes, request header bytes, and copied URL/CA/method strings.
File uploads do not reserve their payload size. Reservation lasts until
collection or drop, even after cancellation. This conservative accounting
rejects work before response storage is needed. Lower `--max-body` when
submitting many small requests. Rejection returns 2 with
`error_kind=queue-limit` and changes no existing job.

The reservation bounds application payload storage, not whole-process memory.
Allocator overhead, libcurl/TLS caches, Zsh's encoded strings, transient
publication copies and caller-owned snapshots use additional memory. Request
configuration and upload copies remain owned until collection/drop/reset/unload.

Every session has its own concurrent pool, retaining connections between
requests. Use `http submit HANDLE --session NAME` to select an existing
[named session](sessions.md); omitting the option uses the default concurrent
pool. Session timeout, connection-timeout and response-size defaults apply at
submission; explicit request options override them. Each accepted job keeps its
effective settings, deadline and storage reservation when its session is later
reconfigured. Wait and poll timeouts are separate and do not use session defaults.
Unknown sessions fail before descriptor preparation. Handles remain in
one global namespace, and all pools share the 32-job/128-MiB admission limits.
Session reset/drop rejects retained jobs, including completed or cancelled jobs;
collect or drop them first. Global reset and unload release jobs before pools.

Each driver iteration advances every pool with pending jobs. One socket wait
covers descriptors from all those pools and honors their earliest libcurl timer,
in addition to submission/wait deadlines and the 100-ms cap. A libcurl multi
failure invalidates attached jobs in the affected pool; other pools and completed
records remain available. Temporary polling-allocation failures preserve jobs.
The descriptor aggregation uses libcurl's
[`curl_multi_waitfds`](https://curl.se/libcurl/c/curl_multi_waitfds.html) and
[`curl_multi_poll`](https://curl.se/libcurl/c/curl_multi_poll.html).

Concurrent pools are separate from synchronous pools and WebSocket connections,
including the synchronous pool with the same session name. Synchronous requests and
WS polling do not advance concurrent HTTP jobs. Concurrent HTTP polling/waiting
does not advance WebSockets. TLS verification, protocol restrictions, redirect
behavior, proxy environment handling and absence of a cookie engine match the
existing HTTP API. A job name alone does not create a session or isolate caches.

Signals are queued around libcurl and publication, then delivered between
driver steps. Ctrl-C stops polling/waiting and preserves outstanding jobs when
Zsh's signal semantics allow subsequent execution. An interrupted poll or wait uses
status 42 and `error_kind=interrupted`. Traps cannot reenter `zcurl`, change its
module features, or unload it while a command is active.

Only the shell that loaded the module may operate on its requests. Inherited
forks, command substitutions, and background subshells remain rejected.
`zcurl --reset` or module unload discards all HTTP and WS state, including
pending and uncollected requests. There is no automatic event loop, ZLE
integration, or worker in this milestone.

## References

- [Driving all easy handles and handling multi-stack failures](https://curl.se/libcurl/c/curl_multi_perform.html)
- [Removing an active handle cancels its transfer](https://curl.se/libcurl/c/curl_multi_remove_handle.html)
- [Copying literal upload bytes and their explicit length](https://curl.se/libcurl/c/CURLOPT_COPYPOSTFIELDS.html)
- [Transfer timeout](https://curl.se/libcurl/c/CURLOPT_TIMEOUT_MS.html)
