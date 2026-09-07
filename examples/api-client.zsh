#!/usr/bin/env zsh
# Usage: zsh examples/api-client.zsh https://your-service.example/resource
emulate -LR zsh
setopt nounset pipefail
source "${0:A:h:h}/zcurl.zsh" || exit
if (( $# != 1 )); then
    print -ru2 -- "usage: $0 URL"
    exit 2
fi

# A helper writes through dynamic scope into the caller's declared result.
fetch_json() {
    emulate -L zsh
    zcurl --result "$1" --fail --header 'Accept: application/json' -- "$2"
}

typeset -A response
integer request_status=0
fetch_json response "$1" || request_status=$?
if (( request_status )); then
    print -ru2 -- "Request failed ($request_status, ${response[error_kind]}): ${(V)response[error]}"
    exit $request_status
fi

# Feed exact bytes to a parser/file through stdout; no command substitution.
print -rn -- "$response[body]"
