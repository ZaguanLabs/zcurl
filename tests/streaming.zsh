emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
fail() { print -ru2 -- "FAIL: $* ($zcurl_error_kind: $zcurl_error)"; exit 1 }
check() { [[ $1 == $2 ]] || fail "$1 != $2" }
expect_code() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    (( actual == expected && zcurl_status == expected )) || fail "expected $expected, got $actual"
}
# Linux fixture: count live descriptors for this file in the owning shell.
file_fds() {
    local target_file=$1 fdpath
    REPLY=0
    for fdpath in /proc/$$/fd/*(N); do
        [[ $fdpath:A == $target_file:A ]] && (( ++REPLY ))
    done
    return 0
}
typeset -A response event
integer out old i
exec {out}>"$ZCURL_TEST_TMP/stream-sync.bin"
print -rn -u $out -- prefix
zcurl -r response -c "$ZCURL_TEST_CA" --output-fd "$out" -- "$ZCURL_TEST_HTTPS/bytes"
check "$response[body]" ''
check $response[bytes] 258
check $response[complete] 1
(( ${#response} == 13 )) || fail 'synchronous result shape changed'
file_fds "$ZCURL_TEST_TMP/stream-sync.bin"
check $REPLY 1
print -rn -u $out -- suffix
exec {out}>&-
# A following scalar request must have its ordinary response body.
zcurl -r response -- "$ZCURL_TEST_HTTP/tiny"
check "$response[body]" $'ok\n'

# Own the descriptor across calls, scope changes, close and descriptor reuse.
exec {out}>"$ZCURL_TEST_TMP/stream-async.bin"
old=$out
zcurl http submit download -r event -c "$ZCURL_TEST_CA" --output-fd "$out" -- "$ZCURL_TEST_HTTPS/bytes"
check $event[bytes] 0
file_fds "$ZCURL_TEST_TMP/stream-async.bin"
check $REPLY 2
exec {out}>&-
exec {out}>"$ZCURL_TEST_TMP/stream-reused.bin"
check $out $old
print -rn -u $out -- untouched
# The private duplicate must not leak into an executed child.
python3 -c 'import os,sys; assert all(os.path.realpath("/proc/self/fd/"+f) != sys.argv[1] for f in os.listdir("/proc/self/fd"))' "$ZCURL_TEST_TMP/stream-async.bin"
zcurl http wait download -r event
check $event[bytes] 258
file_fds "$ZCURL_TEST_TMP/stream-async.bin"
check $REPLY 0
zcurl http collect download -r response
check "$response[body]" ''
check $response[bytes] 258
check $response[http_status] 200
exec {out}>&-

print -rn -- start > "$ZCURL_TEST_TMP/stream-append.bin"
exec {out}>>"$ZCURL_TEST_TMP/stream-append.bin"
repeat 2; do zcurl --output-fd "$out" -- "$ZCURL_TEST_HTTP/tiny"; done
exec {out}>&-

exec {out}>"$ZCURL_TEST_TMP/stream-http-error.bin"
expect_code 22 zcurl -r response --fail --output-fd "$out" -- "$ZCURL_TEST_HTTP/missing"
check $response[bytes] 3
check $response[complete] 1
exec {out}>&-
exec {out}>"$ZCURL_TEST_TMP/stream-limit.bin"
expect_code 23 zcurl -r response --max-body 2 --output-fd "$out" -- "$ZCURL_TEST_HTTP/tiny"
check $response[error_kind] body-limit
check $response[bytes] 0
exec {out}>&-
exec {out}>"$ZCURL_TEST_TMP/stream-large.bin"
zcurl --max-body 16777216 --output-fd "$out" -- "$ZCURL_TEST_HTTP/large"
check "$zcurl_body" ''
check $zcurl_bytes 8388609
exec {out}>&-

# Cancellation closes the duplicate immediately and retains written-byte count.
exec {out}>"$ZCURL_TEST_TMP/stream-partial.bin"
zcurl http submit partial --output-fd "$out" -- "$ZCURL_TEST_HTTP/stream-held"
exec {out}>&-
repeat 30; do
    zcurl http poll --timeout 10
    zcurl http info partial -r event
    (( event[bytes] == 4 )) && break
done
check $event[bytes] 4
zcurl http cancel partial
file_fds "$ZCURL_TEST_TMP/stream-partial.bin"
check $REPLY 0
expect_code 42 zcurl http collect partial -r response
check $response[bytes] 4
check "$response[body]" ''
zcurl -- "$ZCURL_TEST_HTTP/release-stream"

# File output does not reserve scalar-body storage. All 32 jobs fit even with
# large body limits, and reset/drop/unload release their duplicated descriptors.
exec {out}>"$ZCURL_TEST_TMP/stream-cleanup.bin"
for i in {1..32}; do
    zcurl http submit "file_$i" --max-body 67108864 --output-fd "$out" -- "$ZCURL_TEST_HTTP/tiny"
done
file_fds "$ZCURL_TEST_TMP/stream-cleanup.bin"
check $REPLY 33
zcurl --reset
file_fds "$ZCURL_TEST_TMP/stream-cleanup.bin"
check $REPLY 1
zcurl http submit dropped --output-fd "$out" -- "$ZCURL_TEST_HTTP/tiny"
zcurl http drop dropped
file_fds "$ZCURL_TEST_TMP/stream-cleanup.bin"
check $REPLY 1
zcurl http submit unloaded --output-fd "$out" -- "$ZCURL_TEST_HTTP/tiny"
zmodload -u zcurl
file_fds "$ZCURL_TEST_TMP/stream-cleanup.bin"
check $REPLY 1
print -rn -u $out -- caller
exec {out}>&-
print -r -- 'PASS: HTTP file output, bounds, append/offsets, descriptor reuse, cancellation and cleanup'
