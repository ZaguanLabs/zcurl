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
zcurl session configure alpha --max-body 2
expect_code 23 zcurl --session alpha -r response "$ZCURL_TEST_HTTP/tiny"
check $response[error_kind] body-limit
saved=( "${(@kv)response}" )
zcurl session configure alpha --max-body 3
expect_code 2 zcurl session configure alpha --max-body 2 --timeout 0
expect_code 2 zcurl session configure alpha --defaults --timeout 10
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
zcurl --session alpha "$ZCURL_TEST_HTTP/tiny"
check "$zcurl_body" $'ok\n'
# Untouched fields survive partial configuration; pools stay warm.
zcurl session configure alpha --timeout 2000
zcurl --session alpha "$ZCURL_TEST_HTTP/tiny"
check $zcurl_new_connections 0
expect_code 23 zcurl --session alpha "$ZCURL_TEST_HTTP/bytes"
# Explicit options override defaults in either order and never become defaults.
zcurl --max-body 258 --session alpha "$ZCURL_TEST_HTTP/bytes"
check $zcurl_bytes 258
zcurl --session alpha --max-body 258 "$ZCURL_TEST_HTTP/bytes"
expect_code 23 zcurl --session alpha "$ZCURL_TEST_HTTP/bytes"
zcurl --session beta "$ZCURL_TEST_HTTP/bytes"
zcurl "$ZCURL_TEST_HTTP/bytes"
# Reset closes pools but retains policy; --defaults restores policy only.
zcurl session reset alpha
expect_code 23 zcurl --session alpha "$ZCURL_TEST_HTTP/bytes"
zcurl session configure alpha --defaults
zcurl --session alpha "$ZCURL_TEST_HTTP/bytes"
zcurl session configure alpha --max-body 3
zcurl session drop alpha
zcurl session create alpha
zcurl --session alpha "$ZCURL_TEST_HTTP/bytes"

# New defaults affect new jobs, leaving existing buffers and deadlines intact.
zcurl session configure alpha --max-body 258
zcurl http submit existing --session alpha "$ZCURL_TEST_HTTP/bytes"
zcurl session configure alpha --max-body 2
zcurl http submit limited --session alpha "$ZCURL_TEST_HTTP/bytes"
zcurl http submit overridden --max-body 258 --session alpha "$ZCURL_TEST_HTTP/bytes"
zcurl http wait existing
zcurl http collect existing
check $zcurl_bytes 258
zcurl http wait limited
expect_code 23 zcurl http collect limited
check $zcurl_error_kind body-limit
zcurl http wait overridden
zcurl http collect overridden
check $zcurl_bytes 258
# Configured size limits constrain direct file output too.
integer output_fd
exec {output_fd}>"$ZCURL_TEST_TMP/defaults-output.bin"
expect_code 23 zcurl --session alpha --output-fd "$output_fd" "$ZCURL_TEST_HTTP/bytes"
exec {output_fd}>&-
check $zcurl_error_kind body-limit
zcurl session configure alpha --defaults

zcurl session configure alpha -t 30
expect_code 28 zcurl --session alpha "$ZCURL_TEST_HTTP/slow"
zcurl -t 2000 --session alpha "$ZCURL_TEST_HTTP/slow"
zcurl --session alpha --timeout 2000 "$ZCURL_TEST_HTTP/slow"
zcurl http submit expiring --session alpha "$ZCURL_TEST_HTTP/slow"
zcurl session configure alpha --timeout 2000
zcurl http submit survivor --session alpha "$ZCURL_TEST_HTTP/slow"
zcurl http wait survivor
zcurl http collect survivor
check "$zcurl_body" $'ok\n'
zcurl http wait expiring
expect_code 28 zcurl http collect expiring

