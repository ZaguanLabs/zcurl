emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
zmodload zsh/system
fail() { print -ru2 -- "FAIL: $* ($zcurl_error_kind: $zcurl_error)"; exit 1 }
check() { [[ $1 == $2 ]] || fail "$1 != $2" }
expect_code() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    (( actual == expected && zcurl_status == expected )) || fail "expected $expected, got $actual"
}
file_fds() {
    local target_file=$1 fdpath
    REPLY=0
    for fdpath in /proc/$$/fd/*(N); do
        [[ $fdpath:A == $target_file:A ]] && (( ++REPLY ))
    done
    return 0
}
typeset -A response event
integer input out old i
local byte job
exec {input}<"$ZCURL_TEST_TMP/upload-source.bin"
sysseek -u $input 6
zcurl -r response -c "$ZCURL_TEST_CA" --data-fd "$input" -- "$ZCURL_TEST_HTTPS/echo"
check $response[bytes] 258
check $response[complete] 1
[[ $response[headers] == *'X-Request-Method: POST'* ]] || fail 'file body did not imply POST'
(( ${#response} == 13 )) || fail 'synchronous result shape changed'
print -rn -- "$response[body]" > "$ZCURL_TEST_TMP/upload-sync.bin"
file_fds "$ZCURL_TEST_TMP/upload-source.bin"
check $REPLY 1
sysread -i $input -s 1 byte
check "$byte" $'\0'

# Each job captures its own offset, even when they share an open descriptor.
sysseek -u $input 6
zcurl http submit first -X PUT --data-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
sysseek -u $input 7
zcurl http submit second -X PATCH --data-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
sysseek -u $input 0
file_fds "$ZCURL_TEST_TMP/upload-source.bin"
check $REPLY 3
old=$input
exec {input}<&-
exec {input}<"$ZCURL_TEST_CA"
check $input $old
python3 -c 'import os,sys; assert all(os.path.realpath("/proc/self/fd/"+f) != sys.argv[1] for f in os.listdir("/proc/self/fd"))' "$ZCURL_TEST_TMP/upload-source.bin"
for job in first second; do
    zcurl http wait "$job"
    zcurl http collect "$job" -r response
    print -rn -- "$response[body]" > "$ZCURL_TEST_TMP/upload-$job.bin"
    if [[ $job == first ]]; then
        [[ $response[headers] == *'X-Request-Method: PUT'* ]] || fail 'PUT lost'
    else
        [[ $response[headers] == *'X-Request-Method: PATCH'* ]] || fail 'PATCH lost'
    fi
done
file_fds "$ZCURL_TEST_TMP/upload-source.bin"
check $REPLY 0
exec {input}<&-

# Empty captured ranges still send POST, including offsets beyond EOF.
exec {input}<"$ZCURL_TEST_TMP/upload-empty.bin"
for i in 0 100; do
    sysseek -u $input $i
    zcurl --data-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
    check "$zcurl_body" ''
    check $zcurl_complete 1
    [[ $zcurl_headers == *'X-Request-Method: POST'* ]] || fail 'empty POST lost'
done
exec {input}<&-

# A file-to-file round trip uses neither a request scalar nor a response scalar.
exec {input}<"$ZCURL_TEST_TMP/upload-large.bin"
exec {out}>"$ZCURL_TEST_TMP/upload-large-echo.bin"
zcurl http submit large -c "$ZCURL_TEST_CA" --data-fd "$input" --output-fd "$out" \
    --max-body 16777216 -- "$ZCURL_TEST_HTTPS/echo"
exec {input}<&-
exec {out}>&-
zcurl http wait large
file_fds "$ZCURL_TEST_TMP/upload-large.bin"
check $REPLY 0
zcurl http collect large -r response
check "$response[body]" ''
check $response[bytes] 8388609

# Appending does not extend a submitted request; truncation aborts promptly.
print -rn -- original > "$ZCURL_TEST_TMP/upload-changing.bin"
exec {input}<>"$ZCURL_TEST_TMP/upload-changing.bin"
zcurl http submit growth --data-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
print -rn -- extra >> "$ZCURL_TEST_TMP/upload-changing.bin"
zcurl http wait growth
zcurl http collect growth -r response
check "$response[body]" original
zcurl http submit truncated --timeout 3000 --data-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
print -rn -- short > "$ZCURL_TEST_TMP/upload-changing.bin"
zcurl http wait truncated
file_fds "$ZCURL_TEST_TMP/upload-changing.bin"
check $REPLY 1
expect_code 42 zcurl http collect truncated -r response
check $response[code] 42
check $response[error_kind] input
check $response[complete] 0
[[ $response[error] == *'captured upload length'* ]] || fail 'missing truncation diagnosis'
exec {input}<&-

# Subsequent scalar uploads and ordinary GET requests reset the callbacks.
zcurl --data scalar -- "$ZCURL_TEST_HTTP/echo"
check "$zcurl_body" scalar
zcurl -- "$ZCURL_TEST_HTTP/tiny"
[[ $zcurl_headers == *'X-Request-Method: GET'* ]] || fail 'file upload leaked into GET'

# Admission never reserves the entire source file. All 32 sparse-file uploads
# fit with file output, and every terminal path releases the input duplicate.
exec {input}<"$ZCURL_TEST_TMP/upload-sparse.bin"
exec {out}>"$ZCURL_TEST_TMP/upload-cleanup.bin"
for i in {1..32}; do
    zcurl http submit "file_$i" --data-fd "$input" --output-fd "$out" \
        --max-body 67108864 -- "$ZCURL_TEST_HTTP/echo"
done
file_fds "$ZCURL_TEST_TMP/upload-sparse.bin"
check $REPLY 33
zcurl --reset
file_fds "$ZCURL_TEST_TMP/upload-sparse.bin"
check $REPLY 1
zcurl http submit cancelled --data-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
zcurl http cancel cancelled
file_fds "$ZCURL_TEST_TMP/upload-sparse.bin"
check $REPLY 1
expect_code 42 zcurl http collect cancelled -r response
check $response[error_kind] cancelled
zcurl http submit dropped --data-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
zcurl http drop dropped
file_fds "$ZCURL_TEST_TMP/upload-sparse.bin"
check $REPLY 1
expect_code 2 zcurl http submit invalid --data-fd "$input" --output-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
file_fds "$ZCURL_TEST_TMP/upload-sparse.bin"
check $REPLY 1
expect_code 2 zcurl --data-fd "$input" --output-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
file_fds "$ZCURL_TEST_TMP/upload-sparse.bin"
check $REPLY 1
zcurl http submit expired --timeout 1 --data-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
zmodload zsh/zselect
zselect -t 3 || true
zcurl http wait expired
file_fds "$ZCURL_TEST_TMP/upload-sparse.bin"
check $REPLY 1
expect_code 28 zcurl http collect expired
expect_code 60 zcurl --data-fd "$input" -- "$ZCURL_TEST_HTTPS/echo"
file_fds "$ZCURL_TEST_TMP/upload-sparse.bin"
check $REPLY 1
zcurl http submit unloaded --data-fd "$input" -- "$ZCURL_TEST_HTTP/echo"
zmodload -u zcurl
file_fds "$ZCURL_TEST_TMP/upload-sparse.bin"
check $REPLY 1
exec {input}<&-
exec {out}>&-
print -r -- 'PASS: file uploads, captured ranges, binary round trips, methods, descriptor ownership and cleanup'
