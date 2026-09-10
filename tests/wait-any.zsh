emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
fail() { print -ru2 -- "FAIL: $*"; exit 1 }
check() { [[ $1 == $2 ]] || fail "$1 != $2" }
expect_code() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    check $actual $expected
}
typeset -A event response
typeset -Ar locked=(keep value)

# Every invalid selection must fail before driving this pending request.
zcurl http submit untouched -- "$ZCURL_TEST_HTTP/tiny"
expect_code 2 zcurl http wait-any
expect_code 2 zcurl http wait-any -r event
expect_code 2 zcurl http wait-any untouched missing -r event
check $event[error_kind] state
expect_code 2 zcurl http wait-any untouched untouched -r event
check $event[error_kind] usage
expect_code 2 zcurl http wait-any -r event untouched --timeout 600001
expect_code 2 zcurl http wait-any untouched --timeout -1
expect_code 2 zcurl http wait-any untouched -t 1 --timeout 2
expect_code 2 zcurl http wait-any untouched -r 'event[body]'
expect_code 2 zcurl http wait-any untouched -r locked
expect_code 2 zcurl http wait-any untouched --compressed
expect_code 2 zcurl http wait-any untouched -- -t
expect_code 2 zcurl http wait-any untouched $'bad\0tail'
typeset -a excessive=()
# Exceed the argument bound before resolving or deduplicating handles.
repeat 33; do excessive+=( untouched ); done
expect_code 2 zcurl http wait-any "$excessive[@]"
zcurl http info untouched
check $zcurl_state pending
check $zcurl_bytes 0
zcurl http drop untouched

# Unrelated retained completions cannot mask a selected fast request.
zcurl http submit outside -- "$ZCURL_TEST_HTTP/tiny"
zcurl http cancel outside
zcurl http submit slow -- "$ZCURL_TEST_HTTP/slow"
zcurl http submit fast -- "$ZCURL_TEST_HTTP/tiny"
zcurl http wait-any slow fast -r event
check $event[handle] fast
check $event[event] ready
check ${#event} 16
check "$event[body]" ''
zcurl http info outside
check $zcurl_state cancelled
zcurl http wait slow
# When several selected jobs are ready, submission order wins over argument order.
zcurl http wait-any fast -t 0 slow -r event
check $event[handle] slow
zcurl http collect slow -r response
check "$response[body]" $'ok\n'
zcurl http wait-any --timeout 0 --result event -- fast
check $event[handle] fast
zcurl http collect fast
zcurl http wait-any outside -r event --timeout 0
check $event[state] cancelled
check $event[status] 0
expect_code 42 zcurl http collect outside

# Waiting on a subset must still drive unselected dependencies, over HTTP/TLS.
for scheme in plain secure; do
    typeset -a tls_options=()
    url=$ZCURL_TEST_HTTP
    if [[ $scheme == secure ]]; then
        url=$ZCURL_TEST_HTTPS
        tls_options=( -c "$ZCURL_TEST_CA" )
    fi
    zcurl http submit selected "$tls_options[@]" -- "$url/parallel/one"
    zcurl http submit dependency "$tls_options[@]" -- "$url/parallel/two"
    zcurl http wait-any selected -r event --timeout 3000
    check $event[handle] selected
    zcurl http collect selected -r response
    check "$response[body]" /parallel/one
    zcurl http wait-any dependency
    zcurl http collect dependency -r response
    check "$response[body]" /parallel/two
done

# An independent wait timeout preserves every handle, with no selected result.
zcurl http submit pending -- "$ZCURL_TEST_HTTP/slow"
expect_code 28 zcurl http wait-any -r event -t 0 pending
check $event[event] timeout
check $event[error_kind] wait-timeout
check "$event[handle]" ''
check "$event[state]" ''
check $event[bytes] 0
() {
    setopt localoptions ksharrays shwordsplit globsubst
    local -A scoped
    zcurl http wait-any --result scoped pending
    check "${scoped[handle]}" pending
}
zcurl http collect pending
zcurl http submit failed --fail -- "$ZCURL_TEST_HTTP/missing"
zcurl http wait-any failed -r event
check $event[code] 0
expect_code 22 zcurl http collect failed
zcurl http submit expired -t 1 -- "$ZCURL_TEST_HTTP/tiny"
sleep 0.02
zcurl http wait-any expired -r event -t 0
check $event[handle] expired
expect_code 28 zcurl http collect expired
check ${#zcurl_http_handles} 0
# The inclusive selection bound accepts all 32 jobs; retained cancellations
# make this exercise independent of socket limits and network timing.
typeset -a all_handles=()
for index in {1..32}; do
    handle=slot_$index
    zcurl http submit "$handle" --max-body 1 -- "$ZCURL_TEST_HTTP/tiny"
    zcurl http cancel "$handle"
    all_handles+=( "$handle" )
done
zcurl http wait-any "$all_handles[@]" -r event -t 0
check $event[handle] slot_1
zcurl --reset
zmodload -u zcurl
print 'PASS: wait-any selection, validation, ordering, shared-pool progress, deadlines, errors and scope'
