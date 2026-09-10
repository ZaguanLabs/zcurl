emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
fail() { print -ru2 -- "FAIL: $*"; exit 1 }
check() { [[ $1 == $2 ]] || fail "$1 != $2" }
expect_code() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    check $actual $expected
}
typeset -A response saved
typeset -a fields
integer out input
typeset expected="$(<"$ZCURL_TEST_TMP/compression-input.bin")"$'\n\n'

# Scalar decoding preserves all byte values and the wire header transcript.
zcurl --compressed --max-body 258 -r response -- "$ZCURL_TEST_HTTP/compressed/gzip"
check "$response[body]" "$expected"
check $response[bytes] 258
check $response[complete] 1
check ${#response} 13
zcurl headers Content-Encoding --from "$response[headers]" -r fields
check "$fields[1]" gzip
zcurl headers X-Observed-Encoding --from "$response[headers]" -r fields
[[ $fields[1] == *gzip* ]] || fail negotiation
saved=( "${(@kv)response}" )

# Reused synchronous connections reset negotiation and decoding independently.
exec {out}>"$ZCURL_TEST_TMP/compression-raw.bin"
zcurl -r response --output-fd "$out" -- "$ZCURL_TEST_HTTP/compressed/gzip"
exec {out}>&-
zcurl headers X-Observed-Encoding --from "$response[headers]" -r fields
check "$fields[1]" '<absent>'
zcurl -H 'Accept-Encoding: gzip' -- "$ZCURL_TEST_HTTP/compressed/gzip"
[[ $zcurl_body != "$expected" ]] || fail 'literal header enabled decoding'
zcurl --compressed -H 'Accept-Encoding: gzip' -- "$ZCURL_TEST_HTTP/compressed/gzip"
check "$zcurl_body" "$expected"
zcurl --compressed -H 'Accept-Encoding:' -- "$ZCURL_TEST_HTTP/compressed/gzip"
check "$zcurl_body" "$expected"
zcurl headers X-Observed-Encoding --from "$zcurl_headers" -r fields
check "$fields[1]" '<absent>'

for kind in sync deflate identity missing; do
    endpoint=$kind
    [[ $kind == sync ]] && endpoint=gzip
    exec {out}>"$ZCURL_TEST_TMP/compression-$kind.bin"
    integer code=0
    [[ $kind == missing ]] && code=22
    expect_code $code zcurl --compressed --fail --output-fd "$out" -r response \
        -- "$ZCURL_TEST_HTTP/compressed/$endpoint"
    exec {out}>&-
    check "$response[body]" ''
    check $response[bytes] 258
    check $response[complete] 1
done

# Concurrent HTTPS owns the decoder, request options and file descriptors.
exec {out}>"$ZCURL_TEST_TMP/compression-async.bin"
zcurl http submit decoded --compressed -c "$ZCURL_TEST_CA" --output-fd "$out" \
    -- "$ZCURL_TEST_HTTPS/compressed/gzip"
exec {out}>&-
zcurl http submit raw -- "$ZCURL_TEST_HTTP/compressed/gzip"
zcurl http wait decoded
zcurl http collect decoded -r response
check ${#response} 16
check $response[bytes] 258
check "$response[body]" ''
zcurl http wait raw
zcurl http collect raw
[[ $zcurl_body != "$expected" ]] || fail 'decoder leaked between jobs'

exec {input}<"$ZCURL_TEST_TMP/compression-input.bin"
exec {out}>"$ZCURL_TEST_TMP/compression-echo.bin"
zcurl --compressed --data-fd "$input" --output-fd "$out" \
    -- "$ZCURL_TEST_HTTP/compressed/echo"
exec {input}<&-
exec {out}>&-

# The body limit measures expansion, not the much smaller compressed payload.
exec {out}>"$ZCURL_TEST_TMP/compression-limit.bin"
zcurl http submit expanded --compressed --max-body 32768 --output-fd "$out" \
    -- "$ZCURL_TEST_HTTP/compressed/large"
exec {out}>&-
zcurl http wait expanded
expect_code 23 zcurl http collect expanded -r response
check $response[error_kind] body-limit
check $response[complete] 0
(( response[bytes] <= 32768 )) || fail expansion
expect_code 23 zcurl --compressed --max-body 100 -- "$ZCURL_TEST_HTTP/compressed/gzip"
check $zcurl_error_kind body-limit
(( zcurl_bytes <= 100 )) || fail scalar-limit

exec {out}>"$ZCURL_TEST_TMP/compression-corrupt.bin"
expect_code 61 zcurl --compressed --output-fd "$out" -- "$ZCURL_TEST_HTTP/compressed/corrupt"
exec {out}>&-
check $zcurl_error_kind transport
check $zcurl_complete 0
expect_code 61 zcurl --compressed -- "$ZCURL_TEST_HTTP/compressed/unknown"
check $zcurl_error_kind transport
check "$saved[body]" "$expected"

# HEAD keeps encoded entity headers with no body; async scalar and decoder
# failures follow the same collection contract and leave the pool usable.
zcurl --compressed --head -- "$ZCURL_TEST_HTTP/compressed/gzip"
check "$zcurl_body" ''
check $zcurl_bytes 0
zcurl headers Content-Encoding --from "$zcurl_headers" -r fields
check "$fields[1]" gzip
zcurl http submit scalar --compressed -- "$ZCURL_TEST_HTTP/compressed/deflate"
zcurl http submit broken --compressed -- "$ZCURL_TEST_HTTP/compressed/corrupt"
zcurl http wait scalar
zcurl http collect scalar
check "$zcurl_body" "$expected"
zcurl http wait broken
expect_code 61 zcurl http collect broken
check $zcurl_error_kind transport
check ${#zcurl_http_handles} 0
zcurl -- "$ZCURL_TEST_HTTP/tiny"
check "$zcurl_body" $'ok\n'
expect_code 2 zcurl --compressed --compressed -- "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl http submit invalid --compressed --compressed -- "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl http poll --compressed
expect_code 2 zcurl ws open invalid --compressed -- "${ZCURL_TEST_HTTP/http:/ws:}/ws"
check ${#zcurl_http_handles} 0
check ${#zcurl_ws_handles} 0
zmodload -u zcurl
print 'PASS: compression negotiation, scalar bytes, per-request reset, concurrent TLS, errors and limits'
