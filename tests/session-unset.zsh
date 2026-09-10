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
typeset -A info response saved original
typeset -a settings=(timeout connect-timeout max-body cacert proxy-cacert proxy noproxy)
zcurl session create configured
zcurl session configure configured --timeout 10000 --connect-timeout 2000 --max-body 1024 \
    -c "$ZCURL_TEST_CA" --proxy-cacert unused -x '' --noproxy ''
zcurl --session configured "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 1
zcurl session configure configured --unset timeout --unset connect-timeout --unset max-body
zcurl session info configured -r info
check $info[timeout] 10000
check $info[connect_timeout] 3000
check $info[max_body] 8388608
check "$info[cacert]" "$ZCURL_TEST_CA"
check "$info[proxy_cacert]" unused
check $info[proxy_set] 1
check $info[noproxy_set] 1
zcurl --session configured "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 0
# Retained jobs keep their accepted settings; removing trust affects future calls.
zcurl http submit retained --session configured "$ZCURL_TEST_HTTPS/tiny"
zcurl session configure configured --unset cacert --unset proxy-cacert --max-body 4096
zcurl http wait retained
zcurl http collect retained
check "$zcurl_body" $'ok\n'
expect_code 60 zcurl --session configured -r response "$ZCURL_TEST_HTTPS/tiny"
saved=( "${(@kv)response}" )
zcurl session info configured -r info
check "$info[cacert]" ''
check "$info[proxy_cacert]" ''
check $info[max_body] 4096
zcurl session configure configured --unset proxy --timeout 2000 --unset noproxy
zcurl session info configured -r info
check $info[proxy_set] 0
check $info[noproxy_set] 0
check $info[timeout] 2000
check $info[max_body] 4096
# Updates and unsets are one transaction; a setting may appear only once.
zcurl session configure configured --timeout 2000 --connect-timeout 1000 --max-body 2048 \
    -c "$ZCURL_TEST_CA" --proxy-cacert saved_proxy_ca --proxy '' --noproxy '*'
zcurl session info configured -r original
for setting in "${settings[@]}"; do
    expect_code 2 zcurl session configure configured --unset "$setting" --unset "$setting"
    expect_code 2 zcurl session configure configured --unset "$setting" "--$setting" value
    expect_code 2 zcurl session configure configured "--$setting" 123 --unset "$setting"
    expect_code 2 zcurl session configure configured --unset "$setting" --unknown value
done
expect_code 2 zcurl session configure configured --unset timeout -t 50
expect_code 2 zcurl session configure configured -c changed --unset cacert
expect_code 2 zcurl session configure configured --unset proxy -x ''
expect_code 2 zcurl session configure configured --proxy changed --unset cacert --noproxy $'bad\0tail'
expect_code 2 zcurl session configure configured --unset
expect_code 2 zcurl session configure configured --unset proxy --defaults
expect_code 2 zcurl session configure configured --defaults --unset proxy
expect_code 2 zcurl session configure configured --unset=proxy
for setting in '' '--proxy' '-x' 'connect_timeout' 'unknown' $'proxy\0tail'; do
    expect_code 2 zcurl session configure configured --unset "$setting"
done
zcurl session info configured -r info
for key in ${(k)original}; do check "$info[$key]" "$original[$key]"; done
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
# Each setting can be reset separately; copies own the original defaults.
zcurl session create copied --from configured
for setting in "${settings[@]}"; do
    zcurl session configure configured --unset "$setting"
done
zcurl session info configured -r info
check $info[timeout] 10000
check $info[connect_timeout] 3000
check $info[max_body] 8388608
for key in cacert proxy_cacert proxy noproxy; do check "$info[$key]" ''; done
check $info[proxy_set] 0
check $info[noproxy_set] 0
zcurl session info copied -r info
for key in timeout connect_timeout max_body cacert proxy_cacert proxy noproxy proxy_set noproxy_set; do
    check "$info[$key]" "$original[$key]"
done
# Repeated unsets across calls are idempotent and need no discovery feature.
zmodload -F zcurl -p:zcurl_http_sessions
repeat 3; do zcurl session configure copied --unset proxy --unset noproxy; done
() {
    emulate -L zsh
    setopt ksharrays shwordsplit globsubst
    local field=cacert
    zcurl session configure copied --unset "$field" --connect-timeout 5678
}
zcurl session info copied -r info
check "$info[cacert]" ''
check "$info[proxy_cacert]" saved_proxy_ca
check $info[connect_timeout] 5678
zcurl session drop configured
zcurl session drop copied
zmodload -u zcurl
check "$original[cacert]" "$ZCURL_TEST_CA"
print 'PASS: individual session defaults, atomic unset/update patches, retained jobs, trust, pool reuse and copied ownership'
