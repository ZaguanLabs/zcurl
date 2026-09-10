emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
check() { [[ $1 == $2 ]] || { print -ru2 -- "FAIL: $1 != $2 ($zcurl_error_kind: $zcurl_error)"; exit 1; } }
expect_code() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    check "$actual" "$expected"
}
typeset -A response saved
zcurl session create alpha
zcurl session create beta

# Reuse stays inside each execution model and session, including the default.
for chosen in alpha beta default; do
    typeset -a selection=()
    [[ $chosen == default ]] || selection=( --session "$chosen" )
    for expected in 1 0; do
        zcurl http submit request "$selection[@]" -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
        zcurl http wait request
        zcurl http collect request -r response
        check $response[new_connections] $expected
        check ${#response} 16
        check "$response[body]" $'ok\n'
    done
done
zcurl --session alpha -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 1
zcurl session reset alpha
zcurl --session alpha -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 1
for chosen in alpha beta default; do
    typeset -a selection=()
    [[ $chosen == default ]] || selection=( --session "$chosen" )
    zcurl http submit request "$selection[@]" -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
    zcurl http wait request
    zcurl http collect request
    if [[ $chosen == alpha ]]; then check $zcurl_new_connections 1; else check $zcurl_new_connections 0; fi
done

# Waiting for one pool must drive the other side of a server response barrier.
# Cover named/named and named/default, TLS/plain, selected wait and wait-any.
for scheme in HTTP HTTPS; do
    typeset base=${(P)${:-ZCURL_TEST_$scheme}}
    for chosen in beta default; do
        typeset -a selection=()
        [[ $chosen == default ]] || selection=( --session "$chosen" )
        zcurl http submit first --session alpha -c "$ZCURL_TEST_CA" "$base/parallel/one"
        zcurl http submit second "$selection[@]" -c "$ZCURL_TEST_CA" "$base/parallel/two"
        if [[ $chosen == beta ]]; then
            zcurl http wait second -r response
        else
            zcurl http wait-any second -r response
        fi
        check $response[handle] second
        zcurl http collect second
        check "$zcurl_body" /parallel/two
        zcurl http wait first
        zcurl http collect first
        check "$zcurl_body" /parallel/one
    done
done

# A terminal job pins its session until collection, including cancellation.
zcurl http submit held --session alpha "$ZCURL_TEST_HTTP/tiny"
zcurl http info held -r response
saved=( "${(@kv)response}" )
expect_code 2 zcurl session reset alpha
expect_code 2 zcurl session drop alpha
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
zcurl session reset beta
zcurl http wait held
expect_code 2 zcurl session drop alpha
zcurl http collect held
zcurl session reset alpha
zcurl http submit cancelled --session alpha "$ZCURL_TEST_HTTP/tiny"
zcurl http cancel cancelled
expect_code 2 zcurl session reset alpha
expect_code 42 zcurl http collect cancelled
zcurl session drop alpha
zcurl session create alpha
zcurl http submit dropped --session alpha "$ZCURL_TEST_HTTP/tiny"
zcurl http drop dropped
zcurl session reset alpha

# Failed admission must not leave a job pin behind or allocate a fallback pool.
expect_code 2 zcurl http submit invalid --session unknown --output-fd 999999 "$ZCURL_TEST_HTTP/tiny"
check $zcurl_error_kind state
expect_code 2 zcurl http submit invalid --session alpha --session beta "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl http submit invalid --session alpha --output-fd 999999 "$ZCURL_TEST_HTTP/tiny"
zcurl session reset alpha
check ${#zcurl_http_handles} 0

# Storage reservation is also global, and failed admission leaves no pin.
zcurl http submit large --session alpha --max-body 67108864 "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl http submit overflow --session beta --max-body 67108864 "$ZCURL_TEST_HTTP/tiny"
check $zcurl_error_kind queue-limit
zcurl session reset beta
zcurl http drop large
zcurl http submit released --session beta --max-body 67108864 "$ZCURL_TEST_HTTP/tiny"
zcurl http drop released

# Transfer failure in one pool does not prevent another pool from finishing.
zcurl http submit expired --session alpha --timeout 20 "$ZCURL_TEST_HTTP/slow"
zcurl http submit survivor --session beta "$ZCURL_TEST_HTTP/slow"
zcurl http wait survivor
zcurl http collect survivor
check "$zcurl_body" $'ok\n'
zcurl http wait expired
expect_code 28 zcurl http collect expired
zcurl session reset alpha

# Caller descriptors can close after submit; the session owns retained copies.
print -rn -- $'named\0concurrent\n\n' > "$ZCURL_TEST_TMP/session-job-input.bin"
integer input_fd output_fd
exec {input_fd}<"$ZCURL_TEST_TMP/session-job-input.bin"
exec {output_fd}>"$ZCURL_TEST_TMP/session-job-output.bin"
zcurl http submit files --session beta --data-fd "$input_fd" --output-fd "$output_fd" "$ZCURL_TEST_HTTP/echo"
exec {input_fd}<&-
exec {output_fd}>&-
zcurl http wait files
zcurl http collect files -r response
check "$response[body]" ''
check $response[bytes] 18
check $response[complete] 1

# The global 32-job cap cannot be multiplied by creating additional sessions.
# All 17 pools participate in one wait, including a default-pool request.
for number in {1..14}; do zcurl session create "slot_$number"; done
for chosen in "$zcurl_http_sessions[@]"; do
    zcurl http submit "one_$chosen" --session "$chosen" --max-body 1024 "$ZCURL_TEST_HTTP/tiny"
done
zcurl http submit default --max-body 1024 "$ZCURL_TEST_HTTP/tiny"
for number in {1..15}; do
    zcurl http submit "extra_$number" --session beta --max-body 1024 "$ZCURL_TEST_HTTP/tiny"
done
expect_code 2 zcurl http submit overflow --session alpha --max-body 1024 "$ZCURL_TEST_HTTP/tiny"
check $zcurl_error_kind queue-limit
check ${#zcurl_http_handles} 32
while (( ${#zcurl_http_handles} )); do
    zcurl http wait-any "$zcurl_http_handles[@]" -r response
    zcurl http collect "$response[handle]"
    check "$zcurl_body" $'ok\n'
done
for chosen in "$zcurl_http_sessions[@]"; do zcurl session drop "$chosen"; done

# Explicit global cleanup can release sessions containing uncollected jobs.
repeat 3; do
    zcurl session create live
    zcurl http submit retained --session live "$ZCURL_TEST_HTTP/tiny"
    zcurl http wait retained
    zcurl http submit pending --session live "$ZCURL_TEST_HTTP/tiny"
    zcurl --reset
    check ${#zcurl_http_handles} 0
    check ${#zcurl_http_sessions} 0
    zcurl session create live
    zcurl http submit retained --session live "$ZCURL_TEST_HTTP/tiny"
    zcurl http wait retained
    zcurl http submit pending --session live "$ZCURL_TEST_HTTP/tiny"
    zmodload -u zcurl
    zmodload zcurl
done
zmodload -u zcurl
print 'PASS: named concurrent sessions, pool isolation, cross-pool waits, admission limits and retained-job lifecycle'
