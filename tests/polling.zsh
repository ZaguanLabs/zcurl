setopt errexit nounset
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
typeset -A event response received=( alpha '' beta '' )
typeset ws_url=${ZCURL_TEST_HTTP/http:/ws:} wss_url=${ZCURL_TEST_HTTPS/https:/wss:}
fail() { print -ru2 -- "FAIL: $* ($zcurl_error_kind: $zcurl_error)"; exit 1; }
zcurl poll -r event --timeout 1000
[[ $event[event] == idle && -z $event[channel] && -z $event[handle] ]] || fail empty
(( ${#event} == 26 )) || fail shape

zcurl session create left
zcurl session create right
zcurl ws open alpha -- "$ws_url/ws"
zcurl ws open beta -c "$ZCURL_TEST_CA" -- "$wss_url/ws"
# Two HTTP pools must cross a response barrier while both sockets exchange
# binary messages. Names deliberately overlap the HTTP and WS namespaces.
zcurl http submit alpha --session left -- "$ZCURL_TEST_HTTP/parallel/one"
zcurl http submit beta --session right -- "$ZCURL_TEST_HTTP/parallel/two"
zcurl ws send alpha --type binary --data $'a\0\n\n'
zcurl ws send beta --type binary --data $'b\0\n\n'
integer done_http=0 done_ws=0
repeat 200; do
    zcurl poll -r event --timeout 100 --max-chunk 2
    case $event[channel]:$event[event] in
        http:ready)
            zcurl http collect "$event[handle]" -r response
            [[ $response[http_status] == 200 ]] || fail http
            (( ++done_http )) ;;
        ws:data)
            received[$event[handle]]+=$event[body]
            (( ! event[message_end] )) || (( ++done_ws )) ;;
        :idle) ;;
        *) fail "unexpected $event[channel]:$event[event]" ;;
    esac
    (( done_http == 2 && done_ws == 2 )) && break
done
[[ $received[alpha] == $'a\0\n\n' && $received[beta] == $'b\0\n\n' ]] || fail binary
(( done_http == 2 && done_ws == 2 )) || fail mixed

# Retained HTTP completions must not starve sockets; a busy socket must not
# starve its peer or the ready HTTP event. Keep all three sources ready.
zcurl http submit retained -- "$ZCURL_TEST_HTTP/tiny"
zcurl http wait retained
repeat 8; do
    zcurl ws send alpha --data alpha
    zcurl ws send beta --data beta
done
integer alpha_seen=0 beta_seen=0 http_seen=0
repeat 100; do
    zcurl poll -r event --timeout 100
    case $event[channel]:$event[handle] in
        ws:alpha) (( ++alpha_seen )) ;;
        ws:beta) (( ++beta_seen )) ;;
        http:retained) (( ++http_seen )) ;;
    esac
    (( alpha_seen == 8 && beta_seen == 8 )) && break
done
(( alpha_seen == 8 && beta_seen == 8 && http_seen > 0 )) || fail fairness
zcurl http collect retained

# A blocked peer must not prevent shared polling from driving another socket
# and HTTP. Release the peer through a concurrent HTTP request, using no
# per-handle driver calls for the stalled send or its recovery.
zcurl ws open stalled --max-queue 8388608 -- "$ws_url/ws-stalled"
repeat 100; do
    zcurl poll -r event --timeout 100
    [[ $event[handle] == stalled && $event[body] == ready ]] && break
done
[[ $event[handle] == stalled && $event[body] == ready ]] || fail stalled-ready
typeset empty=''
typeset large=${(pl:8388608::x:)empty}
zcurl ws send stalled --type binary --data "$large"
integer pending=-1 stalled_seen=0
repeat 20; do
    zcurl poll --timeout 100
    zcurl ws info stalled -r response
    (( response[queued_bytes] > 0 )) || fail missing-backpressure
    if (( response[queued_bytes] == pending )); then
        stalled_seen=1
        break
    fi
    pending=$response[queued_bytes]
