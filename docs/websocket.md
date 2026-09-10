# Persistent WebSockets (0.13.0-dev)

`zcurl ws` is an experimental, explicitly driven WebSocket client. It uses
libcurl for the WS/WSS handshake, TLS, masking, and wire framing. The module
owns connection handles, queues, incremental events, and lifecycle state.
Build with libcurl >=8.16.0 and a libcurl runtime with `ws`/`wss` enabled.
The implementation is tested with 8.21.0; older supported versions and other
platforms still need validation.

## Contract

```text
zcurl ws open HANDLE [options] URL
zcurl ws send HANDLE [options]
zcurl ws recv HANDLE [options]
zcurl ws poll HANDLE [options]
zcurl ws close HANDLE [options]
zcurl ws info HANDLE [options]
zcurl ws drop HANDLE [options]
```

Handles are caller-chosen ASCII identifiers, at most 64 characters:
`[A-Za-z_][A-Za-z_0-9]*`. Up to 32 handles, including closed/error records, can
exist simultaneously. Opening an existing name fails without replacing it.
Failed opens allocate no handle. `drop` releases a name so it can be reused;
callers must discard their old references when they drop it.

The read-only `zcurl_ws_handles` array lists retained names in successful open
order, including closed/error records, without driving I/O or changing results.
See [handle discovery](handles.md).

Every operation accepts `-r`/`--result ARRAY`, with the same declared ordinary
associative-array requirements and dynamic scope as HTTP. Put it first after
HANDLE to capture subsequent option-validation failures. Results are also
available through read-only `zcurl_*` parameters. Nothing prints payloads.
Options take separate words, only headers repeat, and `--` ends options.

| Operation | Options and behavior |
| --- | --- |
| `open` | Explicit `ws://` or `wss://` URL; `-x`/`--proxy URL`, `--noproxy HOSTS`, `-c`/`--cacert FILE`, repeated `-H`/`--header FIELD`, `-t`/`--timeout MS` (1..600000, default 10000), `--connect-timeout MS` (1..600000, default 3000), `--max-queue BYTES`, `--max-message BYTES` (each 1..67108864, default 8388608) |
| `send` | Copy one frame into the send queue: `-d`/`--data BYTES` (default empty), `--type text\|binary\|ping\|pong` (default text), `--more` for a nonfinal data fragment. Success means accepted, not delivered. No network I/O. |
| `recv` | Attempt one nonblocking receive; `--max-chunk BYTES` (1..65536, default 65536). Does not flush the send queue. |
| `poll` | Drive queued sends and receive at most one event; `-t`/`--timeout MS` (0..1000, default 0), `--max-chunk BYTES` (1..65536, default 65536). |
| `close` | Queue a close frame after accepted sends; `--code CODE` (default 1000), `--reason UTF8` (default empty, at most 123 raw bytes). Immediately enters `closing`, rejecting further sends. Poll to complete the handshake. |
| `info` | Report the current state, queue counts and retained peer-close/error details without I/O. Terminal errors return their error status. |
| `drop` | Immediately release the connection, queued frames and handle record. Does not wait for a close handshake. Works on open, closing, closed and error handles. |

