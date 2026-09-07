emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl

fail() { print -ru2 -- "FAIL: $*"; exit 1 }
[[ $(whence -w zcurl) == 'zcurl: builtin' ]] || fail 'not a native builtin'
expect_code() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    (( actual == expected )) || fail "expected $expected, got $actual"
}

zcurl "$ZCURL_TEST_HTTP/tiny"
[[ $zcurl_body == $'ok\n' && $zcurl_http_status == 200 ]] || fail 'HTTP response'
[[ $zcurl_headers == *'Content-Length: 3'* ]] || fail 'headers'
zcurl "$ZCURL_TEST_HTTP/bytes"
print -rn -- "$zcurl_body" > "$ZCURL_TEST_TMP/response.bin"

zcurl "$ZCURL_TEST_HTTP/missing"
(( zcurl_http_status == 404 && zcurl_code == 0 )) || fail 'HTTP/transport separation'
zcurl "$ZCURL_TEST_HTTP/redirect"
(( zcurl_http_status == 302 )) || fail 'redirect followed unexpectedly'

expect_code 60 zcurl "$ZCURL_TEST_HTTPS/tiny"
[[ -n $zcurl_error && -z $zcurl_body ]] || fail 'TLS trust failure result'
zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
(( zcurl_http_status == 200 )) || fail 'trusted TLS'
expect_code 60 zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_MISMATCH/tiny"
expect_code 60 zcurl "$ZCURL_TEST_HTTPS/tiny"

expect_code 28 zcurl -t 50 "$ZCURL_TEST_HTTP/slow"
expect_code 1 zcurl 'file:///etc/hosts'
expect_code 23 zcurl "$ZCURL_TEST_HTTP/large"
expect_code 2 zcurl -t '1+1' "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl -t 0 "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl "$ZCURL_TEST_HTTP/"$'bad\0tail'

zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
( expect_code 2 zcurl "$ZCURL_TEST_HTTP/tiny" )
zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
(( zcurl_new_connections == 0 )) || fail 'subshell disturbed parent connection'
[[ -z $zcurl_error ]] || fail 'stale error after success'

zmodload -u zcurl
[[ $(whence -w zcurl) == 'zcurl: none' ]] || fail 'builtin remains after unload'
zmodload zcurl
zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
(( zcurl_new_connections == 1 )) || fail 'reload connection'
zmodload -u zcurl
print -r -- 'PASS: HTTP, TLS trust and hostname checks, option reset, errors, bounds, fork guard, unload/reload'