done
(( stalled_seen && pending < 8388608 )) || fail stalled-progress
zcurl ws send alpha --data responsive
zcurl http submit responsive -- "$ZCURL_TEST_HTTP/tiny"
integer ws_responsive=0 http_responsive=0
repeat 100; do
    zcurl poll -r event --timeout 100
    if [[ $event[channel] == ws && $event[handle] == alpha && $event[body] == responsive ]]; then
        ws_responsive=1
    elif [[ $event[channel] == http && $event[handle] == responsive ]]; then
        zcurl http collect responsive
        http_responsive=1
    fi
    (( ws_responsive && http_responsive )) && break
done
(( ws_responsive && http_responsive )) || fail blocked-peer-starvation
zcurl http submit release -- "$ZCURL_TEST_HTTP/release-ws"
integer bulk_bytes=0 bulk_done=0 release_done=0
repeat 1000; do
    zcurl poll -r event --timeout 100
    if [[ $event[channel] == ws && $event[handle] == stalled ]]; then
        [[ $event[event] == data && $event[body] != *[^x]* ]] || fail bulk-payload
        (( bulk_bytes += event[bytes] ))
        bulk_done=$event[message_end]
    elif [[ $event[channel] == http && $event[handle] == release ]]; then
        zcurl http collect release
        release_done=1
    fi
    (( bulk_done && release_done )) && break
done
(( bulk_done && release_done && bulk_bytes == 8388608 )) || fail bulk-recovery
zcurl ws drop stalled
unset large

# Invalid calls must leave pending work and queued frames untouched.
zcurl http submit untouched -- "$ZCURL_TEST_HTTP/tiny"
zcurl ws send alpha --data pending
if zcurl poll -r event --max-chunk 0; then fail invalid-chunk; fi
[[ $event[error_kind] == usage ]] || fail invalid-result
if zcurl poll -r 'event[x]'; then fail invalid-target; fi
if zcurl poll --timeout 0 --timeout 0; then fail duplicate; fi
if zcurl poll --timeout 1001; then fail invalid-timeout; fi
zcurl http info untouched -r response
[[ $response[state] == pending ]] || fail unintended-http
zcurl ws info alpha -r response
[[ $response[queued_frames] == 1 ]] || fail unintended-ws
zcurl http drop untouched

# Shared polling enforces submission deadlines, including before network I/O.
zcurl http submit expired --timeout 1 -- "$ZCURL_TEST_HTTP/tiny"
sleep 0.02
repeat 30; do
    zcurl poll -r event --timeout 100
    [[ $event[channel] == http && $event[handle] == expired ]] && break
done
[[ $event[channel] == http && $event[handle] == expired ]] || fail expiration
if zcurl http collect expired -r response; then fail timeout-status; fi
[[ $response[code] == 28 ]] || fail timeout-code

# One protocol error is delivered, then its retained record is skipped.
zcurl ws open broken -- "$ws_url/ws-invalid-text"
integer error_seen=0
repeat 30; do
    if zcurl poll -r event --timeout 100; then
        [[ $event[event] != error ]] || fail error-status
    elif [[ $event[channel] == ws && $event[handle] == broken && $event[error_kind] == protocol ]]; then
        error_seen=1
        break
    else
        fail unexpected-error
    fi
done
(( error_seen )) || fail missing-error
zcurl poll -r event
[[ $event[handle] != broken ]] || fail retained-error-starvation
zcurl ws drop broken

zcurl ws close alpha
zcurl ws close beta
integer closed=0
repeat 100; do
    zcurl poll -r event --timeout 100
    [[ $event[channel] != ws || $event[state] != closed ]] || (( ++closed ))
    (( closed == 2 )) && break
done
(( closed == 2 )) || fail close
zcurl poll -r event --timeout 1000
[[ $event[event] == idle && -z $event[channel] ]] || fail retained-close
zcurl --reset
zcurl session create fresh
zcurl poll -r event
[[ $event[event] == idle ]] || fail reset
zmodload -u zcurl
[[ $event[event] == idle ]] || fail snapshot
print 'PASS: shared HTTP/WS/WSS polling, mixed pools, binary chunks, fairness, backpressure, deadlines and lifecycle'
