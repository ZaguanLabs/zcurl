"""Exercise the installed completion through ZLE in an isolated real PTY."""
import os
from pathlib import Path
import pty
import select
import signal
import time


def test(env, plain, temp):
    root = Path(__file__).resolve().parents[1]
    work = temp / "completion"
    work.mkdir()
    (work / "trust bundle[1].pem").write_text("fixture")
    setup = work / "setup.zsh"
    setup.write_text(r'''
        fpath=( "$ZCURL_COMPLETION_ROOT/completions" $fpath )
        autoload -Uz compinit
        compinit -D
        zstyle ':completion:*' completer _complete
        zstyle ':completion:*' menu no
        unsetopt listbeep
        setopt completeinword
        module_path=( "$ZCURL_MODULE_PATH" $module_path )
        zmodload zcurl
        typeset -A zc_hash_valid
        zcurl http submit http_live -- "$ZCURL_TEST_HTTP/tiny" || return
        zcurl ws open ws_live -- "${ZCURL_TEST_HTTP/http:/ws:}/ws" || return
        zcurl session create session_live || return
        zcurl -r zc_hash_valid -- "$ZCURL_TEST_HTTP/tiny" || return
        typeset -Ar zc_hash_locked=(keep value)
        typeset -a zc_array_valid
        typeset -ar zc_array_locked=(keep)
        typeset -aU zc_array_unique=(keep)
        typeset -au zc_array_upper=(keep)
        typeset -a zc_array_ø
        alias zc='noglob zcurl'
        zcurl() { print -r -- invoked >> "$ZCURL_COMPLETION_WORK/calls"; return 99 }
        integer zc_test_round=0 zc_test_check_results=1
        zc_test_complete() {
            zle complete-word
            print -rn -- "$BUFFER" > "$ZCURL_COMPLETION_WORK/buffer"
            if (( zc_test_check_results )); then
                [[ $zcurl_body == $'ok\n' && $zcurl_code == 0 && $zcurl_http_status == 200 ]] ||
                    print -r -- changed >> "$ZCURL_COMPLETION_WORK/calls"
            fi
            BUFFER=''
            CURSOR=0
            zle -I
            print -r -- "COMPLETED:$(( ++zc_test_round ))"
        }
        zle -N zc_test_complete
        bindkey -e
        bindkey '^X^T' zc_test_complete
        print -r -- COMPLETION_READY
    ''')
    before = plain.request_count
    child_env = dict(env, TERM="xterm", PS1="completion> ", ZDOTDIR=str(work),
                     ZCURL_COMPLETION_ROOT=str(root), ZCURL_COMPLETION_WORK=str(work))
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(work)
        os.execvpe("zsh", ["zsh", "-dfi"], child_env)
    output = bytearray()

    def wait_for(marker, timeout=10):
        deadline = time.monotonic() + timeout
        while marker not in output:
            remaining = deadline - time.monotonic()
            assert remaining > 0, f"completion PTY timed out: {bytes(output)!r}"
            if select.select([fd], [], [], remaining)[0]:
                output.extend(os.read(fd, 65536))

    count = 0

    def complete(text, expected, cursor_back=0):
        nonlocal count
        output.clear()
        # Ctrl-B moves the cursor without changing the suffix under completion.
        os.write(fd, text.encode() + b'\x02' * cursor_back + b'\x18\x14')
        count += 1
        wait_for(f"COMPLETED:{count}\r\n".encode())
        actual = (work / "buffer").read_text()
        assert actual == expected, f"completion {text!r}: {actual!r} != {expected!r}\n{bytes(output)!r}"
        assert not (work / "calls").exists(), 'completion invoked zcurl or changed its results'

    try:
        os.write(fd, b'source "$ZCURL_COMPLETION_WORK/setup.zsh"\n')
        wait_for(b'COMPLETION_READY\r\n')
        complete('zcurl he', 'zcurl headers ')
        complete('zcurl ses', 'zcurl session ')
        complete('zcurl session cr', 'zcurl session create ')
        complete('zcurl session jo', 'zcurl session jobs ')
        complete('zcurl session jobs session_l', 'zcurl session jobs session_live ')
        complete('zcurl session jobs session_live --res', 'zcurl session jobs session_live --result ')
        complete('zcurl session jobs session_live -r zc_array_v', 'zcurl session jobs session_live -r zc_array_valid ')
        complete('zcurl session jobs session_live -r zc_hash_v', 'zcurl session jobs session_live -r zc_hash_v')
        complete('zcurl session jobs session_live -r zc_array_u', 'zcurl session jobs session_live -r zc_array_u')
        complete('zcurl session jobs session_live --sta', 'zcurl session jobs session_live --state ')
        complete('zcurl session jobs session_live --state p', 'zcurl session jobs session_live --state pending ')
        complete('zcurl session jobs session_live --state d', 'zcurl session jobs session_live --state done ')
        complete('zcurl session jobs session_live --state c', 'zcurl session jobs session_live --state cancelled ')
        complete('zcurl session jobs session_live --state a', 'zcurl session jobs session_live --state all ')
        complete('zcurl session jobs session_live --state done --sta', 'zcurl session jobs session_live --state done --sta')
        complete('zcurl session jobs session_live -r zc_array_valid --res', 'zcurl session jobs session_live -r zc_array_valid --res')
        complete('zcurl session jobs session_live --ti', 'zcurl session jobs session_live --ti')
        complete('zcurl session in', 'zcurl session info ')
        complete('zcurl session info session_l', 'zcurl session info session_live ')
        complete('zcurl session info session_live --res', 'zcurl session info session_live --result ')
        complete('zcurl session info session_live --result zc_hash_v', 'zcurl session info session_live --result zc_hash_valid ')
        complete('zcurl session info session_live -r zc_hash_l', 'zcurl session info session_live -r zc_hash_l')
        complete('zcurl session info session_live -r zc_array_v', 'zcurl session info session_live -r zc_array_v')
        complete('zcurl session info session_live -r zc_hash_valid --res', 'zcurl session info session_live -r zc_hash_valid --res')
        complete('zcurl session info session_live --def', 'zcurl session info session_live --def')
        complete('zcurl session info session_live --ti', 'zcurl session info session_live --ti')
        complete('zcurl session con', 'zcurl session configure ')
        complete('zcurl session configure session_l', 'zcurl session configure session_live ')
        complete('zcurl session configure session_live --ti', 'zcurl session configure session_live --timeout ')
        complete('zcurl session configure session_live --con', 'zcurl session configure session_live --connect-timeout ')
        complete('zcurl session configure session_live --max', 'zcurl session configure session_live --max-body ')
        complete('zcurl session configure session_live --def', 'zcurl session configure session_live --defaults ')
        complete('zcurl session configure session_live --timeout 100 --ti', 'zcurl session configure session_live --timeout 100 --ti')
        complete('zcurl session configure session_live --timeout 100 --def', 'zcurl session configure session_live --timeout 100 --def')
        complete('zcurl session configure session_live --defaults --ti', 'zcurl session configure session_live --defaults --ti')
        complete('zcurl session configure session_live --uns', 'zcurl session configure session_live --unset ')
        complete('zcurl session configure session_live --unset ti', 'zcurl session configure session_live --unset timeout ')
        complete('zcurl session configure session_live --unset con', 'zcurl session configure session_live --unset connect-timeout ')
        complete('zcurl session configure session_live --unset max', 'zcurl session configure session_live --unset max-body ')
        complete('zcurl session configure session_live --unset cac', 'zcurl session configure session_live --unset cacert ')
        complete('zcurl session configure session_live --unset proxy-c', 'zcurl session configure session_live --unset proxy-cacert ')
        complete('zcurl session configure session_live --unset nopr', 'zcurl session configure session_live --unset noproxy ')
        complete('zcurl session configure session_live --unset timeout --uns', 'zcurl session configure session_live --unset timeout --unset ')
        complete('zcurl session configure session_live --unset timeout --unset ti', 'zcurl session configure session_live --unset timeout --unset ti')
        complete('zcurl session configure session_live -t 50 --unset ti', 'zcurl session configure session_live -t 50 --unset ti')
        complete('zcurl session configure session_live --unset timeout --ti', 'zcurl session configure session_live --unset timeout --ti')
        complete('zcurl session configure session_live --unset cacert -c', 'zcurl session configure session_live --unset cacert -c')
        complete('zcurl session configure session_live --unset proxy -x', 'zcurl session configure session_live --unset proxy -x')
        complete('zcurl session configure session_live --unset proxy --proxy-c', 'zcurl session configure session_live --unset proxy --proxy-cacert ')
        complete('zcurl session configure session_live --unset proxy --def', 'zcurl session configure session_live --unset proxy --def')
        complete('zcurl session configure session_live --defaults --uns', 'zcurl session configure session_live --defaults --uns')
        complete('zcurl session configure session_live --proxy --unset --unset nopr', 'zcurl session configure session_live --proxy --unset --unset noproxy ')
        complete('zcurl session create fresh --uns', 'zcurl session create fresh --uns')
        complete('zcurl --uns', 'zcurl --uns')
        complete('zcurl session configure session_live --res', 'zcurl session configure session_live --res')
        complete('zcurl session configure session_live --proxy-c', 'zcurl session configure session_live --proxy-cacert ')
        complete('zcurl session configure session_live --nopr', 'zcurl session configure session_live --noproxy ')
        complete('zcurl session configure session_live -x htt', 'zcurl session configure session_live -x http')
        complete('zcurl session configure session_live --proxy socks5h', 'zcurl session configure session_live --proxy socks5h://')
        complete('zcurl session configure session_live --proxy value -x', 'zcurl session configure session_live --proxy value -x')
        complete('zcurl session configure session_live --proxy value --def', 'zcurl session configure session_live --proxy value --def')
        complete('zcurl session configure session_live --noproxy value --nopr', 'zcurl session configure session_live --noproxy value --nopr')
        complete('zcurl session configure session_live --defaults --nopr', 'zcurl session configure session_live --defaults --nopr')
        complete('zcurl session configure session_live --defaults -x', 'zcurl session configure session_live --defaults -x')
        complete('zcurl session configure session_live --cac', 'zcurl session configure session_live --cacert ')
        complete('zcurl session configure session_live --cacert trust', r'zcurl session configure session_live --cacert trust\ bundle\[1\].pem ')
        complete('zcurl session configure session_live --proxy-cacert trust', r'zcurl session configure session_live --proxy-cacert trust\ bundle\[1\].pem ')
        complete('zcurl session configure session_live -c file --cac', 'zcurl session configure session_live -c file --cac')
        complete('zcurl session configure session_live --cacert file --def', 'zcurl session configure session_live --cacert file --def')
        complete('zcurl session configure session_live --defaults --cac', 'zcurl session configure session_live --defaults --cac')
        complete('zcurl session configure session_live --proxy-cacert file --proxy-c', 'zcurl session configure session_live --proxy-cacert file --proxy-c')

        complete('zcurl session configure session_live --timeout 100 --max', 'zcurl session configure session_live --timeout 100 --max-body ')
        complete('zcurl session configure session_live -t 100 --ti', 'zcurl session configure session_live -t 100 --ti')
        complete('zcurl session create session_l', 'zcurl session create session_l')
        complete('zcurl session create fresh --fr', 'zcurl session create fresh --from ')
        complete('zcurl session create fresh --from session_l', 'zcurl session create fresh --from session_live ')
        complete('zcurl session create fresh --from session_live --fr', 'zcurl session create fresh --from session_live --fr')
        complete('zcurl session create fresh --ti', 'zcurl session create fresh --ti')
        complete('zcurl session reset session_live --fr', 'zcurl session reset session_live --fr')
        complete('zcurl session drop session_l', 'zcurl session drop session_live ')
        complete('zcurl session reset session_l', 'zcurl session reset session_live ')
        complete('zcurl session drop session_live --res', 'zcurl session drop session_live --res')
        complete('zcurl --ses', 'zcurl --session ')
        complete('zcurl --session session_l', 'zcurl --session session_live ')
        complete('zcurl --session session_live --ses', 'zcurl --session session_live --ses')
        complete('zcurl http submit job --ses', 'zcurl http submit job --session ')
        complete('zcurl http submit job --session session_l', 'zcurl http submit job --session session_live ')
        complete('zcurl http submit job --session session_live --ses', 'zcurl http submit job --session session_live --ses')
        complete('zcurl http wait job --ses', 'zcurl http wait job --ses')
        complete('zcurl ws open channel --ses', 'zcurl ws open channel --ses')
        complete('zcurl http su', 'zcurl http submit ')
        complete('zcurl ws re', 'zcurl ws recv ')
        complete('zcurl ws open channel --sub', 'zcurl ws open channel --subprotocol ')
        complete('zcurl ws open channel --subprotocol fixture.v1 --sub', 'zcurl ws open channel --subprotocol fixture.v1 --sub')
        complete('zcurl ws open channel --subprotocol fi', 'zcurl ws open channel --subprotocol fi')
        complete('zcurl ws send channel --sub', 'zcurl ws send channel --sub')
        complete('zcurl --sub', 'zcurl --sub')
        complete('zcurl http submit job --sub', 'zcurl http submit job --sub')
        complete('zcurl --data-f', 'zcurl --data-fd ')
        complete('zcurl --comp', 'zcurl --compressed ')
        complete('zcurl --pro', 'zcurl --proxy')
        complete('zcurl http submit job --pro', 'zcurl http submit job --proxy')
        complete('zcurl --nopro', 'zcurl --noproxy ')
        complete('zcurl -x http:', 'zcurl -x http://')
        complete('zcurl --proxy socks5h:', 'zcurl --proxy socks5h://')
        complete('zcurl -x http://example.invalid --pro', 'zcurl -x http://example.invalid --proxy-cacert ')
        complete('zcurl --noproxy localhost --nopro', 'zcurl --noproxy localhost --nopro')
        complete('zcurl ws open channel --pro', 'zcurl ws open channel --proxy')
        complete('zcurl ws open channel --nopro', 'zcurl ws open channel --noproxy ')
        complete('zcurl ws open channel -x http:', 'zcurl ws open channel -x http://')
        complete('zcurl ws open channel --proxy socks5h:', 'zcurl ws open channel --proxy socks5h://')
        complete('zcurl ws open channel -x http://example.invalid --pro', 'zcurl ws open channel -x http://example.invalid --proxy-cacert ')
        complete('zcurl ws open channel --noproxy localhost --nopro', 'zcurl ws open channel --noproxy localhost --nopro')
        complete('zcurl ws send channel --pro', 'zcurl ws send channel --pro')
        complete('zcurl ws poll channel --nopro', 'zcurl ws poll channel --nopro')
        complete('zcurl http wait job --pro', 'zcurl http wait job --pro')
        complete('zcurl --proxy=http:', 'zcurl --proxy=http:')
        complete('zcurl http submit job --comp', 'zcurl http submit job --compressed ')
        complete('zcurl --compressed --comp', 'zcurl --compressed --comp')
        complete('zcurl http wait job --comp', 'zcurl http wait job --comp')
        complete('zcurl ws open channel --comp', 'zcurl ws open channel --comp')
        complete('zcurl --ver', 'zcurl --version ')
        complete('zcurl --version --out', 'zcurl --version --out')
        complete('zcurl https://example.invalid --rese', 'zcurl https://example.invalid --rese')
        complete('zcurl -X PA', 'zcurl -X PATCH ')
        complete('zcurl --head -X H', 'zcurl --head -X HEAD ')
        complete('zcurl --head -X P', 'zcurl --head -X P')
        complete('zcurl --data value -X H', 'zcurl --data value -X H')
        complete('zcurl --data value --data-f', 'zcurl --data value --data-f')
        complete('zcurl --head --data-f', 'zcurl --head --data-f')
        complete('zcurl --data-fd 10 --he', 'zcurl --data-fd 10 --header ')
        complete('zcurl https://example.invalid --output-f', 'zcurl https://example.invalid --output-fd ')
        complete('zcurl -- --out', 'zcurl -- --out')
        complete('zcurl http submit job --data-f', 'zcurl http submit job --data-fd ')
        complete('zcurl http submit --ti', 'zcurl http submit --ti')
        for operation in ('wait', 'collect', 'cancel', 'drop', 'info'):
            complete(f'zcurl http {operation} http_l', f'zcurl http {operation} http_live ')
        for operation in ('send', 'recv', 'poll', 'close', 'drop', 'info'):
            complete(f'zcurl ws {operation} ws_l', f'zcurl ws {operation} ws_live ')
        complete('zcurl http submit http_l', 'zcurl http submit http_l')
        complete('zcurl ws open ws_l', 'zcurl ws open ws_l')
        complete('zcurl http info ws_l', 'zcurl http info ws_l')
        complete('zcurl ws info http_l', 'zcurl ws info http_l')
        complete('zcurl http wait job --ti', 'zcurl http wait job --timeout ')
        complete('zcurl http wait-a', 'zcurl http wait-any ')
        complete('zcurl http wait-any http_l', 'zcurl http wait-any http_live ')
        complete('zcurl http wait-any job http_l', 'zcurl http wait-any job http_live ')
        complete('zcurl http wait-any --ti', 'zcurl http wait-any --timeout ')
        complete('zcurl http wait-any job --ti', 'zcurl http wait-any job --timeout ')
        complete('zcurl http wait-any -t 0 http_l', 'zcurl http wait-any -t 0 http_live ')
        complete('zcurl http wait-any -- http_l', 'zcurl http wait-any -- http_live ')
        complete('zcurl http wait-any -r zc_hash_v', 'zcurl http wait-any -r zc_hash_valid ')
        complete('zcurl http wait-any ws_l', 'zcurl http wait-any ws_l')
        complete('zcurl http collect job --ti', 'zcurl http collect job --ti')
        complete('zcurl http poll --ti', 'zcurl http poll --timeout ')
        complete('zcurl http nonsense --ti', 'zcurl http nonsense --ti')
        complete('zcurl ws open channel --max-q', 'zcurl ws open channel --max-queue ')
        complete('zcurl ws send channel --type b', 'zcurl ws send channel --type binary ')
        complete('zcurl ws recv channel --max-c', 'zcurl ws recv channel --max-chunk ')
        complete('zcurl ws recv channel --ti', 'zcurl ws recv channel --ti')
        complete('zcurl ws close channel --rea', 'zcurl ws close channel --reason ')
        complete('zcurl headers Set-C', 'zcurl headers Set-Cookie ')
        complete('zcurl headers ETag --tra', 'zcurl headers ETag --trailers ')
        complete('zcurl -r zc_hash_v', 'zcurl -r zc_hash_valid ')
        complete('zcurl -r zc_hash_l', 'zcurl -r zc_hash_l')
        complete('zcurl -r zc_array_v', 'zcurl -r zc_array_v')
        complete('zcurl headers ETag -r zc_array_v', 'zcurl headers ETag -r zc_array_valid ')
        complete('zcurl headers ETag -r zc_array_un', 'zcurl headers ETag -r zc_array_un')
        complete('zcurl headers ETag -r zc_array_up', 'zcurl headers ETag -r zc_array_up')
        complete('zcurl headers ETag -r zc_array_l', 'zcurl headers ETag -r zc_array_l')
        complete('zcurl headers ETag -r path', 'zcurl headers ETag -r path')
        complete('zcurl headers ETag -r zc_array_ø', 'zcurl headers ETag -r zc_array_ø')
        complete('zcurl -c tru', r'zcurl -c trust\ bundle\[1\].pem ')
        complete('zcurl --proxy-c', 'zcurl --proxy-cacert ')
        complete('zcurl --proxy-cacert tru', r'zcurl --proxy-cacert trust\ bundle\[1\].pem ')
        complete('zcurl http submit job --proxy-cacert tru', r'zcurl http submit job --proxy-cacert trust\ bundle\[1\].pem ')
        complete('zcurl ws open channel --proxy-cacert tru', r'zcurl ws open channel --proxy-cacert trust\ bundle\[1\].pem ')
        complete('zcurl --proxy-cacert file --proxy-c', 'zcurl --proxy-cacert file --proxy-c')
        complete('zcurl http wait job --proxy-c', 'zcurl http wait job --proxy-c')
        complete('zcurl ws send channel --proxy-c', 'zcurl ws send channel --proxy-c')
        complete('zcurl http submit job -c tru', r'zcurl http submit job -c trust\ bundle\[1\].pem ')
        complete('zcurl ws open channel -c tru', r'zcurl ws open channel -c trust\ bundle\[1\].pem ')
        complete('zcurl -X PTCH', 'zcurl -X PATCH ', cursor_back=3)
        complete('zcurl http submit job https:', 'zcurl http submit job https://')
        complete('zcurl ws open channel wss:', 'zcurl ws open channel wss://')
        complete('zcurl http submit job ftp:', 'zcurl http submit job ftp:')
        complete('zc --max-b', 'zc --max-body ')
        complete('zcurl --header X:one --heade', 'zcurl --header X:one --header ')
        complete('zcurl --request=PA', 'zcurl --request=PA')
        complete('zcurl -XPA', 'zcurl -XPA')
        output.clear()
        os.write(fd, b"zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'; print -r -- MATCHER_READY\n")
        wait_for(b'MATCHER_READY\r\n')
        complete('zcurl -X pat', 'zcurl -X PATCH ')
        output.clear()
        os.write(fd, b'zmodload -F zcurl -p:zcurl_http_handles -p:zcurl_http_sessions; print -r -- DISABLED_READY\n')
        wait_for(b'DISABLED_READY\r\n')
        complete('zcurl session create fresh --from session_l', 'zcurl session create fresh --from session_l')
        complete('zcurl --session session_l', 'zcurl --session session_l')
        complete('zcurl http submit job --session session_l', 'zcurl http submit job --session session_l')
        complete('zcurl http info http_l', 'zcurl http info http_l')
        complete('zcurl http wait-any http_l', 'zcurl http wait-any http_l')
        output.clear()
        os.write(fd, b'zmodload -F zcurl +p:zcurl_http_handles +p:zcurl_http_sessions; print -r -- ENABLED_READY\n')
        wait_for(b'ENABLED_READY\r\n')
        complete('zcurl --session session_l', 'zcurl --session session_live ')
        complete('zcurl http info http_l', 'zcurl http info http_live ')
        output.clear()
        os.write(fd, b'zc_test_check_results=0; builtin zcurl http drop http_live; builtin zcurl ws drop ws_live; builtin zcurl session drop session_live; print -r -- DROPPED_READY\n')
        wait_for(b'DROPPED_READY\r\n')
        complete('zcurl session drop session_l', 'zcurl session drop session_l')
        complete('zcurl http info http_l', 'zcurl http info http_l')
        complete('zcurl ws info ws_l', 'zcurl ws info ws_l')
        output.clear()
        os.write(fd, b'zc_test_check_results=0; zmodload -u zcurl; unfunction zcurl; print -r -- UNLOADED_READY\n')
        wait_for(b'UNLOADED_READY\r\n')
        complete('zcurl --session session_l', 'zcurl --session session_l')
        complete('zcurl http submit job --session session_l', 'zcurl http submit job --session session_l')
        complete('zcurl http wait-any http_l', 'zcurl http wait-any http_l')
        complete('zcurl ws send channel --type b', 'zcurl ws send channel --type binary ')
        complete('zcurl http info http_l', 'zcurl http info http_l')
        complete('zcurl ws info ws_l', 'zcurl ws info ws_l')
        assert plain.request_count == before + 2, 'completion caused HTTP I/O'
        print(f'PASS: {count} real ZLE completions, operation grammar, quoting, array types and unchanged HTTP state')
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
        os.close(fd)
