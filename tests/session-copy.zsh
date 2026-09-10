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
typeset -A info original response saved
typeset -a jobs=(stale)
typeset trust="$ZCURL_TEST_TMP/copied ø[1]"$'\n.pem'
cp -- "$ZCURL_TEST_CA" "$trust"
zcurl session create template
zcurl session configure template --timeout 10000 --connect-timeout 2000 --max-body 1024 \
    --cacert "$trust" --proxy-cacert "$trust"
zcurl --session template "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 1
zcurl http submit source_job --session template -r response "$ZCURL_TEST_HTTPS/tiny"
saved=( "${(@kv)response}" )
# Copying a busy source neither drives nor duplicates its retained jobs.
() { local name=worker source_name=template; zcurl session create "$name" --from "$source_name"; }
zcurl session info template -r original
zcurl session info worker -r info
check $info[name] worker
check $info[retained_jobs] 0
check $original[retained_jobs] 1
for key in timeout connect_timeout max_body cacert proxy_cacert; do
    check "$info[$key]" "$original[$key]"
done
zcurl session jobs worker -r jobs
check $#jobs 0
check "${(j:,:)zcurl_http_sessions}" template,worker
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
zcurl http info source_job
check $zcurl_state pending
# Each synchronous pool is independent, and creating the copy keeps the warm source.
zcurl --session template "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 0
zcurl --session worker "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 1
zcurl --session worker "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 0
# Source configuration and lifetime cannot invalidate copied strings or limits.
zcurl session configure template --defaults
zcurl session configure worker --timeout 12000
zcurl session info template -r info
check $info[timeout] 10000
check "$info[cacert]" ''
zcurl session info worker -r info
check $info[timeout] 12000
check $info[connect_timeout] 2000
check $info[max_body] 1024
check "$info[cacert]" "$trust"
check "$info[proxy_cacert]" "$trust"
zcurl http wait source_job
zcurl http collect source_job
check "$zcurl_body" $'ok\n'
zcurl session drop template
zcurl http submit copied_job --session worker "$ZCURL_TEST_HTTPS/tiny"
zcurl http wait copied_job
zcurl http collect copied_job
check $zcurl_new_connections 1
zcurl --session worker "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 0
zcurl http submit copied_again --session worker "$ZCURL_TEST_HTTPS/tiny"
zcurl http wait copied_again
zcurl http collect copied_again
check $zcurl_new_connections 0
# Invalid creates preserve the registry, source settings and failed transfer globals.
expect_code 2 zcurl --session missing -r response "$ZCURL_TEST_HTTPS/tiny"
saved=( "${(@kv)response}" )
expect_code 2 zcurl session create worker --from worker
expect_code 2 zcurl session create absent --from absent
expect_code 2 zcurl session create absent --from template
expect_code 2 zcurl session create absent --from
expect_code 2 zcurl session create absent --from worker extra
expect_code 2 zcurl session create absent --from worker --from worker
expect_code 2 zcurl session create absent --from=worker
expect_code 2 zcurl session create absent --unknown worker
for name in '' bad-name $'worker\0tail'; do
    expect_code 2 zcurl session create absent --from "$name"
    expect_code 2 zcurl session create "$name" --from worker
done
typeset seed='' too_long
too_long=${(pl:65::x:)seed}
expect_code 2 zcurl session create "$too_long" --from worker
expect_code 2 zcurl session create absent --from "$too_long"
expect_code 2 zcurl session reset worker --from worker
expect_code 2 zcurl session drop worker --from worker
check "${(j:,:)zcurl_http_sessions}" worker
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
zcurl session info worker -r info
check "$info[cacert]" "$trust"
# Copying also works with discovery disabled and consumes an ordinary session slot.
zmodload -F zcurl -p:zcurl_http_sessions
zcurl session create hidden --from worker
zmodload -F zcurl +p:zcurl_http_sessions
check "${(j:,:)zcurl_http_sessions}" worker,hidden
for number in {1..14}; do zcurl session create copy_$number --from hidden; done
check $#zcurl_http_sessions 16
expect_code 2 zcurl session create overflow --from worker
zcurl session drop copy_1
zcurl session create replacement --from hidden
check $zcurl_http_sessions[-1] replacement
zcurl session drop worker
zcurl session info hidden -r info
check "$info[cacert]" "$trust"
zcurl session reset hidden
zcurl session info hidden -r info
check "$info[proxy_cacert]" "$trust"
zcurl --reset
check $#zcurl_http_sessions 0
# Unset CA defaults remain unset; repeated ownership cleanup includes module unload.
zcurl session create empty
zcurl session create defaults --from empty
zcurl session info defaults -r info
check $info[max_body] 8388608
check "$info[cacert]" ''
check "$info[proxy_cacert]" ''
repeat 3; do
    zcurl session configure empty -c "$trust" --proxy-cacert "$trust"
    zcurl session create owned --from empty
    zcurl session configure empty --defaults
    zcurl session drop owned
done
zcurl session configure empty -c "$trust" --proxy-cacert "$trust"
zcurl session create surviving --from empty
zcurl session drop empty
zmodload -u zcurl
check "$original[cacert]" "$trust"
print 'PASS: session configuration copies, independent pools, retained jobs, atomic creation and owned lifetimes'
