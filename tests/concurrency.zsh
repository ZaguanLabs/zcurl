emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
zmodload zsh/datetime
fail() { print -ru2 -- "FAIL: $* ($zcurl_error_kind: $zcurl_error)"; exit 1 }
check() { [[ $1 == $2 ]] || fail "$1 != $2" }
expect_code() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    (( actual == expected && zcurl_status == expected )) || fail "expected $expected, got $actual"
}
typeset -A event response saved seen
ready() {
    repeat 100; do
        zcurl http poll -r event --timeout 100
        [[ $event[event] == ready ]] && return 0
    done
    fail 'HTTP completion deadline exceeded'
}
collect() {
    ready
    check "$event[handle]" "$1"
    zcurl http collect "$1" -r response
}

# A server barrier proves overlap without a fragile speed comparison.
for scheme in HTTP HTTPS; do
    typeset base=${(P)${:-ZCURL_TEST_$scheme}}
    zcurl http submit first -r event -c "$ZCURL_TEST_CA" -- "$base/parallel/one"
    check $event[event] submitted
    check $event[state] pending
    (( ${#event} == 16 )) || fail 'async result shape'
    zcurl http submit second -c "$ZCURL_TEST_CA" -- "$base/parallel/two"
    seen=()
    repeat 2; do
        ready
        typeset handle=$event[handle]
        [[ ! -v "seen[$handle]" ]] || fail 'duplicate collection'
        zcurl http collect "$handle" -r response
        check $response[state] done
        check $response[event] collected
        check $response[complete] 1
        seen[$handle]=$response[body]
    done
    check "$seen[first]" /parallel/one
    check "$seen[second]" /parallel/two
done

# Submission must outlive the submitting function's arguments and locals.
zcurl "$ZCURL_TEST_HTTP/bytes"
typeset payload=$zcurl_body
submit_local() {
    emulate -L zsh
    local data=$payload url="$ZCURL_TEST_HTTPS/echo" ca=$ZCURL_TEST_CA
    local -A acknowledgment
    zcurl http submit owned -r acknowledgment -c "$ca" -X PUT \
        -H 'X-Owned: local' -d "$data" -- "$url"
    check $acknowledgment[event] submitted
}
submit_local
repeat 10; do typeset heap_churn=${(pl:4096::x:)payload}; done
collect owned
check "$response[body]" "$payload"
[[ $response[headers] == *'X-Request-Method: PUT'* ]] || fail 'owned method'
[[ $response[headers] == *'X-Observed-Owned: local'* ]] || fail 'owned header'
print -rn -- "$response[body]" > "$ZCURL_TEST_TMP/concurrent.bin"
saved=( "${(@kv)response}" )
zcurl http submit reuse -c "$ZCURL_TEST_CA" -- "$ZCURL_TEST_HTTPS/tiny"
collect reuse
check $response[new_connections] 0
[[ $response[headers] != *'X-Observed-Owned:'* ]] || fail 'request header leaked across jobs'
check "$saved[body]" "$payload"

# A slow partial response must not block a fast one or another transport.
zcurl http submit slow -- "$ZCURL_TEST_HTTP/held"
zcurl http submit fast -- "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl http collect slow -r response
check $response[state] pending
expect_code 2 zcurl http submit slow -- "$ZCURL_TEST_HTTP/tiny"
collect fast
repeat 20; do
    zcurl http poll --timeout 10
    zcurl http info slow -r event
    (( event[bytes] == 4 )) && break
done
check $event[bytes] 4
check $event[state] pending
zcurl ws open slow -- "${ZCURL_TEST_HTTP/http:/ws:}/ws"
zcurl http cancel slow -r event
check $event[event] cancelled
zcurl ws info slow
check $zcurl_state open
zcurl ws drop slow
expect_code 42 zcurl http collect slow -r response
check $response[error_kind] cancelled
check "$response[body]" part
check $response[complete] 0
check $response[http_status] 200
expect_code 2 zcurl http info slow
zcurl "$ZCURL_TEST_HTTP/release-http"

# Completed failures retain normal HTTP metadata and consume only on collect.
zcurl http submit missing --fail -- "$ZCURL_TEST_HTTP/missing"
zcurl http submit limit --max-body 2 -- "$ZCURL_TEST_HTTP/tiny"
zcurl http submit timeout --timeout 30 -- "$ZCURL_TEST_HTTP/slow"
zcurl http submit trust -- "$ZCURL_TEST_HTTPS/tiny"
zcurl http submit partial -- "$ZCURL_TEST_HTTP/truncated"
seen=()
repeat 5; do
    ready
    typeset handle=$event[handle]
    zcurl http collect "$handle" -r response && fail 'expected failed transfer'
    seen[$handle]=$response[status]
    case $handle in
        missing)
            check $response[http_status] 404
            check $response[code] 0
            check $response[complete] 1
            check "$response[body]" $'ok\n' ;;
        limit) check $response[error_kind] body-limit ;;
        timeout|trust) check $response[error_kind] transport ;;
        partial) check "$response[body]" $'ok\n' ;;
    esac
