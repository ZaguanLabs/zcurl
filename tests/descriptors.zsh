emulate -LR zsh
setopt errexit nounset pipefail
module_path=( "$ZCURL_MODULE_PATH" $module_path )
zmodload zcurl
zmodload zsh/stat
fail() { print -ru2 -- "FAIL: $* (${zcurl_error_kind-}: ${zcurl_error-})"; exit 1 }
check() { [[ $1 == $2 ]] || fail "$1 != $2" }
typeset -a sockets links
typeset -A response
integer input output private_fd
local candidate handle
local ws_url=${ZCURL_TEST_HTTP/http:/ws:} wss_url=${ZCURL_TEST_HTTPS/https:/wss:}

socket_fds() {
    local candidate
    local -a link
    sockets=()
    links=()
    for candidate in /proc/$$/fd/*(N); do
        zstat -L +link -A link -- "$candidate" 2>/dev/null || continue
        [[ $link[1] == socket:* ]] || continue
        sockets+=( "${candidate:t}" )
        links+=( "$link[1]" )
    done
}
protected_fd() {
    local owned_fd=$1 alias_fd
    (( owned_fd >= 10 )) || fail 'private descriptor overlaps ordinary redirections'
    if { exec {owned_fd}>&-; } 2>/dev/null; then fail 'private descriptor could be closed'; fi
    if { exec {alias_fd}>&$owned_fd; } 2>/dev/null; then fail 'private descriptor could be duplicated'; fi
    [[ -e /proc/$$/fd/$owned_fd ]] || fail 'private descriptor disappeared'
}

# Keep synchronous, cached concurrent and WS sockets alive together. Collected
# easy handles are gone, so closing cached connections also tests callback lifetime.
zcurl -- "$ZCURL_TEST_HTTP/tiny"
zcurl -c "$ZCURL_TEST_CA" -- "$ZCURL_TEST_HTTPS/tiny"
zcurl http submit plain -- "$ZCURL_TEST_HTTP/tiny"
zcurl http wait plain
zcurl http collect plain
zcurl http submit secure -c "$ZCURL_TEST_CA" -- "$ZCURL_TEST_HTTPS/tiny"
zcurl http wait secure
zcurl http collect secure
zcurl ws open plain -- "$ws_url/ws"
zcurl ws open secure -c "$ZCURL_TEST_CA" -- "$wss_url/ws"
socket_fds
check ${#sockets} 6
for private_fd in $sockets; do protected_fd $private_fd; done

# Check the actual descriptor flags in the parent, as well as the absence of
# the parent connection identities after exec in a child process.
python3 -c 'import os,sys
parent=sys.argv[1]
fds=sys.argv[2:]
identities=set()
for fd in fds:
    identities.add(os.readlink(f"/proc/{parent}/fd/{fd}"))
    info=dict(line.split(":",1) for line in open(f"/proc/{parent}/fdinfo/{fd}"))
    assert int(info["flags"].strip(),8) & os.O_CLOEXEC
for fd in os.listdir("/proc/self/fd"):
    try: link=os.readlink("/proc/self/fd/"+fd)
    except FileNotFoundError: continue
    assert link not in identities, "connection inherited across exec"
' $$ "$sockets[@]"

zcurl -- "$ZCURL_TEST_HTTP/tiny"
check $zcurl_new_connections 0
zcurl -c "$ZCURL_TEST_CA" -- "$ZCURL_TEST_HTTPS/tiny"
check $zcurl_new_connections 0
zcurl http submit reused -- "$ZCURL_TEST_HTTP/tiny"
zcurl http wait reused
zcurl http collect reused
check $zcurl_new_connections 0
for handle in plain secure; do
    zcurl ws send "$handle" --data $'still\0connected'
    repeat 50; do
        zcurl ws poll "$handle" --timeout 100
        [[ $zcurl_event == data ]] && break
    done
    check "$zcurl_body" $'still\0connected'
done

# Private file duplicates need the same protection. The originals remain
# caller-owned and closable, and the retained upload/download still succeeds.
print -rn -- $'file\0payload\n\n' > "$ZCURL_TEST_TMP/protected-input.bin"
exec {input}<"$ZCURL_TEST_TMP/protected-input.bin"
exec {output}>"$ZCURL_TEST_TMP/protected-output.bin"
zcurl http submit files --data-fd "$input" --output-fd "$output" -- "$ZCURL_TEST_HTTP/echo"
integer found=0
for candidate in /proc/$$/fd/*(N); do
    [[ $candidate:A == $ZCURL_TEST_TMP/protected-(input|output).bin ]] || continue
    private_fd=${candidate:t}
    (( private_fd == input || private_fd == output )) && continue
    protected_fd $private_fd
    (( ++found ))
done
check $found 2
exec {input}<&-
exec {output}>&-
zcurl http wait files
zcurl http collect files -r response
check $response[bytes] 14
check "$response[body]" ''
zcurl --reset
socket_fds
check ${#sockets} 0

# Drop closes one live connection. Unload must close cache sockets too, and a
# fresh module instance must be able to register and release reused FD numbers.
repeat 3; do
    zcurl -- "$ZCURL_TEST_HTTP/tiny"
    zcurl http submit cached -- "$ZCURL_TEST_HTTP/tiny"
    zcurl http wait cached
    zcurl http collect cached
    zcurl ws open dropped -- "$ws_url/ws"
    zcurl ws drop dropped
    socket_fds
    check ${#sockets} 2
    zmodload -u zcurl
    socket_fds
    check ${#sockets} 0
    zmodload zcurl
done
zmodload -u zcurl

# Caller-owned single-digit descriptors may already occupy the entire range.
# A socket opened above it needs CLOEXEC/registration, with no extra duplicate.
{
    zmodload zcurl
    zcurl -- "$ZCURL_TEST_HTTP/tiny"
    socket_fds
    check ${#sockets} 1
    protected_fd $sockets[1]
    zmodload -u zcurl
    for private_fd in {3..9}; do print -rn -u $private_fd -- caller; done
} 3>/dev/null 4>/dev/null 5>/dev/null 6>/dev/null 7>/dev/null 8>/dev/null 9>/dev/null

print -r -- 'PASS: protected HTTP/HTTPS/WS/WSS sockets and file duplicates, connection reuse, exec isolation and cleanup'
