emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
fail() { print -ru2 -- "FAIL: $*"; exit 1 }
expect_code() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    (( actual == expected )) || fail "expected $expected, got $actual"
    (( zcurl_status == expected )) || fail 'status parameter disagrees'
}

typeset -A response=(stale gone) saved
zcurl --result response --header 'Content-Type: application/json' \
    -H 'Authorization: Bearer fixture-token' -H 'X-Tag: one' -H 'X-Tag: two' \
    --data $'{"message":"hello"}\n' "$ZCURL_TEST_HTTP/inspect"
(( ! ${+response[stale]} && ${#response} == 13 )) || fail 'result replacement'
[[ $response[content_type] == application/json && $response[http_status] == 200 ]] || fail 'metadata'
[[ $response[effective_url] == "$ZCURL_TEST_HTTP/inspect" ]] || fail 'effective URL'
print -rn -- "$response[body]" > "$ZCURL_TEST_TMP/post.json"
saved=( "${(@kv)response}" )
zcurl "$ZCURL_TEST_HTTP/inspect" -r response
print -rn -- "$response[body]" > "$ZCURL_TEST_TMP/following.json"
[[ $saved[body] != $response[body] ]] || fail 'snapshot overwritten'
(( response[new_connections] == 0 )) || fail 'options prevented connection reuse'

zcurl "$ZCURL_TEST_HTTP/bytes"
typeset payload=$zcurl_body
zcurl -X PUT --data "$payload" -r response "$ZCURL_TEST_HTTP/echo"
[[ $response[body] == "$payload" && $response[headers] == *'X-Request-Method: PUT'* ]] || fail 'binary PUT'
(( response[bytes] == 258 )) || fail 'byte count'
print -rn -- "$response[body]" > "$ZCURL_TEST_TMP/echo.bin"
zcurl -X PATCH -d '@literal-file-name' -r response "$ZCURL_TEST_HTTP/echo"
[[ $response[body] == '@literal-file-name' ]] || fail 'literal data treated as filename'
zcurl -X DELETE -r response "$ZCURL_TEST_HTTP/tiny"
[[ $response[headers] == *'X-Request-Method: DELETE'* ]] || fail 'DELETE'
zcurl -X POST -r response "$ZCURL_TEST_HTTP/echo"
[[ -z $response[body] && $response[headers] == *'X-Request-Method: POST'* ]] || fail 'empty POST'
zcurl -d '' -r response "$ZCURL_TEST_HTTP/echo"
[[ $response[headers] == *'X-Request-Method: POST'* ]] || fail 'empty data POST'
zcurl --head -r response "$ZCURL_TEST_HTTP/tiny"
[[ -z $response[body] && $response[headers] == *'X-Request-Method: HEAD'* ]] || fail 'HEAD'
zcurl -X HEAD -r response "$ZCURL_TEST_HTTP/tiny"
[[ -z $response[body] ]] || fail 'custom HEAD semantics'
zcurl "$ZCURL_TEST_HTTP/tiny"
[[ $zcurl_body == $'ok\n' ]] || fail 'HEAD leaked into GET'
zcurl -r response "$ZCURL_TEST_HTTP/empty"
(( response[http_status] == 204 && response[complete] == 1 && response[bytes] == 0 )) || fail 'empty response'

expect_code 22 zcurl --result response --fail "$ZCURL_TEST_HTTP/missing"
[[ $response[error_kind] == http && $response[body] == $'ok\n' ]] || fail 'HTTP error body'
(( response[code] == 0 && response[complete] == 1 && response[http_status] == 404 )) || fail 'HTTP/transport separation'
expect_code 28 zcurl --result response --timeout 30 "$ZCURL_TEST_HTTP/slow"
[[ $response[error_kind] == transport && $response[complete] == 0 ]] || fail 'timeout result'
expect_code 23 zcurl --result response --max-body 2 "$ZCURL_TEST_HTTP/tiny"
[[ $response[error_kind] == body-limit && $response[complete] == 0 ]] || fail 'body limit diagnostic'
zcurl --max-body 3 "$ZCURL_TEST_HTTP/tiny"
expect_code 23 zcurl --result response "$ZCURL_TEST_HTTP/large-headers"
[[ $response[error_kind] == header-limit ]] || fail 'header limit diagnostic'
expect_code 18 zcurl -r response "$ZCURL_TEST_HTTP/truncated"
[[ $response[body] == $'ok\n' && $response[complete] == 0 ]] || fail 'partial response'
zcurl -r response "$ZCURL_TEST_HTTP/chunked"
[[ $response[body] == $'a\0b\n\n' && $response[headers] == *'X-Trailer: yes'* ]] || fail 'chunking/trailer'
zcurl -r response "$ZCURL_TEST_HTTP/headers"
[[ $response[headers] == *$'Set-Cookie: one=1\r\nSet-Cookie: two=2\r\n'* ]] || fail 'duplicate response headers'
zcurl -r response "$ZCURL_TEST_HTTP/interim"
[[ $response[headers] == *'103 Early Hints'*'200 OK'* ]] || fail 'interim header block'

fetch_into() { emulate -L zsh; zcurl --result "$1" "$ZCURL_TEST_HTTP/tiny" }
scope_test() {
    emulate -L zsh
    local -A response
    fetch_into response
    [[ $response[body] == $'ok\n' ]] || fail 'dynamic scope'
}
scope_test
[[ $response[headers] == *'103 Early Hints'* ]] || fail 'local response changed outer array'
caller_options() {
    emulate -L zsh
    setopt ksharrays shwordsplit globsubst typesettounset
    typeset -A local_result
    zcurl -r local_result "$ZCURL_TEST_HTTP/tiny"
    [[ ${local_result[body]} == $'ok\n' ]] || fail 'caller options'
}
caller_options
zcurl --reset
[[ -z $zcurl_body && $zcurl_code == -1 && $zcurl_complete == 0 ]] || fail 'reset result'
zcurl --cacert "$ZCURL_TEST_CA" --connect-timeout 5000 -r response "$ZCURL_TEST_HTTPS/tiny"
(( response[new_connections] == 1 )) || fail 'reset did not close session'
zcurl --cacert "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
(( zcurl_new_connections == 0 )) || fail 'TLS reuse'

expect_code 2 zcurl -r response --unknown "$ZCURL_TEST_HTTP/tiny"
[[ $response[error_kind] == usage && -z $response[body] && $response[code] == -1 ]] || fail 'stale result on usage error'
expect_code 2 zcurl
[[ $zcurl_error_kind == usage && -z $zcurl_body && $zcurl_code == -1 ]] || fail 'stale no-argument result'
zcurl --help > "$ZCURL_TEST_TMP/help.txt"
zcurl --version > "$ZCURL_TEST_TMP/version.txt"
zmodload -u zcurl
[[ $saved[content_type] == application/json ]] || fail 'result did not survive unload'
print -r -- 'PASS: methods, caller-owned results, scopes/options, limits, partial/chunked responses, HTTP errors and reset'
