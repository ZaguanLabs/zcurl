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
typeset -a names=(stale) copied selected
typeset -A response saved info
zcurl session create alpha
zcurl session create beta
zcurl session jobs alpha --result names
check ${#names} 0
zcurl http submit first --session alpha "$ZCURL_TEST_HTTP/tiny"
zcurl http submit outsider --session beta "$ZCURL_TEST_HTTP/tiny"
zcurl http submit unnamed "$ZCURL_TEST_HTTP/tiny"
zcurl http submit cancelled --session alpha "$ZCURL_TEST_HTTP/tiny"
zcurl http submit failed --session alpha --fail "$ZCURL_TEST_HTTP/missing"
zcurl http cancel cancelled -r response
saved=( "${(@kv)response}" )
zcurl session jobs alpha -r names
check "${(j:,:)names}" first,cancelled,failed
copied=( "$names[@]" )
zcurl session jobs alpha --state pending -r names
check "${(j:,:)names}" first,failed
zcurl session jobs alpha -r names --state cancelled
check "${(j:,:)names}" cancelled
zcurl session jobs alpha --state done -r names
check ${#names} 0
zcurl session jobs alpha --state all -r names
check "${(j:,:)names}" first,cancelled,failed
zcurl session jobs beta -r names
check "${(j:,:)names}" outsider
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
# Invalid queries must not publish even a partial list or drive any request.
typeset scalar=keep
typeset -ar locked=(keep)
typeset -aU unique=(keep)
typeset -au upper=(keep)
typeset original_upper=$upper[1]
for target in missing scalar response locked unique upper path zcurl_http_handles 'names[1]' $'names\0tail'; do
    expect_code 2 zcurl session jobs alpha -r "$target"
done
(( ! ${+missing} )) || exit 1
check $scalar keep
check $locked[1] keep
check $unique[1] keep
check "$upper[1]" "$original_upper"
expect_code 2 zcurl session jobs alpha
expect_code 2 zcurl session jobs alpha --state pending
expect_code 2 zcurl session jobs alpha -r
expect_code 2 zcurl session jobs alpha -r names --result selected
expect_code 2 zcurl session jobs alpha -r names --state pending --state done
expect_code 2 zcurl session jobs alpha -r names --state
for state in '' ready error Pending $'done\0tail'; do
    expect_code 2 zcurl session jobs alpha -r names --state "$state"
done
expect_code 2 zcurl session jobs alpha -r names --timeout 1
expect_code 2 zcurl session jobs alpha -r names extra
expect_code 2 zcurl session jobs absent -r names
expect_code 2 zcurl session jobs $'alpha\0tail' -r names
check "${(j:,:)names}" outsider
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
# Drop unselected jobs before any driver call. Origin counters detect query I/O.
zcurl http drop outsider
zcurl http drop unnamed
# Inspection reports recorded state even after the submission budget expires.
zcurl http submit expired --session alpha --timeout 1 "$ZCURL_TEST_HTTP/tiny"
sleep 0.03
zcurl session jobs alpha --state pending -r names
check "${(j:,:)names}" first,failed,expired
zcurl session jobs alpha --state done -r names
check ${#names} 0
zcurl http drop expired
zcurl http wait failed
zcurl http wait first
zcurl session jobs alpha --state done -r names
check "${(j:,:)names}" first,failed
zcurl session info alpha -r info
check $info[retained_jobs] 3
# The returned names can be passed directly to selected waits and collection.
zcurl http wait-any "$names[@]" -r response
check $response[handle] first
zcurl http collect first
expect_code 22 zcurl http collect failed -r response
saved=( "${(@kv)response}" )
zcurl session jobs alpha --state done -r names
check ${#names} 0
zcurl session jobs alpha -r names
check "${(j:,:)names}" cancelled
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
expect_code 42 zcurl http collect cancelled
zcurl session jobs alpha -r names
check ${#names} 0
check "${(j:,:)copied}" first,cancelled,failed

# Reusing a released handle moves it to the end of this session's list.
zcurl http submit second --session alpha "$ZCURL_TEST_HTTP/tiny"
zcurl http submit first --session alpha "$ZCURL_TEST_HTTP/tiny"
zcurl session jobs alpha -r names
check "${(j:,:)names}" second,first
zmodload -F zcurl -p:zcurl_http_sessions -p:zcurl_http_handles
zcurl session jobs alpha -r names --state pending
check "${(j:,:)names}" second,first
zmodload -F zcurl +p:zcurl_http_sessions +p:zcurl_http_handles
( zcurl session jobs alpha -r names ) 2>/dev/null && exit 1
() {
    emulate -L zsh
    setopt ksharrays shwordsplit globsubst
    local -a names=(old)
    zcurl session jobs beta -r names
    (( ${#names[@]} == 0 )) || exit 1
}
check "${(j:,:)names}" second,first
# Cleanup touches only this session; snapshots do not retain ownership.
zcurl http submit other --session beta "$ZCURL_TEST_HTTP/tiny"
for handle in "$names[@]"; do zcurl http drop "$handle"; done
zcurl session drop alpha
zcurl session jobs beta -r selected
check "${(j:,:)selected}" other
expect_code 2 zcurl session jobs alpha -r names
check "${(j:,:)names}" second,first
zcurl --reset
check "${(j:,:)copied}" first,cancelled,failed
zcurl session create alpha
zcurl session jobs alpha -r names
check ${#names} 0
zmodload -u zcurl
check "${(j:,:)copied}" first,cancelled,failed
zmodload zcurl
zcurl session create alpha
zcurl session jobs alpha -r names
check ${#names} 0
zmodload -u zcurl
print 'PASS: session job discovery, state filters, submission order, owned arrays, scoped cleanup and no-I/O validation'
