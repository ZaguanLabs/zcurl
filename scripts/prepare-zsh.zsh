#!/usr/bin/env zsh
# Local headers for this experiment; does not install or replace the shell.
emulate -LR zsh
setopt errexit nounset pipefail
readonly zcurl_root=${0:A:h:h}
readonly zcurl_version=5.9.2
readonly zcurl_sha256=36fa734374b44783582cec09bcd67822e2f992c779ec1624ab5596df078d2f81
readonly zcurl_deps=$zcurl_root/.deps
readonly zcurl_source=$zcurl_deps/zsh-$zcurl_version

if [[ $ZSH_VERSION != $zcurl_version ]]; then
    print -ru2 -- "This experiment targets Zsh $zcurl_version; running $ZSH_VERSION."
    exit 1
fi
mkdir -p -- "$zcurl_deps"
cd -- "$zcurl_deps"
if [[ ! -f $zcurl_source/configure ]]; then
    curl --fail --location --proto '=https' --proto-redir '=https' --max-time 120 \
        "https://www.zsh.org/pub/zsh-$zcurl_version.tar.xz" -o "zsh-$zcurl_version.tar.xz"
    print -r -- "$zcurl_sha256  zsh-$zcurl_version.tar.xz" | sha256sum -c -
    tar -xJf "zsh-$zcurl_version.tar.xz"
fi
cd -- "$zcurl_source"
if [[ ! -f config.status || ! -f Src/Makefile ]]; then
    if ! ./configure --disable-gdbm --disable-pcre > configure-zcurl.log 2>&1; then
        print -ru2 -- "Configure failed; see $zcurl_source/configure-zcurl.log"
        exit 1
    fi
fi
# Always ask make to finish generation: zsh.mdh can exist after an interrupted build.
if ! make -C Src -j4 headers > headers-zcurl.log 2>&1; then
    print -ru2 -- "Header generation failed; see $zcurl_source/headers-zcurl.log"
    exit 1
fi
print -r -- "Prepared Zsh $zcurl_version headers in $zcurl_source"
