emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
typeset -A response saved
typeset -a names
check() { [[ $1 == $2 ]] || { print -ru2 -- "FAIL: $1 != $2"; exit 1; } }
expect_code() {
    local expected=$1 actual
    shift
    if "$@"; then actual=0; else actual=$?; fi
    check "$actual" "$expected"
}
check ${#zcurl_http_sessions} 0
zcurl session create alpha
zcurl session create beta
for chosen in alpha beta; do
    zcurl --session "$chosen" -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
    check $zcurl_new_connections 1
    zcurl --session "$chosen" -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
    check $zcurl_new_connections 0
done
zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 1
zcurl session reset alpha
zcurl --session alpha -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 1
zcurl --session beta -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 0
zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 0
zcurl session drop beta
zcurl session create beta
zcurl --session beta -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 1
# Management and discovery preserve errors and all last-transfer fields.
expect_code 22 zcurl --session alpha --fail -c "$ZCURL_TEST_CA" -r response "$ZCURL_TEST_HTTPS/missing"
saved=( "${(@kv)response}" )
zcurl session create temporary
zcurl session reset temporary
zcurl session drop temporary
expect_code 2 zcurl session drop temporary
expect_code 2 zcurl session create alpha
names=( "${zcurl_http_sessions[@]}" )
check "${(j:,:)names}" alpha,beta
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
# Per-request headers, methods and trust are reset within a session.
zcurl --session alpha -c "$ZCURL_TEST_CA" -H 'Authorization: Bearer alpha' \
    --data $'owned\0\n\n' "$ZCURL_TEST_HTTPS/inspect"
print -rn -- "$zcurl_body" > "$ZCURL_TEST_TMP/session-alpha.json"
zcurl --session alpha -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/inspect"
print -rn -- "$zcurl_body" > "$ZCURL_TEST_TMP/session-reset.json"
zcurl --session beta -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/inspect"
print -rn -- "$zcurl_body" > "$ZCURL_TEST_TMP/session-beta.json"
expect_code 60 zcurl --session alpha "$ZCURL_TEST_HTTPS/tiny"
zcurl --session beta -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 0
# A selected session supports binary file transfers with caller-owned descriptors.
print -rn -- $'file\0session\n\n' > "$ZCURL_TEST_TMP/session-input.bin"
integer input_fd output_fd
exec {input_fd}<"$ZCURL_TEST_TMP/session-input.bin"
exec {output_fd}>"$ZCURL_TEST_TMP/session-output.bin"
zcurl --session alpha -c "$ZCURL_TEST_CA" --data-fd "$input_fd" --output-fd "$output_fd" \
    -r response "$ZCURL_TEST_HTTPS/echo"
exec {input_fd}<&-
exec {output_fd}>&-
check "$response[body]" ''
check $response[complete] 1
check ${#response} 13
# An unknown session fails before descriptor preparation and never falls back.
expect_code 2 zcurl --session unknown --output-fd 999999 "$ZCURL_TEST_HTTP/tiny"
check $zcurl_error_kind state
expect_code 2 zcurl http submit invalid --session alpha "$ZCURL_TEST_HTTP/tiny"
check ${#zcurl_http_handles} 0
expect_code 2 zcurl ws open invalid --session alpha "${ZCURL_TEST_HTTP/http:/ws:}/ws"
for invalid in '' 'a-b' '1name' 'name[x]' $'bad\0tail' ø; do
    expect_code 2 zcurl --session "$invalid" "$ZCURL_TEST_HTTP/tiny"
    expect_code 2 zcurl session create "$invalid"
done
expect_code 2 zcurl --session
expect_code 2 zcurl --session alpha --session beta "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl session create alpha extra
expect_code 2 zcurl session reset
expect_code 2 zcurl session unknown alpha
expect_code 2 zcurl session reset unknown
# Discovery features, dynamic scope and forks preserve session ownership.
( zcurl_http_sessions=(fake) ) 2>/dev/null && exit 1
( unset zcurl_http_sessions ) 2>/dev/null && exit 1
( [[ ${#zcurl_http_sessions} == 0 ]] ) || exit 1
( zcurl session drop alpha ) 2>/dev/null && exit 1
zmodload -F zcurl -p:zcurl_http_sessions
(( ! ${+parameters[zcurl_http_sessions]} )) || exit 1
zcurl --session beta -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 0
zmodload -F zcurl +p:zcurl_http_sessions
check "${(j:,:)zcurl_http_sessions}" alpha,beta
() {
    emulate -L zsh
    setopt ksharrays shwordsplit globsubst
    local chosen=beta
    local -A local_result
    zcurl --session "$chosen" -c "$ZCURL_TEST_CA" -r local_result "$ZCURL_TEST_HTTPS/tiny"
    [[ ${local_result[body]} == $'ok\n' ]] || exit 1
}
# Session limits and order are independent of request/WS handle namespaces.
for number in {1..14}; do zcurl session create "slot_$number"; done
expect_code 2 zcurl session create overflow
check ${#zcurl_http_sessions} 16
zcurl session drop alpha
zcurl session create alpha
check "$zcurl_http_sessions[-1]" alpha
zcurl --reset
check ${#zcurl_http_sessions} 0
check "${(j:,:)names}" alpha,beta
repeat 3; do
    zcurl session create live
    zcurl --session live "$ZCURL_TEST_HTTP/tiny"
    zmodload -u zcurl
    (( ! ${+parameters[zcurl_http_sessions]} )) || exit 1
    zmodload zcurl
    check ${#zcurl_http_sessions} 0
done
zmodload -u zcurl
print 'PASS: named HTTP sessions, independent reuse/reset, binary I/O, option reset, validation and lifecycle'
