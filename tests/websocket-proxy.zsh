# Sourced by proxy.py with its check helper and independent tunnel observations.
next_event() {
    repeat 200; do
        zcurl ws poll "$1" -r response --timeout 100 || return
        [[ $response[event] != idle ]] && return 0
    done
    print -ru2 'FAIL: proxy WebSocket event deadline'
    exit 1
}
for endpoint in "$ws_url" "$wss_url"; do
    open_local() {
        local route=$AUTH_PROXY bypass=''
        zcurl ws open via -r response -x "$route" --noproxy "$bypass" \
            -c "$ZCURL_TEST_CA" -H 'Authorization: Bearer fixture-token' \
            -H 'X-Origin: private' "$endpoint/ws-auth"
    }
    open_local
    check $response[http_status] 101
    check $response[event] open
    # Locals can disappear, and unrelated handles keep independent routing.
    repeat 10; do typeset churn=${(pl:4096::x:)ZCURL_TEST_PROXY}; done
    zcurl ws open direct --proxy '' -c "$ZCURL_TEST_CA" "$endpoint/ws"
    zcurl ws send via --type binary --data $'through\0proxy\n\n'
    zcurl ws send direct --data direct
    next_event via
    check $response[event] data
    check $response[frame_type] binary
    check "$response[body]" $'through\0proxy\n\n'
    check $response[message_end] 1
    next_event direct
    check "$response[body]" direct
    zcurl ws send via --more --data $'a\xe2'
    zcurl ws send via --type ping --data $'p\0'
    zcurl ws send via --data $'\x82\xac\n\n'
    next_event via
    check "$response[body]" $'a\xe2'
    check $response[message_end] 0
    next_event via
    check $response[event] pong
    check "$response[body]" $'p\0'
    next_event via
    check "$response[body]" $'\x82\xac\n\n'
    check $response[message_end] 1
    zcurl ws close via --reason done
    next_event via
    check $response[event] close
    check $response[state] closed
    check $response[close_code] 1000
    check $response[close_reason] done
    check "${(j: :)zcurl_ws_handles}" 'via direct'
    zcurl ws drop via
    zcurl ws drop direct
    check ${#zcurl_ws_handles} 0
done
# Active tunnels and queued payloads are released on reset and unload.
zcurl ws open reset -x "$AUTH_PROXY" "$ws_url/ws"
zcurl ws send reset --data pending
zcurl --reset
check ${#zcurl_ws_handles} 0
zcurl ws open unload -x "$AUTH_PROXY" "$ws_url/ws"
zcurl ws send unload --data pending
zmodload -u zcurl
zmodload zcurl
check ${#zcurl_ws_handles} 0
