#!/usr/bin/env zsh
# Parser-only benchmark. No request reaches libcurl's transfer API.
# Optional argument: directory containing a compatible zcurl.so to compare.
emulate -LR zsh
setopt nounset pipefail
if (( $# > 1 )); then
    print -ru2 -- "usage: $0 [MODULE_DIRECTORY]"
    exit 2
fi
module_path=( "${1:-${0:A:h:h}/build}" $module_path )
zmodload zcurl || exit
zmodload zsh/datetime || exit
typeset -a fields=(-H 'a:')
integer count result
float start elapsed fastest slowest total
repeat 12; do fields=( "${fields[@]}" "${fields[@]}" ); done
print 'headers median_seconds min_seconds max_seconds'
for count in 4096 8192 16384 32768 65536; do
    fastest=1e9 slowest=0 total=0
    repeat 3; do
        start=$EPOCHREALTIME
        result=0
        zcurl "${fields[@]}" --result zcurl_benchmark_missing 2>/dev/null || result=$?
        elapsed=$(( EPOCHREALTIME - start ))
        if (( result != 2 )) || [[ $zcurl_error != '--result requires'* ]]; then
            print -ru2 -- "unexpected parser result: $result ${(V)zcurl_error}"
            exit 1
        fi
        (( total += elapsed ))
        (( elapsed < fastest )) && fastest=$elapsed
        (( elapsed > slowest )) && slowest=$elapsed
    done
    printf '%d %.6f %.6f %.6f\n' $count $((total - fastest - slowest)) $fastest $slowest
    (( count == 65536 )) || fields=( "${fields[@]}" "${fields[@]}" )
done
