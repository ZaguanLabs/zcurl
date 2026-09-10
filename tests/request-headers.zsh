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
typeset -a fields=(-H 'a:')
typeset -A response
# 65,536 shortest legal field specifications exactly fill the 256 KiB budget.
repeat 16; do fields=( "${fields[@]}" "${fields[@]}" ); done
expect_code 2 zcurl "${fields[@]}" --result nonexistent
[[ $zcurl_error == '--result requires'* ]] || exit 1
# One more field must fail before the trailing result-target validation.
expect_code 2 zcurl "${fields[@]}" -H 'a:' --result nonexistent
[[ $zcurl_error == *'request headers exceed 256 KiB'* ]] || exit 1
# Use a single long field to cover the same boundary in both other parsers.
typeset seed='' large
large="X:${(pl:262140::x:)seed}"
expect_code 2 zcurl http submit oversized -H "$large" -H 'a:' "$ZCURL_TEST_HTTP/tiny"
check $#zcurl_http_handles 0
expect_code 2 zcurl ws open oversized -H "$large" -H 'a:' "${ZCURL_TEST_HTTP/http:/ws:}/ws"
check $#zcurl_ws_handles 0
# Generate enough duplicate headers to exercise head/tail/order, below server limits.
fields=()
for number in {1..40}; do fields+=( --header "X-Batch: value_$number" ); done
zcurl "${fields[@]}" -r response "$ZCURL_TEST_HTTP/inspect"
print -rn -- "$response[body]" > "$ZCURL_TEST_TMP/header-batch-sync.json"
zcurl http submit owned "${fields[@]}" "$ZCURL_TEST_HTTP/inspect"
fields=( -H 'X-Batch: fresh' )
zcurl http wait owned
zcurl http collect owned -r response
print -rn -- "$response[body]" > "$ZCURL_TEST_TMP/header-batch-async.json"
zcurl "${fields[@]}" -r response "$ZCURL_TEST_HTTP/inspect"
print -rn -- "$response[body]" > "$ZCURL_TEST_TMP/header-batch-fresh.json"
# A generated subprotocol header must append after every caller header.
fields=()
for number in {1..40}; do fields+=( -H "X-Batch: value_$number" ); done
zcurl ws open owned "${fields[@]}" --subprotocol fixture.v1 "${ZCURL_TEST_HTTP/http:/ws:}/ws-header-batch"
fields=()
zcurl ws drop owned
# Partial lists are released on validation failures and retained-handle cleanup.
repeat 3; do
    expect_code 2 zcurl -H 'X-Batch: valid' -H $'Bad: injected\r\nNext: value' "$ZCURL_TEST_HTTP/tiny"
    expect_code 2 zcurl http submit invalid -H 'X-Batch: valid' -H 'invalid' "$ZCURL_TEST_HTTP/tiny"
    expect_code 2 zcurl ws open invalid -H 'X-Batch: valid' -H 'invalid' "${ZCURL_TEST_HTTP/http:/ws:}/ws"
    zcurl http submit dropped -H 'X-Batch: owned' "$ZCURL_TEST_HTTP/tiny"
    zcurl http drop dropped
done
zcurl http submit reset_owned -H 'X-Batch: reset' "$ZCURL_TEST_HTTP/tiny"
zcurl --reset
zcurl http submit unload_owned -H 'X-Batch: unload' "$ZCURL_TEST_HTTP/tiny"
zmodload -u zcurl
print 'PASS: request header boundaries, duplicate ordering, independent ownership and partial-list cleanup'
