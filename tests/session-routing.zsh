# Invoked inside the loopback proxy fixture with NO_PROXY='*'.
expect_code() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    check "$actual" "$expected"
}
typeset -A info saved
zcurl session create routed
zcurl session create direct
zcurl session info routed -r info
check ${#info} 11
check $info[proxy_set] 0
check $info[noproxy_set] 0
check "$info[proxy]" ''
check "$info[noproxy]" ''
() {
    local route=$ZCURL_TEST_PROXY bypass=''
    zcurl session configure routed -x "$route" --noproxy "$bypass"
}
zcurl session configure direct --proxy '' --noproxy ''
zcurl session info routed -r info
check "$info[proxy]" "$ZCURL_TEST_PROXY"
check $info[proxy_set] 1
check $info[noproxy_set] 1
check "$info[noproxy]" ''
zcurl --session routed "$ZCURL_TEST_HTTP/tiny" # proxied 1
zcurl --session direct "$ZCURL_TEST_HTTP/tiny"
zcurl "$ZCURL_TEST_HTTP/tiny"
# Request overrides win in both positions and do not change defaults.
zcurl --proxy '' --session routed "$ZCURL_TEST_HTTP/tiny"
zcurl --session routed --proxy '' "$ZCURL_TEST_HTTP/tiny"
zcurl --noproxy '*' --session routed "$ZCURL_TEST_HTTP/tiny"
zcurl --session routed --noproxy '*' "$ZCURL_TEST_HTTP/tiny"
zcurl session create copied --from routed
zcurl http submit retained --session routed "$ZCURL_TEST_HTTP/tiny"
zcurl session configure routed --proxy '' --noproxy '*'
zcurl http wait retained
zcurl http collect retained # proxied 2, submission retained both strings
check "$zcurl_body" $'ok\n'
zcurl session drop routed
zcurl --session copied "$ZCURL_TEST_HTTP/tiny" # proxied 3
zcurl http submit copied_job --session copied "$ZCURL_TEST_HTTP/tiny"
zcurl http wait copied_job
zcurl http collect copied_job # proxied 4
zcurl session reset copied
zcurl --session copied "$ZCURL_TEST_HTTP/tiny" # proxied 5
# Explicit session defaults survive changes to the exported environment.
export http_proxy=''
zcurl --session copied "$ZCURL_TEST_HTTP/tiny" # proxied 6
zcurl session configure copied --defaults
zcurl session info copied -r info
check $info[proxy_set] 0
check $info[noproxy_set] 0
zcurl --session copied "$ZCURL_TEST_HTTP/tiny"
export http_proxy=$ZCURL_TEST_PROXY
# Either setting can independently inherit the other from the environment.
zcurl session configure copied --noproxy ''
zcurl --session copied "$ZCURL_TEST_HTTP/tiny" # proxied 7
zcurl session configure copied --defaults
zcurl session configure copied --proxy "$ZCURL_TEST_PROXY"
zcurl --session copied "$ZCURL_TEST_HTTP/tiny" # environment bypass remains active
zcurl --noproxy '' --session copied "$ZCURL_TEST_HTTP/tiny" # proxied 8
zcurl --session copied --noproxy '' "$ZCURL_TEST_HTTP/tiny" # proxied 9
# Copying an explicit empty proxy must not turn it into environment inheritance.
zcurl session create direct_copy --from direct
zcurl session configure direct --defaults
zcurl session drop direct
export NO_PROXY=''
zcurl --session direct_copy "$ZCURL_TEST_HTTP/tiny"
zcurl session info direct_copy -r info
check $info[proxy_set] 1
check $info[noproxy_set] 1
check "$info[proxy]" ''
check "$info[noproxy]" ''
# Every rejected patch is atomic and preserves prior transfer errors.
expect_code 2 zcurl --session missing -r response "$ZCURL_TEST_HTTP/tiny"
saved=( "${(@kv)response}" )
zcurl session configure copied --timeout 4321 --proxy "$ZCURL_TEST_PROXY" --noproxy '*'
for flag in --proxy --noproxy; do
    expect_code 2 zcurl session configure copied "$flag"
    expect_code 2 zcurl session configure copied "$flag" $'bad\0tail'
    expect_code 2 zcurl session configure copied "$flag" changed "$flag" duplicate
    expect_code 2 zcurl session configure copied "$flag" changed --timeout 0
    expect_code 2 zcurl session configure copied "$flag" changed --defaults
    expect_code 2 zcurl session configure copied --defaults "$flag" changed
done
expect_code 2 zcurl session configure copied -x changed --proxy duplicate
expect_code 2 zcurl session configure copied --timeout 50 --proxy changed --noproxy changed --cacert $'bad\0tail'
zcurl session info copied -r info
check $info[timeout] 4321
check "$info[proxy]" "$ZCURL_TEST_PROXY"
check "$info[noproxy]" '*'
for key in ${(k)saved}; do check "${(P)${:-zcurl_$key}}" "$saved[$key]"; done
# Stored text is bounded by decoded byte length; syntax interpretation is deferred.
typeset seed='' longest
longest=${(pl:4096::x:)seed}
zcurl session configure copied --proxy "$longest" --noproxy "$longest"
expect_code 2 zcurl session configure copied --proxy "${longest}x"
expect_code 2 zcurl session configure copied --proxy short --noproxy "${longest}x"
zcurl session info copied -r info
check "$info[proxy]" "$longest"
check "$info[noproxy]" "$longest"
zcurl session configure copied --proxy $'http://user:secret@ø\nhost' --noproxy $'ø\nhost'
zcurl session info copied -r info
check "$info[proxy]" $'http://user:secret@ø\nhost'
check "$info[noproxy]" $'ø\nhost'
repeat 3; do
    zcurl session create owned --from copied
    zcurl session drop owned
done
zcurl session create owned --from copied
zcurl session drop copied
zcurl --reset
zcurl session create fresh
zcurl session info fresh -r info
check $info[proxy_set] 0
check $info[noproxy_set] 0
zcurl session configure fresh --proxy '' --noproxy ''
zcurl session create unload_copy --from fresh
zmodload -u zcurl
check $info[proxy_set] 0
