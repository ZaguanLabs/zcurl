setopt errexit nounset
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
typeset -A response
typeset empty='' collected=''
typeset payload=${(pl:200000::x:)empty}
zcurl ws open probe -c "$ZCURL_TEST_CA" -- "$ZCURL_TEST_WS_AGAIN"
zcurl ws send probe --type binary --data "$payload"
repeat 100; do
    zcurl ws poll probe -r response --timeout 100
    if [[ $response[event] == data ]]; then
        collected+=$response[body]
        (( response[message_end] )) && break
    fi
done
[[ $collected == $payload ]] || exit 1
# A following frame must have an independent, correctly encoded header.
zcurl ws send probe --data recovered
repeat 100; do
    zcurl ws poll probe -r response --timeout 100
    [[ $response[event] == data ]] && break
done
[[ $response[body] == recovered && $response[message_end] == 1 ]] || exit 2
zcurl ws drop probe
zmodload -u zcurl
