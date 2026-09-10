emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
fail() { print -ru2 -- "FAIL: $*"; exit 1 }
check() { [[ $1 == $2 ]] || fail "$1 != $2" }
typeset -a saved_http saved_ws
typeset -A response
check ${#zcurl_http_handles} 0
check ${#zcurl_ws_handles} 0

# Creation order, separate namespaces, and rejected submissions.
zcurl http submit zebra -- "$ZCURL_TEST_HTTP/tiny"
zcurl http submit alpha -- "$ZCURL_TEST_HTTP/tiny"
zcurl ws open zebra -- "${ZCURL_TEST_HTTP/http:/ws:}/ws"
zcurl ws open alpha -- "${ZCURL_TEST_HTTP/http:/ws:}/ws-close"
zcurl http submit zebra -- "$ZCURL_TEST_HTTP/tiny" 2>/dev/null && fail duplicate
check "${(j:,:)zcurl_http_handles}" zebra,alpha
check "${(j:,:)zcurl_ws_handles}" zebra,alpha
check $zcurl_error_kind state
saved_http=( "${zcurl_http_handles[@]}" )
saved_ws=( "${zcurl_ws_handles[@]}" )

# Reads preserve every result field, and terminal handles remain discoverable.
zcurl http cancel alpha
check "${(j:,:)zcurl_http_handles}" zebra,alpha
check $zcurl_event cancelled
zcurl http wait zebra
zcurl http info zebra -r response
for key in ${(k)response}; do
    value=${(P)${:-zcurl_$key}}
    : "${zcurl_http_handles[@]}" "${zcurl_ws_handles[@]}"
    check "${(P)${:-zcurl_$key}}" "$value"
done
check "${(j:,:)zcurl_http_handles}" zebra,alpha
zcurl http collect zebra
check "${(j:,:)zcurl_http_handles}" alpha
zcurl http collect alpha && fail 'cancelled collection succeeded'
check ${#zcurl_http_handles} 0
repeat 100; do
    zcurl ws poll alpha --timeout 100
    [[ $zcurl_state == closed ]] && break
done
check $zcurl_state closed
check "${(j:,:)zcurl_ws_handles}" zebra,alpha
zcurl ws drop zebra
check "${(j:,:)zcurl_ws_handles}" alpha
zcurl ws open zebra -- "${ZCURL_TEST_HTTP/http:/ws:}/ws"
check "${(j:,:)zcurl_ws_handles}" alpha,zebra

# Expired deadlines are processed only by the driver, never by a read.
zcurl http submit expired --timeout 1 -- "$ZCURL_TEST_HTTP/tiny"
sleep 0.02
check "${(j:,:)zcurl_http_handles}" expired
zcurl http info expired
check $zcurl_state pending

# Readonly in the owner; inherited children cannot use or discover handles.
( zcurl_http_handles=(fake) ) 2>/dev/null && fail writable
( unset zcurl_ws_handles ) 2>/dev/null && fail unsettable
( [[ ${#zcurl_http_handles} == 0 && ${#zcurl_ws_handles} == 0 ]] ) || fail inherited
check "${(j:,:)zcurl_http_handles}" expired
check "${(j:,:)zcurl_ws_handles}" alpha,zebra
() {
    setopt localoptions ksharrays
    local -a names=( "${zcurl_ws_handles[@]}" )
    check "${names[0]}" alpha
    check "${names[1]}" zebra
}

# Disabling discovery does not release handles; enabling it sees current state.
zmodload -F zcurl -p:zcurl_http_handles -p:zcurl_ws_handles
(( ! ${+parameters[zcurl_http_handles]} && ! ${+parameters[zcurl_ws_handles]} )) || fail disabled
zcurl http drop expired
zcurl http submit fresh -- "$ZCURL_TEST_HTTP/tiny"
zmodload -F zcurl +p:zcurl_http_handles +p:zcurl_ws_handles
check "${(j:,:)zcurl_http_handles}" fresh
check "${(j:,:)zcurl_ws_handles}" alpha,zebra
zcurl --reset
check ${#zcurl_http_handles} 0
check ${#zcurl_ws_handles} 0
repeat 3; do
    zcurl http submit discarded -- "$ZCURL_TEST_HTTP/tiny"
    zmodload -u zcurl
    (( ! ${+parameters[zcurl_http_handles]} && ! ${+parameters[zcurl_ws_handles]} )) || fail unloaded
    check "${(j:,:)saved_http}" zebra,alpha
    check "${(j:,:)saved_ws}" zebra,alpha
    zmodload zcurl
    check ${#zcurl_http_handles} 0
    check ${#zcurl_ws_handles} 0
done
zmodload -u zcurl
print 'PASS: handle discovery, ordering, terminal retention, readonly arrays, forks and feature lifecycle'
