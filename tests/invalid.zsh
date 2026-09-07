emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
fail() { print -ru2 -- "FAIL: $*"; exit 1 }
reject() {
    local rc=0
    zcurl "$@" "$ZCURL_TEST_HTTP/tiny" || rc=$?
    (( rc == 2 && zcurl_status == 2 && zcurl_code == -1 )) || fail 'argument accepted'
}
typeset scalar=unchanged
typeset -A ordinary=(keep original)
typeset -Ar locked=(keep original)
typeset -Au uppercase
reject --result scalar
reject --result missing_array
reject --result locked
reject --result uppercase
reject --result 'ordinary[$(touch SHOULD_NOT_EXIST)]'
zmodload zsh/parameter
reject --result functions
reject --result commands
reject --result parameters
[[ $scalar == unchanged && $ordinary[keep] == original && $locked[keep] == original ]] || fail 'invalid result modified'
reject -H $'X-Test: ok\r\nInjected: yes'
reject -H $'X-Test: bad\0tail'
reject -H $'Bad Name: invalid'
reject -H 'No-Colon'
reject -X $'GET\r\nInjected: yes'
reject -X 'GET /other'
reject -I -d body
reject -I -X GET
reject -d one -d two
reject -c ''
reject --timeout 0
reject --timeout 600001
reject --timeout '1+1'
reject --timeout 9999999999999999999999999999
reject --connect-timeout -1
reject --max-body 0
reject --max-body 67108865
reject --max-body 1.5
reject --timeout=100
reject -fI
reject --version
reject --reset
reject --data
print -r -- 'PASS: invalid API inputs rejected without parameter evaluation'
