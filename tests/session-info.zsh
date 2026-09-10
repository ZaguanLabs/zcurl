emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
check() { [[ $1 == $2 ]] || { print -ru2 -- "FAIL: $1 != $2"; exit 1; } }
expect_code() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    check "$actual" "$expected"
}
typeset -A info=(stale gone) copied response saved
zcurl session create alpha
zcurl session create beta
zcurl session info alpha --result info
check ${#info} 7
check $info[name] alpha
check $info[timeout] 10000
check $info[connect_timeout] 3000
check $info[max_body] 8388608
check $info[retained_jobs] 0
(( ! ${+info[stale]} )) || exit 1
zcurl --session alpha "$ZCURL_TEST_HTTP/tiny"
zcurl session info alpha -r info
zcurl --session alpha "$ZCURL_TEST_HTTP/tiny"
check $zcurl_new_connections 0
zcurl session configure alpha --timeout 1234 --connect-timeout 321 --max-body 2048
zcurl session info alpha -r info
copied=( "${(@kv)info}" )
check $info[timeout] 1234
check $info[connect_timeout] 321
check $info[max_body] 2048
zcurl session info beta -r info
check $info[timeout] 10000
check $copied[name] alpha
check $copied[timeout] 1234

# Read-only inspection preserves failed transfer globals and old snapshots.
expect_code 22 zcurl --session alpha --fail -r response "$ZCURL_TEST_HTTP/missing"
saved=( "${(@kv)response}" )
zcurl session info alpha -r info
expect_code 2 zcurl session info unknown -r info
check $info[name] alpha
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
check $response[status] 22

# Counts include pending, done and cancelled jobs in this session only.
zcurl http submit first --session alpha -r response "$ZCURL_TEST_HTTP/tiny"
saved=( "${(@kv)response}" )
repeat 20; do zcurl session info alpha -r info; done
check $info[retained_jobs] 1
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
zcurl http info first
check $zcurl_state pending
zcurl http submit other --session beta "$ZCURL_TEST_HTTP/tiny"
zcurl http submit unnamed "$ZCURL_TEST_HTTP/tiny"
zcurl session info alpha -r info
check $info[retained_jobs] 1
zcurl session info beta -r info
check $info[retained_jobs] 1
zcurl http drop other
zcurl http drop unnamed
zcurl http wait first
zcurl session info alpha -r info
check $info[retained_jobs] 1
expect_code 2 zcurl session reset alpha
zcurl http collect first
zcurl session info alpha -r info
check $info[retained_jobs] 0
zcurl http submit cancelled --session alpha "$ZCURL_TEST_HTTP/tiny"
zcurl http cancel cancelled
zcurl session info alpha -r info
check $info[retained_jobs] 1
expect_code 42 zcurl http collect cancelled
zcurl session info alpha -r info
check $info[retained_jobs] 0
# Pool reset keeps defaults; standard reset and recreation are visible.
zcurl session reset alpha
zcurl session info alpha -r info
check $info[max_body] 2048
zcurl session configure alpha --defaults
zcurl session info alpha -r info
check $info[max_body] 8388608
check $copied[max_body] 2048
zcurl session configure alpha --timeout 600000 --connect-timeout 1 --max-body 67108864
zcurl session info alpha -r info
check $info[timeout] 600000
check $info[connect_timeout] 1
check $info[max_body] 67108864

# Errors leave the destination intact, including invalid parameter attributes.
saved=( "${(@kv)info}" )
typeset scalar=keep
typeset -a indexed=(keep)
typeset -Ar locked=(keep value)
typeset -Al lowered=(keep value)
typeset -A strange_name_ø=(keep value)
for target in missing scalar indexed locked lowered options zcurl_http_sessions 'info[key]' strange_name_ø $'info\0tail'; do
    expect_code 2 zcurl session info alpha -r "$target"
done
(( ! ${+missing} )) || exit 1
check $scalar keep
check $indexed[1] keep
check $locked[keep] value
check $lowered[keep] value
check $strange_name_ø[keep] value
expect_code 2 zcurl session info alpha
expect_code 2 zcurl session info alpha -r
expect_code 2 zcurl session info alpha -r info --result response
expect_code 2 zcurl session info alpha --timeout 10
expect_code 2 zcurl session info alpha --result=info
expect_code 2 zcurl session info alpha -r info extra
expect_code 2 zcurl session info $'alpha\0tail' -r info
for key in ${(k)saved}; do check "$info[$key]" "$saved[$key]"; done

# Publication follows ordinary dynamic scope, even under caller emulation.
() {
    emulate -L zsh
    setopt ksharrays shwordsplit globsubst
    local -A info=(old gone)
    zcurl session info beta -r info
    [[ ${info[name]} == beta && ${#info[@]} == 7 ]] || exit 1
}
check $info[name] alpha
zmodload -F zcurl -p:zcurl_http_sessions
zcurl session info alpha -r info
check $info[timeout] 600000
zmodload -F zcurl +p:zcurl_http_sessions
( zcurl session info alpha -r info ) 2>/dev/null && exit 1
check $info[name] alpha
zcurl session drop alpha
expect_code 2 zcurl session info alpha -r info
check $info[timeout] 600000
zcurl session create alpha
zcurl session info alpha -r info
check $info[timeout] 10000
zcurl --reset
expect_code 2 zcurl session info alpha -r info
check $info[name] alpha
zmodload -u zcurl
check $copied[max_body] 2048
zmodload zcurl
zcurl session create alpha
zcurl session info alpha -r info
check $info[max_body] 8388608
zmodload -u zcurl
print 'PASS: session information, owned metadata, configuration visibility, retained-job counts, validation and preserved results'