# A TCP peer accepts TLS bytes but never completes the handshake. The shorter
# connect budget must win over the five-second request budget.
zcurl session configure alpha --timeout 5000 --connect-timeout 100
expect_code 28 zcurl --session alpha "$ZCURL_TEST_STALLED_TLS"
(( zcurl_total_us < 2000000 )) || exit 1
zcurl http submit handshake --session alpha "$ZCURL_TEST_STALLED_TLS"
zcurl session configure alpha --connect-timeout 5000
zcurl http wait handshake
expect_code 28 zcurl http collect handshake
(( zcurl_total_us < 2000000 )) || exit 1
expect_code 28 zcurl --connect-timeout 100 --session alpha "$ZCURL_TEST_STALLED_TLS"
(( zcurl_total_us < 2000000 )) || exit 1
expect_code 28 zcurl --session alpha --connect-timeout 100 "$ZCURL_TEST_STALLED_TLS"
(( zcurl_total_us < 2000000 )) || exit 1

# Session defaults participate in admission accounting; accepted reservations
# stay unchanged if a session's defaults are increased afterwards.
zcurl session configure alpha --defaults
zcurl session configure alpha --max-body 1024
repeat 16; do
    zcurl http submit "job_${#zcurl_http_handles}" --session alpha "$ZCURL_TEST_HTTP/tiny"
done
zcurl session configure alpha --max-body 67108864
zcurl http submit large --session alpha "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl http submit overflow --session alpha "$ZCURL_TEST_HTTP/tiny"
check $zcurl_error_kind queue-limit
check ${#zcurl_http_handles} 17
zcurl session configure alpha --defaults
for handle in "$zcurl_http_handles[@]"; do zcurl http drop "$handle"; done

# Strict validation is atomic and preserves all transfer globals.
zcurl --session alpha -r response "$ZCURL_TEST_HTTP/tiny"
saved=( "${(@kv)response}" )
for field in --timeout --connect-timeout --max-body; do
    for value in '' 0 -1 1.5 999999999999999999999 $'12\0tail' nope; do
        expect_code 2 zcurl session configure alpha "$field" "$value"
    done
    expect_code 2 zcurl session configure alpha "$field"
    expect_code 2 zcurl session configure alpha "$field" 1 "$field" 2
done
expect_code 2 zcurl session configure alpha --timeout 600001
expect_code 2 zcurl session configure alpha --connect-timeout 600001
expect_code 2 zcurl session configure alpha --max-body 67108865
expect_code 2 zcurl session configure alpha --timeout 10 -t 20
expect_code 2 zcurl session configure alpha
expect_code 2 zcurl session configure absent --defaults
expect_code 2 zcurl session configure alpha --defaults --defaults
expect_code 2 zcurl session configure alpha --max-body 1 --defaults
expect_code 2 zcurl session configure alpha --proxy ''
expect_code 2 zcurl session configure alpha --result response
expect_code 2 zcurl session configure alpha --timeout=10
zcurl session configure alpha --timeout 1 --connect-timeout 1 --max-body 1
zcurl session configure alpha --timeout 600000 --connect-timeout 600000 --max-body 67108864
zcurl session configure alpha --defaults
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
# Feature toggles and caller options leave configuration and ownership intact.
zcurl session configure alpha --max-body 2
zmodload -F zcurl -p:zcurl_http_sessions
expect_code 23 zcurl --session alpha "$ZCURL_TEST_HTTP/tiny"
zmodload -F zcurl +p:zcurl_http_sessions
( zcurl session configure alpha --defaults ) 2>/dev/null && exit 1
() {
    emulate -L zsh
    setopt ksharrays shwordsplit globsubst
    local chosen=alpha
    zcurl session configure "$chosen" --max-body 3
    zcurl --session "$chosen" "$ZCURL_TEST_HTTP/tiny"
}
zcurl --reset
zcurl session create alpha
zcurl --session alpha "$ZCURL_TEST_HTTP/bytes"
zmodload -u zcurl
print 'PASS: session defaults, explicit overrides, atomic updates, retained job snapshots, connection deadlines and admission'
