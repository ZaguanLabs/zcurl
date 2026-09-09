setopt errexit nounset
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
typeset -A response saved
typeset ws_url=${ZCURL_TEST_HTTP/http:/ws:}
typeset wss_url=${ZCURL_TEST_HTTPS/https:/wss:}
fail() { print -ru2 -- "FAIL: $* ($zcurl_error_kind: $zcurl_error)"; exit 1; }
check() { [[ $1 == $2 ]] || fail "$1 != $2"; }
next_event() {
    local handle=$1
    repeat 200; do
        zcurl ws poll "$handle" -r response --timeout 100 --max-chunk 65536 || return
        [[ $response[event] != idle ]] && return 0
    done
    fail 'event deadline exceeded'
}
collect_message() {
    local handle=$1
    collected=''
    repeat 3000; do
        next_event "$handle" || return
        [[ $response[event] == data ]] || fail "unexpected $response[event]"
        collected+=$response[body]
        (( response[message_end] )) && return 0
    done
    fail 'message deadline exceeded'
}
typeset collected empty=''
zcurl ws open blade -r response -c "$ZCURL_TEST_CA" -H 'Authorization: Bearer fixture-token' -- "$wss_url/ws-auth"
check $response[event] open
check $response[state] open
check $response[http_status] 101
saved=( "${(@kv)response}" )
zcurl ws send blade -r response --data $'hello\0\n\n'
check $response[event] queued
check $response[queued_bytes] 8
collect_message blade
check "$collected" $'hello\0\n\n'
check $saved[event] open
zcurl "$ZCURL_TEST_HTTP/tiny"
check $zcurl_http_status 200
zcurl ws info blade -r response
check $response[state] open
zcurl ws recv blade -r response
check $response[event] idle
# Fragmentation, UTF-8 split across frames, explicit ping and pong.
zcurl ws send blade --more --data $'a\xe2'
zcurl ws send blade --type ping --data $'p\0'
zcurl ws send blade --data $'\x82\xac\n\n'
next_event blade
check "$response[body]" $'a\xe2'
check $response[more] 1
check $response[message_end] 0
next_event blade
check $response[event] pong
check "$response[body]" $'p\0'
next_event blade
check "$response[body]" $'\x82\xac\n\n'
check $response[message_end] 1
zcurl ws send blade --type pong --data unsolicited
# All bytes and a large frame exercise binary publication and partial sends.
zcurl "$ZCURL_TEST_HTTP/bytes"
typeset binary=$zcurl_body
zcurl ws send blade --type binary --data "$binary"
collect_message blade
check "$collected" "$binary"
zcurl ws send blade --type binary --data ''
collect_message blade
check "$collected" ''
zcurl ws open bulk -- "$ws_url/ws-backpressure"
typeset large=${(pl:4000000::x:)empty}
zcurl ws send bulk --type binary --data "$large"
zcurl ws poll bulk -r response --timeout 0
(( response[queued_bytes] > 0 && response[queued_frames] == 1 )) || fail 'zero-time poll exceeded send work bound'
collect_message bulk
check ${#collected} 4000000
check "$collected" "$large"
zcurl ws drop bulk
# Real socket backpressure retains the partially sent frame and its storage.
zmodload zsh/datetime
zcurl ws open stalled --max-queue 8388608 -- "$ws_url/ws-stalled"
next_event stalled
check "$response[body]" ready
large=${(pl:8388608::x:)empty}
zcurl ws send stalled --type binary --data "$large"
integer pending=-1 stalled_seen=0
float poll_started
repeat 20; do
    poll_started=$EPOCHREALTIME
    zcurl ws poll stalled -r response --timeout 100
    (( EPOCHREALTIME - poll_started < 2 )) || fail 'stalled poll exceeded deadline'
    check $response[event] idle
    (( response[queued_bytes] > 0 )) || fail 'fixture did not force backpressure'
    if (( pending == response[queued_bytes] )); then
        stalled_seen=1
        break
    fi
    pending=$response[queued_bytes]
done
(( stalled_seen && pending < 8388608 )) || fail 'partial send did not stall'
if zcurl ws send stalled -r response --data x; then fail 'partially sent storage was released early'; fi
check $response[error_kind] queue-limit
check $response[queued_bytes] $pending
check $response[queued_frames] 1
# Another handle and HTTP must remain usable while this socket is blocked.
zcurl ws send blade --data responsive
collect_message blade
check "$collected" responsive
zcurl "$ZCURL_TEST_HTTP/release-ws"
collect_message stalled
check "$collected" "$large"
zcurl ws send stalled --data recovered
collect_message stalled
check "$collected" recovered
zcurl ws close stalled
next_event stalled
check $response[state] closed
zcurl ws drop stalled
# A second handle gets unsolicited fragmented text and automatic pong.
zcurl ws open push -- "$ws_url/ws-push"
next_event push
check $response[event] data
check $response[more] 1
repeat 100; do
    zcurl ws poll push -r response --timeout 100 --max-chunk 1
    [[ $response[event] != idle ]] && break
done
check $response[event] ping
check "$response[body]" $'heartbeat\0'
next_event push
check $response[message_end] 1
check "$response[body]" $'\x82\xac\n\n'
zcurl ws poll push --timeout 10
zcurl ws drop push
# Small receive chunks expose frame offsets; no full-frame buffering.
zcurl ws open split -- "$ws_url/ws-split"
typeset partial=''
integer previous=0
repeat 100; do
    zcurl ws poll split -r response --timeout 100 --max-chunk 1
    [[ $response[event] == idle ]] && continue
    check $response[event] data
    check $response[offset] $previous
    (( previous += response[bytes] ))
    partial+=$response[body]
    (( response[message_end] )) && break
done
check "$partial" abcdef
zcurl ws drop split
# Queue limits are transactional; draining allows retry.
zcurl ws open small --max-queue 3 --max-message 8 -- "$ws_url/ws"
zcurl ws send small --data abc
if zcurl ws send small -r response --data d; then fail queue-limit; fi
check $response[error_kind] queue-limit
check $response[queued_bytes] 3
collect_message small
check "$collected" abc
zcurl ws send small --data d
collect_message small
check "$collected" d
zcurl ws drop small
# Graceful local and peer closes retain reports until explicit drop.
zcurl ws close blade --code 1000 --reason $'done\n'
next_event blade
check $response[event] close
check $response[close_code] 1000
check "$response[close_reason]" $'done\n'
check $response[state] closed
zcurl ws drop blade
for endpoint in close empty-close; do
    zcurl ws open peer -- "$ws_url/ws-$endpoint"
    next_event peer
    check $response[event] close
    if [[ $endpoint == close ]]; then
        check $response[close_code] 1001
        check $response[close_reason] bye
    else
        check $response[close_code] 1005
    fi
    zcurl ws poll peer -r response --timeout 100
    check $response[state] closed
    zcurl ws drop peer
done
# Error state keeps its diagnosis and releases the network resource.
for endpoint in abort invalid-text invalid-close big; do
    zcurl ws open bad --max-message 10 -- "$ws_url/ws-$endpoint"
    if next_event bad; then fail "expected error for $endpoint"; fi
    check $response[state] error
    if [[ $endpoint == big ]]; then check $response[error_kind] message-limit; fi
    if zcurl ws info bad -r response; then fail 'lost terminal error'; fi
    check $response[close_code] 1006
    zcurl ws drop bad
done
# TLS failures, handshake rejection/timeouts, protocol restrictions.
if zcurl ws open untrusted -r response -- "$wss_url/ws"; then fail trust; fi
check $response[code] 60
if zcurl ws open mismatch -r response -c "$ZCURL_TEST_CA" -- "${ZCURL_TEST_MISMATCH/https:/wss:}/ws"; then fail hostname; fi
check $response[code] 60
if zcurl ws open denied -r response -- "$ws_url/ws-deny"; then fail denied; fi
check $response[http_status] 403
if zcurl ws open timeout -r response --timeout 20 -- "$ws_url/ws-hang"; then fail timeout; fi
check $response[code] 28
if zcurl ws open wrong -r response -- "$ZCURL_TEST_HTTP/tiny"; then fail scheme; fi
check $response[error_kind] usage
# Invalid payloads, options and targets never enter the queue.
zcurl ws open valid -- "$ws_url/ws"
for args in '--type nope' '--timeout 5' '--more --type ping' '--code 1005'; do
    if zcurl ws send valid -r response ${=args}; then fail "accepted $args"; fi
done
if zcurl ws send valid --data $'\xff'; then fail utf8; fi
if zcurl ws send valid --type ping --data "${(pl:126::x:)empty}"; then fail ping-size; fi
if zcurl ws close valid --reason $'\xff'; then fail close-utf8; fi
if zcurl ws close valid --code 1006; then fail close-code; fi
if zcurl ws send valid -r 'response[x]' --data no; then fail subscript; fi
zcurl ws info valid -r response
check $response[queued_frames] 0
if (zcurl ws send valid --data child); then fail fork; fi
zcurl ws send valid --data parent
collect_message valid
check "$collected" parent
# Dynamic-scope results and adverse caller options preserve the caller.
scoped_result() {
    emulate -L zsh
    setopt ksharrays shwordsplit globsubst
    local -A local_result=(stale gone)
    zcurl ws info valid -r local_result
    [[ ${local_result[state]} == open && ! -v 'local_result[stale]' ]] || fail scope
}
scoped_result
# A rejected fragment must not corrupt the message under construction.
zcurl ws send valid --more --data first
if zcurl ws send valid --type binary --data wrong; then fail fragment-type; fi
zcurl ws send valid --data last
collect_message valid
check "$collected" firstlast
# Frame count also bounds empty-frame queues.
zcurl ws open frames -- "$ws_url/ws"
repeat 256; do zcurl ws send frames --type binary; done
if zcurl ws send frames -r response --type binary; then fail frame-limit; fi
check $response[queued_frames] 256
zcurl ws drop frames
# Duplicate names and handle count reject without replacing live state.
if zcurl ws open valid -- "$ws_url/ws"; then fail duplicate; fi
integer handle_no
for handle_no in {1..31}; do zcurl ws open "slot_$handle_no" -- "$ws_url/ws"; done
if zcurl ws open overflow -- "$ws_url/ws"; then fail handle-limit; fi
# Reset/unload close live handles and discard queued data.
zcurl --reset
if zcurl ws info valid; then fail reset; fi
zcurl ws open live -- "$ws_url/ws"
zcurl ws send live --data pending
zmodload -u zcurl
zmodload zcurl
if zcurl ws info live; then fail unload; fi
zmodload -u zcurl
print -r -- 'PASS: WS/WSS handles, incremental binary I/O, queues, fragmentation, ping/pong, close/error lifecycle, TLS and cleanup'
