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
typeset -A info copied response saved
typeset trust="$ZCURL_TEST_TMP/ca ø[1]"$'\n.pem'
cp -- "$ZCURL_TEST_CA" "$trust"
zcurl session create alpha
zcurl session create beta
zcurl session info alpha -r info
check ${#info} 7
check "$info[cacert]" ''
check "$info[proxy_cacert]" ''
expect_code 60 zcurl --session alpha "$ZCURL_TEST_HTTPS/tiny"
() { local path_copy=$trust; zcurl session configure alpha -c "$path_copy"; }
zcurl session info alpha -r info
check "$info[cacert]" "$trust"
copied=( "${(@kv)info}" )
zcurl --session alpha "$ZCURL_TEST_HTTPS/tiny"
zcurl --session alpha "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 0
expect_code 60 zcurl --session beta "$ZCURL_TEST_HTTPS/tiny"
expect_code 60 zcurl "$ZCURL_TEST_HTTPS/tiny"
expect_code 60 zcurl --session alpha "$ZCURL_TEST_MISMATCH/tiny"
expect_code 77 zcurl -c "$ZCURL_TEST_TMP/missing.pem" --session alpha "$ZCURL_TEST_HTTPS/tiny"
expect_code 77 zcurl --session alpha -c "$ZCURL_TEST_TMP/missing.pem" "$ZCURL_TEST_HTTPS/tiny"
zcurl --session alpha "$ZCURL_TEST_HTTPS/tiny"
# Partial updates retain paths; reset retains configuration and snapshots.
zcurl session configure alpha --timeout 2000
zcurl session reset alpha
zcurl --session alpha "$ZCURL_TEST_HTTPS/tiny"
zcurl session info alpha -r info
check "$info[cacert]" "$trust"
# An already submitted request keeps its copied CA path after reconfiguration.
zcurl http submit retained --session alpha "$ZCURL_TEST_HTTPS/tiny"
zcurl session configure alpha --cacert ''
zcurl http submit untrusted --session alpha "$ZCURL_TEST_HTTPS/tiny"
zcurl http wait retained
zcurl http collect retained
check "$zcurl_body" $'ok\n'
zcurl http wait untrusted
expect_code 60 zcurl http collect untrusted
zcurl http submit override --session alpha -c "$trust" "$ZCURL_TEST_HTTPS/tiny"
zcurl http wait override
zcurl http collect override
zcurl session info alpha -r info
check "$info[cacert]" ''
check "$copied[cacert]" "$trust"
expect_code 60 zcurl --session alpha -r response "$ZCURL_TEST_HTTPS/tiny"
saved=( "${(@kv)response}" )
# Validate the whole patch before replacing any path or numeric setting.
zcurl session configure alpha --cacert "$trust" --proxy-cacert "$trust"
expect_code 2 zcurl session configure alpha --cacert changed --proxy-cacert changed --timeout 0
expect_code 2 zcurl session configure alpha --cacert changed -c duplicate
expect_code 2 zcurl session configure alpha --proxy-cacert changed --proxy-cacert duplicate
for flag in --cacert --proxy-cacert; do
    expect_code 2 zcurl session configure alpha "$flag"
    expect_code 2 zcurl session configure alpha "$flag" $'bad\0tail'
    expect_code 2 zcurl session configure alpha "$flag" changed --defaults
    expect_code 2 zcurl session configure alpha --defaults "$flag" changed
done
zcurl session info alpha -r info
check "$info[cacert]" "$trust"
check "$info[proxy_cacert]" "$trust"
check $info[timeout] 2000
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
# Bounded path storage uses decoded byte length; configuration never opens files.
typeset seed='' long_path
long_path=${(pl:4096::x:)seed}
zcurl session configure alpha --cacert "$long_path" --proxy-cacert "$long_path"
zcurl session info alpha -r info
check "$info[cacert]" "$long_path"
check "$info[proxy_cacert]" "$long_path"
expect_code 2 zcurl session configure alpha --cacert "${long_path}x"
expect_code 2 zcurl session configure alpha --cacert "$trust" --proxy-cacert "${long_path}x"
zcurl session info alpha -r info
check "$info[cacert]" "$long_path"
zcurl session configure alpha --defaults
zcurl session info alpha -r info
check "$info[cacert]" ''
check "$info[proxy_cacert]" ''
check $info[timeout] 10000
expect_code 60 zcurl --session alpha "$ZCURL_TEST_HTTPS/tiny"
repeat 3; do
    zcurl session configure alpha --cacert "$trust" --proxy-cacert "$trust"
    zcurl session drop alpha
    zcurl session create alpha
    zcurl session info alpha -r info
    check "$info[cacert]" ''
done
zcurl session configure alpha -c "$trust" --proxy-cacert "$trust"
zcurl --reset
zcurl session create alpha
zcurl session info alpha -r info
check "$info[cacert]" ''
zcurl session configure alpha -c "$trust" --proxy-cacert "$trust"
zmodload -u zcurl
check "$copied[cacert]" "$trust"
print 'PASS: session CA defaults, verified TLS, explicit overrides, owned paths, atomic patches and cleanup'
