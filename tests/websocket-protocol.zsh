setopt errexit nounset
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
typeset -A response
typeset -a selected
typeset ws_url=${ZCURL_TEST_HTTP/http:/ws:} wss_url=${ZCURL_TEST_HTTPS/https:/wss:}
check() { [[ $1 == $2 ]] || { print -ru2 -- "FAIL: $1 != $2"; exit 1; } }
next_event() {
    repeat 100; do
        zcurl ws poll "$1" -r response --timeout 100
        [[ $response[event] != idle ]] && return 0
    done
    print -ru2 'FAIL: subprotocol event deadline'
    exit 1
}
for url in "$ws_url" "$wss_url"; do
    for mode in match spacing folded early; do
        zcurl ws open chosen -r response -c "$ZCURL_TEST_CA" \
            --subprotocol fixture.v1 "$url/ws-protocol/$mode"
        check $response[event] open
        check $response[complete] 1
        check $response[http_status] 101
        zcurl headers Sec-WebSocket-Protocol --from "$response[headers]" -r selected
        check ${#selected} 1
        check "$selected[1]" fixture.v1
        zcurl ws send chosen --type binary --data $'negotiated\0\n\n'
        next_event chosen
        check "$response[body]" $'negotiated\0\n\n'
        zcurl ws close chosen
        next_event chosen
        check $response[event] close
        zcurl ws drop chosen
    done
    # A valid upgrade alone does not satisfy an explicit protocol requirement.
    for mode in missing wrong case empty list duplicate quoted early-only; do
        if zcurl ws open rejected -r response -c "$ZCURL_TEST_CA" \
            --subprotocol fixture.v1 "$url/ws-protocol/$mode"; then exit 1; else check $? 8; fi
        check $response[error_kind] protocol
        check $response[event] error
        check $response[http_status] 101
        check $response[complete] 0
        check "$response[state]" ''
        check ${#zcurl_ws_handles} 0
        [[ $response[headers] == *'101 Switching Protocols'* ]] || exit 1
    done
done
# Retained headers own their strings after the opening function returns.
open_local() {
    local protocol=fixture.v1
    zcurl ws open one --subprotocol "$protocol" "$ws_url/ws-protocol-echo"
}
open_local
zcurl ws open two --subprotocol fixture.v2 "$ws_url/ws-protocol-echo"
repeat 10; do typeset churn=${(pl:4096::x:)ws_url}; done
for handle in one two; do
    zcurl ws send "$handle" --data "$handle"
    next_event "$handle"
    check "$response[body]" "$handle"
done
zcurl --reset
# Token boundaries and raw-header mode remain explicit.
typeset empty=''
typeset longest=${(pl:255::x:)empty}
zcurl ws open limit --subprotocol "$longest" "$ws_url/ws-protocol-echo"
zcurl ws drop limit
zcurl ws open raw -H 'Sec-WebSocket-Protocol: fixture.v1' "$ws_url/ws-protocol/match"
zcurl ws drop raw
zcurl ws open plain "$ws_url/ws"
for operation in send recv poll close info drop; do
    if zcurl ws "$operation" plain --subprotocol fixture.v1; then exit 1; else check $? 2; fi
done
zcurl ws drop plain
# Validate tokens, duplicate options and conflicting headers before any I/O.
for invalid in '' 'two tokens' 'a,b' '"quoted"' $'bad\0tail' $'bad\r\nheader' ø "${longest}x"; do
    if zcurl ws open bad --subprotocol "$invalid" "$ws_url/ws"; then exit 1; else check $? 2; fi
done
if zcurl ws open bad --subprotocol; then exit 1; else check $? 2; fi
if zcurl ws open bad --subprotocol a --subprotocol b "$ws_url/ws"; then exit 1; else check $? 2; fi
for field in 'Sec-WebSocket-Protocol: fixture.v1' 'sEc-WeBsOcKeT-pRoToCoL:'; do
    if zcurl ws open bad --subprotocol fixture.v1 -H "$field" "$ws_url/ws"; then exit 1; else check $? 2; fi
    if zcurl ws open bad -H "$field" --subprotocol fixture.v1 "$ws_url/ws"; then exit 1; else check $? 2; fi
done
check ${#zcurl_ws_handles} 0
zmodload -u zcurl
print 'PASS: required WebSocket subprotocol, final-response selection, rejection cleanup, scope, tokens and header conflicts'