done
check $seen[missing] 22
check $seen[limit] 23
check $seen[timeout] 28
check $seen[trust] 60
check $seen[partial] 18

# The total deadline includes time before the first poll; no stale metadata.
zcurl http submit expired --timeout 1 -- "$ZCURL_TEST_HTTP/tiny"
sleep 0.02
ready
expect_code 28 zcurl http collect expired -r response
check $response[http_status] 0
check $response[bytes] 0

# A failed destination check cannot consume a ready result.
zcurl http submit retained -- "$ZCURL_TEST_HTTP/tiny"
ready
zcurl http poll -r response
check $response[handle] retained
typeset scalar=unchanged
expect_code 2 zcurl http collect retained -r scalar
check $scalar unchanged
scope_collect() {
    emulate -L zsh
    setopt ksharrays shwordsplit globsubst
    local -A response=(stale gone)
    zcurl http collect retained -r response
    [[ ${response[body]} == $'ok\n' && ! -v 'response[stale]' ]] || fail 'collection scope'
}
scope_collect
expect_code 2 zcurl http collect retained

# Polling a retained completion still advances newly submitted requests.
zcurl http submit old -- "$ZCURL_TEST_HTTP/tiny"
ready
zcurl http submit new -- "$ZCURL_TEST_HTTP/tiny"
repeat 100; do
    zcurl http poll
    zcurl http info new -r event
    [[ $event[state] == done ]] && break
    sleep 0.01
done
check $event[state] done
zcurl http drop old
zcurl http collect new

# Names, option parsing and inherited forks cannot mutate a live request.
zcurl http submit owner -- "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl http poll -r response --timeout 1001
check $response[error_kind] usage
expect_code 2 zcurl http submit 'bad[name]' -- "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl http submit invalid -r response -H $'X: bad\nfield' -- "$ZCURL_TEST_HTTP/tiny"
if (zcurl http cancel owner); then fail 'fork cancellation accepted'; fi
collect owner

# Admission reserves response limits, headers and copied arguments until release.
zcurl http submit reserve --max-body 67108864 -- "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl http submit overflow -r response --max-body 67108864 -- "$ZCURL_TEST_HTTP/tiny"
check $response[error_kind] queue-limit
zcurl http drop reserve
zcurl http submit overflow --max-body 67108864 -- "$ZCURL_TEST_HTTP/tiny"
zcurl http drop overflow
integer i
for i in {1..32}; do zcurl http submit "slot_$i" --max-body 1 -- "$ZCURL_TEST_HTTP/tiny"; done
expect_code 2 zcurl http submit extra -r response --max-body 1 -- "$ZCURL_TEST_HTTP/tiny"
check $response[error_kind] queue-limit
zcurl http cancel slot_1
expect_code 2 zcurl http submit extra --max-body 1 -- "$ZCURL_TEST_HTTP/tiny"
expect_code 42 zcurl http collect slot_1
zcurl http submit extra --max-body 1 -- "$ZCURL_TEST_HTTP/tiny"
zcurl --reset
expect_code 2 zcurl http info extra
zcurl http poll -r event --timeout 1000
check $event[event] idle

# Unload discards active and completed jobs; snapshots remain caller-owned.
zcurl http submit completed -- "$ZCURL_TEST_HTTP/tiny"
ready
zcurl http submit pending -- "$ZCURL_TEST_HTTP/tiny"
zmodload -u zcurl
check "$saved[body]" "$payload"
zmodload zcurl
expect_code 2 zcurl http info pending
zcurl http submit fresh -- "$ZCURL_TEST_HTTP/tiny"
collect fresh
zmodload -u zcurl
print -r -- 'PASS: concurrent HTTP/HTTPS overlap, owned requests, pool reuse, cancellation, bounds, collection and lifecycle'
