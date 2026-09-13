#!/usr/bin/env zsh
# Execute in a fresh shell: no network requests or startup-file changes.
emulate -LR zsh
setopt errexit nounset
typeset zcurl_check_root=${0:A:h:h}
source "$zcurl_check_root/zcurl.zsh"
zcurl --version
typeset -A zcurl_check_result
zcurl session create deployment_check
zcurl session info deployment_check -r zcurl_check_result
zcurl session drop deployment_check
zcurl poll -r zcurl_check_result
[[ $zcurl_check_result[event] == idle && -z $zcurl_check_result[channel] ]]
zmodload -u zcurl
source "$zcurl_check_root/zcurl.zsh"
zmodload -u zcurl
print -r -- 'PASS: module load, parameters, session lifecycle, shared poll and reload'
