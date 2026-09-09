emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
fail() { print -ru2 -- "FAIL: $*"; exit 1 }
check() { [[ $1 == $2 ]] || fail "$1 != $2" }
expect_invalid() {
    local actual=0
    "$@" 2>/dev/null || actual=$?
    (( actual == 2 )) || fail "expected usage error, got $actual"
}
typeset -a values=(sentinel)
typeset -A response saved
local raw malformed target empty=''

# Live HTTP duplicates and saved snapshots keep individual values and order.
zcurl -r response -- "$ZCURL_TEST_HTTP/headers"
saved=( "${(@kv)response}" )
zcurl headers sEt-CoOkIe --from "$response[headers]" -r values
check ${#values} 2
check "$values[1]" one=1
check "$values[2]" two=2
check "$zcurl_body" "$response[body]"
check "$zcurl_headers" "$response[headers]"
check "$zcurl_status" "$response[status]"
zcurl headers X-Absent --from "$response[headers]" -r values
check ${#values} 0
zcurl headers Set-Cookie --from "$response[headers]" -r values --trailers
check ${#values} 0

# Concurrent completion remains collectable after looking up its snapshot.
zcurl http submit cookies -- "$ZCURL_TEST_HTTP/headers"
zcurl headers Set-Cookie --from "$saved[headers]" -r values
check $zcurl_event submitted
zcurl http wait cookies
zcurl headers Set-Cookie --from "$saved[headers]" -r values
check $zcurl_handle cookies
check $zcurl_event ready
zcurl http collect cookies -r response
zcurl --reset
zcurl headers Set-Cookie --from "$response[headers]" -r values
check ${#values} 2
check $zcurl_code -1

# Informational fields and response trailers never merge with final headers.
zcurl -r response -- "$ZCURL_TEST_HTTP/interim"
zcurl headers Link --from "$response[headers]" -r values
check ${#values} 0
zcurl headers Content-Length --from "$response[headers]" -r values
check "$values[1]" 3
zcurl -r response -- "$ZCURL_TEST_HTTP/chunked"
zcurl headers X-Trailer --from "$response[headers]" -r values
check ${#values} 0
zcurl headers X-Trailer --from "$response[headers]" -r values --trailers
check "$values[1]" yes

# Parsing must not replace a failed transfer's status or diagnostics.
zcurl --fail -- "$ZCURL_TEST_HTTP/missing" && fail 'expected HTTP error'
zcurl headers Set-Cookie --from "$saved[headers]" -r values
check $zcurl_status 22
check $zcurl_error_kind http
expect_invalid zcurl headers Bad:Name --from "$saved[headers]" -r values
check $zcurl_status 22
check $zcurl_error_kind http

# Synthetic callback transcripts cover proxy/auth blocks, HTTP/2/3 rendering,
# duplicate/empty values, whitespace, folding and bytes above ASCII.
raw=$'HTTP/1.1 200 Connection established\r\nX-Value: proxy\r\n\r\n'
raw+=$'HTTP/1.1 401 Unauthorized\r\nX-Value: auth\r\n\r\n'
raw+=$'HTTP/1.1 103 Early Hints\r\nX-Value: hint\r\n\r\n'
raw+=$'HTTP/2 200\r\nX-Value: \tfirst, second \t\r\nx-value:\r\n'
raw+=$'X-Value: same\r\nX-Value: same\r\nX-Value: alpha\r\n \tbeta\r\n'
raw+=$'X-Value: \t\r\n \r\n \tgamma \t\r\n \r\n'
raw+=$'X-Value: \200\377\r\nX-Value: $(touch should-not-exist)\r\n\r\n'
raw+=$'X-Value: trailer\r\nX-Value: trailer2\r\n\r\n'
zcurl headers x-value --from "$raw" -r values
check ${#values} 8
check "$values[1]" 'first, second'
check "$values[2]" ''
check "$values[3]" same
check "$values[4]" same
check "$values[5]" 'alpha beta'
check "$values[6]" gamma
check "$values[7]" $'\200\377'
check "$values[8]" '$(touch should-not-exist)'
zcurl headers X-Value --from "$raw" --trailers -r values
check ${#values} 2
check "$values[1]" trailer
check "$values[2]" trailer2
zcurl headers X --from $'HTTP/3 204\nX: lf\n\n' -r values
check "$values[1]" lf
zcurl headers X --from $'HTTP/1.1 101 Switching Protocols\r\nX: upgrade\r\n\r\n' -r values
check "$values[1]" upgrade
zcurl headers X --from $'HTTP/1.1 100 Continue\r\nX: interim\r\n\r\n' -r values
check ${#values} 0
zcurl headers X --from '' -r values
check ${#values} 0
# A failed transfer may still contain complete field lines before the blank line.
zcurl headers X --from $'HTTP/1.1 200 OK\r\nX: partial\r\n' -r values
check "$values[1]" partial

# Invalid input never partially publishes a result, even after a valid match.
values=(sentinel)
for malformed in $'X: orphan\r\n' $'HTTP/1.1 200 OK\r\nX: unterminated' \
    $'HTTP/1.1 200 OK\r\nX: good\r\nBad Name: value\r\n' \
    $'HTTP/1.1 200 OK\r\n continuation\r\n' $'HTTP/1.1 200 OK\r\nX: a\0b\r\n' \
    $'HTTP/1.1 200 OK\r\nX: a\rb\r\n' $'HTTP/1.1 200 OK\r\nX: a\177b\r\n' \
    $'HTTP/1.1 200 OK\r\nX: a\001b\r\n' $'HTTP/1.1 200 OK\r\nHTTP/2 200\r\n' \
    $'HTTP/2 999\r\n\r\n' $'HTTP/ 200\r\n\r\n' $'HTTP/2 20\r\n\r\n' \
    $'HTTP/2 200x\r\n\r\n' $'HTTP/1.1 200 OK\r\n\r\n\r\nX: late\r\n' \
    "${(pl:262145::x:)empty}"; do
    expect_invalid zcurl headers X --from "$malformed" -r values
    check "${(j:,:)values}" sentinel
done
local scalar=sentinel
local -ar readonly_values=(sentinel)
local -aU unique_values=(sentinel)
local -au upper_values=(sentinel)
for target in 'values[1+1]' 'values[$(touch should-not-exist)]' 'missing' 'scalar' \
    'response' 'readonly_values' 'unique_values' 'upper_values' 'path'; do
    expect_invalid zcurl headers X-Value --from "$raw" -r "$target"
done
expect_invalid zcurl headers X --from "$raw" --from "$raw" -r values
expect_invalid zcurl headers X --from "$raw" -r values --trailers --trailers
expect_invalid zcurl headers X --from "$raw"
expect_invalid zcurl headers X -r values
expect_invalid zcurl headers X --from "$raw" -r values --unknown
check "${(j:,:)values}" sentinel

# The inclusive raw-header bound also accepts a single large value.
raw=$'HTTP/2 200\nX: '"${(pl:262128::a:)empty}"$'\n\n'
zcurl headers X --from "$raw" -r values
check ${#values[1]} 262128
values=(sentinel)

# Dynamic scope and caller indexing/options do not change native publication.
lookup() { zcurl headers Set-Cookie --from "${saved[headers]}" -r values }
scoped() {
    local -a values=(local)
    setopt localoptions ksharrays shwordsplit globsubst rcexpandparam
    lookup
    [[ ${#values[@]} == 2 && ${values[0]} == one=1 && ${values[1]} == two=2 ]] || fail scope
}
scoped
check "${(j:,:)values}" sentinel
lookup
zmodload -u zcurl
check "$values[1]" one=1
check "$values[2]" two=2
print -r -- 'PASS: response header lookup, duplicates, blocks, trailers, validation, scope and preserved transfer state'
