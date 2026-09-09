#!/usr/bin/env zsh
# Usage: zsh examples/concurrent.zsh URL [URL ...] (up to eight requests)
emulate -LR zsh
setopt nounset pipefail
source "${0:A:h:h}/zcurl.zsh" || exit
if (( $# < 1 || $# > 8 )); then
    print -ru2 -- "usage: $0 URL [URL ...] (1..8 URLs)"
    exit 2
fi

fetch_batch() {
    emulate -L zsh
    local -A pending event response
    local url handle
    integer next=0 failed=0
    {
        for url in "$@"; do
            handle=request_$(( ++next ))
            if ! zcurl http submit "$handle" --fail -- "$url"; then
                print -ru2 -- "Submission failed: ${(V)zcurl_error}"
                return 1
            fi
            pending[$handle]=1
        done
        while (( ${#pending} )); do
            zcurl http poll -r event --timeout 100 || return
            [[ $event[event] == ready ]] || continue
            handle=$event[handle]
            if zcurl http collect "$handle" -r response; then
                print -r -- "$handle: HTTP $response[http_status], $response[bytes] bytes"
                # Consume response[body] here, as data; it preserves NUL bytes.
            else
                failed=1
                print -ru2 -- "$handle: ${(V)response[error]}"
            fi
            unset "pending[$handle]"
        done
        return $failed
    } always {
        for handle in "${(@k)pending}"; do
            zcurl http drop "$handle"
        done
    }
}
fetch_batch "$@"
