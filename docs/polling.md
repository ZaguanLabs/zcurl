# Shared HTTP and WebSocket polling

`zcurl poll` drives concurrent HTTP jobs and live WebSocket handles in the
owning shell. Use it when one application loop mixes HTTP and WS/WSS or owns
several WebSockets:

```zsh
typeset -A event response
zcurl http submit metadata -- "$metadata_url"
zcurl ws send blade --data "$request_json"
while true; do
    if ! zcurl poll -r event --timeout 100; then
        # Inspect event[error_kind], event[channel] and event[handle].
        break
    fi
    case $event[channel]:$event[event] in
        http:ready)
            if zcurl http collect "$event[handle]" -r response; then
                # Use the successful HTTP response here.
                :
            fi ;;
        ws:data)
            # Consume this chunk; message_end marks the final message chunk.
            ;;
        ws:close|ws:closed) zcurl ws drop "$event[handle]" ;;
        :idle) ;;
    esac
    # Service UI/input and check the application's exit condition here.
done
```

The application owns exit conditions, message assembly, and cleanup. This
command does not install a ZLE hook or run during shell computation or sleep.
Synchronous HTTP and WebSocket handshakes retain their existing behavior.

## Command and events

```text
zcurl poll [-r ARRAY] [-t MS] [--max-chunk BYTES]
```

`--timeout` is 0..1000 ms, default 0. `--max-chunk` is 1..65536 bytes, default
65536. Options take separate words and cannot repeat. An optional final `--`
is accepted; handle selections and URLs are not accepted.

Results contain the existing 25 WebSocket fields plus `channel`, also available
as the read-only global `zcurl_channel`. Existing HTTP and WS snapshot shapes
are unchanged. Ordinary calls clear the channel along with the other globals.

| Channel | Event | Meaning |
| --- | --- | --- |
| `http` | `ready` | One retained terminal HTTP job. Collect it to obtain the transfer status and body; poll itself returns 0. |
| `ws` | `data`, `ping`, `pong`, `close`, `closed` | The corresponding WebSocket event, with its handle and ordinary WS fields. Data/control payloads are consumed by this call. |
| `ws` | `error` | A newly observed WS failure. Returns nonzero, identifying the failed handle. Other handles remain available. |
| empty | `idle` | No event was found before the wait/work budget ended, or there is no pending HTTP/live WS work. |

HTTP driver failures use `channel=http`; a general wait or interruption may
have no channel. Always inspect the status and `error_kind`. A WS record that
was already terminal when the call began is skipped; `ws info`, `ws poll` and
`ws drop` remain available for it. Retained HTTP completions can be reported
again until collected or dropped.

The usual result validation applies before I/O and again after signal delivery.
If a trap changes the destination, the event remains in global parameters and
publication returns `error_kind=result`. A consumed WS chunk is not replayed;
HTTP completions remain collectable. Use a destination the application controls.

## Scheduling guarantees and limits

Each scheduling round advances all pending HTTP pools, then visits live
WebSockets in round-robin order until it finds an event. The next call resumes
after that socket. When HTTP completions and WS events are both available,
they alternate; an uncollected HTTP completion cannot starve WebSockets.
An early event return means not every socket is visited in every call.

When no event is ready, the command waits on the HTTP pools and all live WS
sockets together. Libcurl timers and HTTP submission deadlines shorten that
wait. Queued sends request write readiness. Buffered send/control progress
causes another immediate round, avoiding a wait for bytes already in libcurl.

A call performs at most 64 steps (one HTTP drive or one WS send/receive step
each). Timeout zero performs one round, stopping earlier if an event arrives.
Each WS step submits at most 64 KiB and receives at most `--max-chunk`.
Socket waits are capped at 100 ms. The deadline limits waiting; it does not
bound every backend operation, shell trap, or OS scheduling delay. An `idle`
return can still have queued sends or unfinished HTTP jobs. Continue polling.

Signals are delivered between native steps. Reentry and active-module unload
remain rejected. Interruption preserves handles and queues. No extra receive
queue or response-storage reservation is introduced by shared polling.
