# Source this file from a project to load the locally built module.
() {
    builtin emulate -L zsh
    builtin zmodload -e zcurl && return 0
    builtin typeset zcurl_loader_root=${${(%):-%x}:A:h}
    if [[ ! -r $zcurl_loader_root/build/zcurl.so ]]; then
        builtin print -ru2 -- "zcurl: module missing; run make in $zcurl_loader_root"
        return 1
    fi
    builtin typeset -a zcurl_loader_paths
    zcurl_loader_paths=( "$zcurl_loader_root/build" "${module_path[@]}" )
    builtin typeset -a module_path
    module_path=( "${zcurl_loader_paths[@]}" )
    builtin zmodload zcurl
}
