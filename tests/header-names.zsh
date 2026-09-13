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
typeset -a names=(stale) values unique_names
typeset -A response saved
zcurl -r response "$ZCURL_TEST_HTTP/headers"
saved=( "${(@kv)response}" )
zcurl headers --names --from "$response[headers]" -r names
check "${(j:,:)names}" server,date,content-length,content-type,x-request-method,set-cookie,set-cookie
unique_names=( "${(@u)names}" )
check $#unique_names 6
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
zcurl http submit untouched "$ZCURL_TEST_HTTP/tiny"
zcurl headers --names --from "$response[headers]" -r names
check $zcurl_event submitted
check $zcurl_state pending
zcurl http drop untouched
expect_code 22 zcurl --fail -r response "$ZCURL_TEST_HTTP/missing"
saved=( "${(@kv)response}" )
# The final block wins; names use ASCII lowercase and keep duplicates and order.
typeset raw=$'HTTP/1.1 200 Connection established\r\nProxy-Field: proxy\r\n\r\n'
raw+=$'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: auth\r\n\r\n'
raw+=$'HTTP/1.1 103 Early Hints\r\nLink: hint\r\n\r\n'
raw+=$'HTTP/3 200\r\nX-Mixed: one\r\n \ttwo\r\nx-MIXED:\r\n'
raw+=$'Set-Cookie: first\r\nX-$HOME: \200\377\r\n--names: literal\r\n--field: other\r\n\r\n'
raw+=$'Digest: first\r\n second\r\ndIgEsT: duplicate\r\n\r\n'
zcurl headers --names --from "$raw" --result names
check "${(j:,:)names}" 'x-mixed,x-mixed,set-cookie,x-$home,--names,--field'
zcurl headers --names --from "$raw" --trailers -r names
check "${(j:,:)names}" digest,digest
zcurl headers --field --names --from "$raw" -r values
check "$values[1]" literal
zcurl headers --field --field --from "$raw" -r values
check "$values[1]" other
# An explicit field selector makes discovery-driven lookup safe for every token.
zcurl headers --names --from "$raw" -r names
for field in "${(@u)names}"; do
    zcurl headers --field "$field" --from "$raw" -r values
    (( $#values > 0 )) || exit 1
done
zcurl headers --names --from $'HTTP/1.1 101 Switching Protocols\nUpgrade: websocket\n\n' -r names
check "$names[1]" upgrade
zcurl headers --names --from $'HTTP/2 103\nLink: ignored\n\n' -r names
check $#names 0
zcurl headers --names --from '' -r names
check $#names 0
zcurl headers --names --from $'HTTP/2 200\nComplete-Line: partial\n' -r names
check "$names[1]" complete-line
# Output storage handles an inclusive maximum-length name and many occurrences.
typeset seed='' large lines=$'X:\n'
large=${(pl:262130::A:)seed}
zcurl headers --names --from $'HTTP/2 200\n'"$large"$':\n\n' -r names
check ${#names[1]} 262130
check "$names[1]" "${(L)large}"
repeat 14; do lines+=$lines; done
zcurl headers --names --from $'HTTP/2 200\n'"$lines"$'\n' -r names
check $#names 16384
check "$names[1]" x
check "$names[-1]" x
# Validation is atomic, and malformed values still fail when only names are wanted.
names=(sentinel)
expect_code 2 zcurl headers --names --from $'HTTP/2 200\nGood: ok\nBad: a\001b\n\n' -r names
expect_code 2 zcurl headers --names --from "$raw" -r names --names
expect_code 2 zcurl headers --names --field X --from "$raw" -r names
expect_code 2 zcurl headers --field
expect_code 2 zcurl headers --field '' --from "$raw" -r names
expect_code 2 zcurl headers --field $'X\0tail' --from "$raw" -r names
check "$names[1]" sentinel
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
() {
    emulate -L zsh
    setopt ksharrays shwordsplit globsubst
    local -a names=(old)
    zcurl headers --names --from "$raw" --trailers -r names
    [[ ${#names[@]} == 2 && ${names[0]} == digest ]] || exit 1
}
check "$names[1]" sentinel
zcurl --reset
zcurl headers --names --from "$raw" -r names
zmodload -u zcurl
check "$names[1]" x-mixed
check "$names[-1]" --field
print 'PASS: response field discovery, canonical names, duplicates, block/trailer selection, literal selectors and owned arrays'