TLS peer and hostname verification are enabled. Redirects are not followed.
HTTP operations still accept only HTTP/HTTPS. Handshake headers, including
Authorization or Sec-WebSocket-Protocol, are supplied explicitly on `open`;
there is no cookie engine or credential sharing with HTTP/other WS handles.
`open` also accepts `-x`/`--proxy URL` and `--noproxy HOSTS`. Empty proxy disables
proxies; empty bypass list bypasses none, while `'*'` bypasses all. Omitted
options retain libcurl's proxy environment behavior. Both WS and WSS use CONNECT
with the tested HTTP proxy; WSS verifies origin TLS inside the tunnel. See
[proxy routing](proxy.md#websocket-connections) for authentication and scope.
These options apply only at open. Subprotocol negotiation policy is the
caller's responsibility; the raw handshake headers are in the open result.

## Events and results

WS snapshots extend the 13 synchronous HTTP result fields with the fields below.
Synchronous HTTP snapshots retain their original shape. Concurrent HTTP snapshots
also use `handle`, `event` and `state`; see [their contract](concurrency.md).
Global fields clear on every ordinary invocation; use a snapshot to retain an event.

| Field | Meaning |
| --- | --- |
| `handle` | Caller-chosen connection name |
| `event` | `open`, `queued`, `idle`, `data`, `ping`, `pong`, `close`, `closed`, `info`, `dropped`, `error`, or `interrupted`; may be empty for validation failures |
| `state` | `open`, `closing`, `closed`, or `error`; empty when no handle exists |
| `frame_type` | `text`, `binary`, `ping`, `pong`, or `close` for received events |
| `body`, `bytes` | This event's raw payload and its raw byte count; not an accumulated message |
| `offset` | This data chunk's byte offset in its frame |
| `bytesleft` | Payload bytes still pending in the current data frame |
| `more` | 1 if this data frame is a nonfinal message fragment |
| `message_end` | 1 only on the last chunk of the last data frame of a message |
| `queued_bytes` | Payload bytes not yet consumed by libcurl |
| `queued_frames` | Frames still queued, including an in-progress frame and automatic control replies |
| `close_code`, `close_reason` | Retained peer-close status and UTF-8 reason; 0 before close, synthetic 1005 for an empty peer close, synthetic 1006 for failure without a valid peer close |

`http_status`, `headers`, and `effective_url` describe the `open` handshake and
are not retained in subsequent operation results. `code` is 0 for successful
WS operations, a libcurl code for transport failure, or -1 when no operation
was attempted. Check `status`/the shell return value and `error_kind`/`error`.
`complete` is 1 for successful open/drop, a complete control event, or a data
event with `message_end=1`; it is not an acknowledgement of message delivery.
`new_connections`, `total_us`, and `content_type` are unused for WS.

No data available is a successful `idle` event, not an error. Poll timeout is
also `idle` (status 0), not HTTP-style timeout 28. Invalid arguments/state or
send-queue rejection return 2. Send message limits also return 2. Receive
message limits return 23 and close the transport. Invalid received text/close
payloads return 56 with `error_kind=protocol`. Other transport errors retain
the libcurl status. Terminal failures free sockets and queue storage immediately
and persist as `state=error` until `drop`/reset/unload.

## Fragmentation, control and backpressure

A send call queues one frame. Set `--more` on every data fragment except the
last, and use the same explicit type throughout a message. Text defaults apply
to each call, so repeat `--type binary` for all binary fragments. UTF-8 text is
validated across fragments; an invalid send is rejected transactionally, so a
corrected fragment can be retried. Binary data preserves all bytes including
NUL and trailing newlines. PING/PONG are unfragmented and limited to 125 bytes.

Receive delivers chunks as bytes arrive, with no full-message accumulation.
Text chunks may split a UTF-8 character. Use `bytesleft` to find a frame's end
and `message_end` to find a message's end. Control events can appear between
data fragments; they do not reset the data message's state. Received text is
validated incrementally; earlier chunks are provisional until the message ends.

PING payloads are returned as events and automatically queued as matching PONGs.
Use `poll` to send these replies. An explicit PING elicits a peer PONG event;
applications choose their heartbeat schedule. Automatic controls get priority
over unstarted application frames, but never interrupt a partially sent frame.

The queue is capped by retained payload storage and 256 frames, with two slots
and 250 bytes reserved for automatic control replies. Partially sent storage
counts against admission until that frame is finished, even though
`queued_bytes` decreases. Rejecting a send leaves the queue and fragmentation
state unchanged. `--max-message` applies to the aggregate bytes across fragments
in each direction. Receive buffers are at most 64 KiB, controls 125 bytes, and
handshake headers 256 KiB; libcurl and Zsh result copies use additional memory.

When the peer closes, the module reports its code/reason, discards unstarted
application frames, and queues a matching close reply. An already started
frame finishes before that reply. Once both close frames have been exchanged,
the transport is released and the state becomes `closed`. The record remains
available for `info`. A peer that never completes close can leave the handle
`closing`; impose an application deadline, then `drop` it. Protocol/transport
errors terminate immediately rather than attempting a graceful close.

## Scheduling and ownership

`open` synchronously establishes the connection using the multi driver and
processes shell signals between network steps. Its timeout covers connection
setup and handshake. DNS/backend blocking limitations remain those described
in the HTTP execution model.

`poll` advances one named handle. Each call stops at an event, its deadline,
or 64 steps, whichever occurs first. Each step submits at most 64 KiB and reads
at most `--max-chunk`; socket waits are at most 100 ms. Timeout zero performs
one immediate step. A work-budget exit can return `idle` with sends pending;
call again. The timeout bounds waiting, not OS scheduling, shell trap execution,
or every possible TLS/backend operation. No thread or worker makes independent
progress. Poll each live handle in the caller's loop.

Zsh signals are queued around native operations and publication and delivered
between steps. Reentrant calls and active-module unload are rejected. An
interrupted poll preserves its handle/queue and reports status 42 when shell
signal semantics allow a return. Result destinations are revalidated after
poll/open because a trap may have changed them.

Only the shell that loaded the module can use its handles. Command substitution,
background/subshell calls inheriting the module are rejected. A worker must
**exec a fresh Zsh process and load the module there**, owning its connections
and communicating results through its own IPC. zcoder's existing forked HTTP
worker cannot substitute this builtin directly. This change supplies transport
primitives for a Blade client; it does not implement the Blade application
protocol or change zcoder.

`zcurl --reset` drops HTTP and all WS state. Module unload releases all owned
WS transports without waiting for close; snapshots survive. Prefer a bounded
close/poll sequence followed by `drop` for intentional application shutdown.
There is no ZLE hook or exported socket descriptor API in this milestone.
The local Zsh manual says `zle -F` handles readable descriptors only while ZLE
is active, requiring separate scheduling outside ZLE.

## Example

```zsh
typeset -A event
zcurl ws open blade --result event \
    --header "Authorization: Bearer $api_token" -- "$blade_url" || return
{
    zcurl ws send blade --data "$request_json" || return
    typeset message=''
    integer received=0
    # A real client supplies its own deadlines and application protocol.
    repeat 100; do
        zcurl ws poll blade --result event --timeout 100 || return
        case $event[event] in
            data)
                message+=$event[body]
                if (( event[message_end] )); then
                    received=1
                    break
                fi ;;
            close|closed) break ;;
        esac
    done
    (( received )) || return 1
    # Parse message as data. Never eval/source it.
    zcurl ws close blade --code 1000 || return
    repeat 10; do
        zcurl ws poll blade --result event --timeout 100 || break
        [[ $event[state] == closed ]] && break
    done
} always {
    zcurl ws drop blade
}
```

## References

- [libcurl WebSocket model](https://curl.se/libcurl/c/libcurl-ws.html)
- [Connect-only lifetime with multi](https://curl.se/libcurl/c/CURLOPT_CONNECT_ONLY.html)
- [Incremental receive and metadata](https://curl.se/libcurl/c/curl_ws_recv.html)
- [Partial sends and fragmentation flags](https://curl.se/libcurl/c/curl_ws_send.html)
- [Automatic PONG control](https://curl.se/libcurl/c/CURLOPT_WS_OPTIONS.html)
- [Local Zsh line-editor manual](/home/stig/dev/ai/zaguan/PowerHouse/inspiration/zsh/zsh_html/Zsh-Line-Editor.html)
