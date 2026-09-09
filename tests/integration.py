#!/usr/bin/env python3
"""Local HTTP/TLS experiments; no public endpoints or system trust changes."""
import argparse
import contextlib
import http.server
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import ssl
import statistics
import subprocess
import tempfile
import threading
import time
import websocket_fixture

ROOT = Path(__file__).resolve().parents[1]


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    connections = 0

    def __init__(self, *args):
        super().__init__(*args)
        self.slow_started = threading.Event()
        self.request_count = 0
        self.request_lock = threading.Lock()
        self.ws_frames = []
        self.ws_errors = []
        self.ws_release = threading.Event()
        self.http_release = threading.Event()
        self.http_barrier = threading.Barrier(2)

    def handle_error(self, request, client_address):
        import traceback
        self.ws_errors.append(traceback.format_exc())
        super().handle_error(request, client_address)

    def get_request(self):
        sock, address = super().get_request()
        self.connections += 1
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return sock, address


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            # Expected when a transfer is cancelled or TLS verification fails.
            pass

    def log_message(self, *args):
        pass

    def do_GET(self):
        with self.server.request_lock:
            self.server.request_count += 1
        if self.path.startswith('/ws'):
            websocket_fixture.serve(self)
            return
        request_body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/release-ws":
            self.server.ws_release.set()
        if self.path == "/release-http":
            self.server.http_release.set()
        if self.path.startswith("/parallel/"):
            # Neither response can finish until both requests arrive.
            self.server.http_barrier.wait(timeout=5)
        if self.path == "/held":
            self.send_response(200)
            self.send_header("Content-Length", "10")
            self.end_headers()
            self.wfile.write(b"part")
            self.server.slow_started.set()
            assert self.server.http_release.wait(10), "held HTTP request was never released"
            self.wfile.write(b"-final")
            return
        if self.path == "/slow":
            self.server.slow_started.set()
            time.sleep(0.5)
        if self.path == "/hang":
            self.server.slow_started.set()
            time.sleep(5)
        data = b"ok\n"
        response_type = "application/octet-stream"
        if self.path == "/bytes":
            data = bytes(range(256)) + b"\n\n"
        elif self.path.startswith("/parallel/"):
            data = self.path.encode()
        elif self.path == "/large":
            data = b"x" * (8 * 1024 * 1024 + 1)
        elif self.path == "/echo":
            data = request_body
        elif self.path == "/inspect":
            data = json.dumps({"method": self.command, "body": request_body.hex(),
                               "headers": list(self.headers.items())}).encode()
            response_type = "application/json"
        elif self.path == "/empty":
            data = b""
        status = 404 if self.path == "/missing" else 302 if self.path == "/redirect" else 200
        if self.path == "/empty":
            status = 204
        try:
            if self.path == "/interim":
                self.wfile.write(b"HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n")
            self.send_response(status)
            if self.path == "/chunked":
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", str(len(data) + (5 if self.path == "/truncated" else 0)))
            self.send_header("Content-Type", response_type)
            self.send_header("X-Request-Method", self.command)
            if self.headers.get("X-Owned"):
                self.send_header("X-Observed-Owned", self.headers["X-Owned"])
            if self.path == "/headers":
                self.send_header("Set-Cookie", "one=1")
                self.send_header("Set-Cookie", "two=2")
            if self.path == "/large-headers":
                for _ in range(280):
                    self.send_header("X-Padding", "x" * 1000)
            if status == 302:
                self.send_header("Location", "/tiny")
            self.end_headers()
            if self.command != "HEAD":
                if self.path == "/chunked":
                    self.wfile.write(b"3\r\na\x00b\r\n2\r\n\n\n\r\n0\r\nX-Trailer: yes\r\n\r\n")
                else:
                    self.wfile.write(data)
            if self.path == "/truncated":
                self.close_connection = True
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_GET


@contextlib.contextmanager
def fixture():
    with tempfile.TemporaryDirectory(prefix="zcurl-test-ø-") as temp:
        temp = Path(temp)
        cert, key = temp / "local-ca.pem", temp / "local-key.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key), "-out", str(cert), "-days", "1",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-addext", "basicConstraints=critical,CA:TRUE",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        plain = Server(("127.0.0.1", 0), Handler)
        tls = Server(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        tls.socket = context.wrap_socket(tls.socket, server_side=True)
        threads = []
        for server in (plain, tls):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            threads.append(thread)
        env = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}
        env.update(NO_PROXY="*", ZCURL_MODULE_PATH=str(ROOT / "build"),
                   ZCURL_TEST_CA=str(cert), ZCURL_TEST_TMP=str(temp),
                   ZCURL_TEST_HTTP=f"http://127.0.0.1:{plain.server_port}",
                   ZCURL_TEST_HTTPS=f"https://localhost:{tls.server_port}",
                   ZCURL_TEST_MISMATCH=f"https://127.0.0.1:{tls.server_port}")
        try:
            yield env, plain, tls, temp
        finally:
            for server, thread in zip((plain, tls), threads):
                server.shutdown()
                server.server_close()
                thread.join()


def run(env, source):
    command = ["zsh", "-dfc", source]
    if env.get("ZCURL_TEST_VALGRIND") == "1":
        command = ["valgrind", "--quiet", "--keep-debuginfo=yes", "--error-exitcode=99", "--leak-check=full",
                   "--show-leak-kinds=definite", "--errors-for-leak-kinds=definite",
                   f"--suppressions={ROOT / 'tests' / 'valgrind-libcurl.supp'}"] + command
    result = subprocess.run(command, env=env, capture_output=True, timeout=60 if env.get("ZCURL_TEST_VALGRIND") else 30)
    if result.returncode:
        raise AssertionError(f"zsh exited {result.returncode}\n{result.stdout!r}\n{result.stderr!r}")
    return result.stdout.decode().strip()


LOAD = 'module_path=( "$ZCURL_MODULE_PATH" $module_path ); zmodload zcurl || exit 90\n'


def integration(env, plain, tls, temp):
    source = (ROOT / "tests" / "smoke.zsh").read_text()
    print(run(env, source))
    expected = bytes(range(256)) + b"\n\n"
    assert (temp / "response.bin").read_bytes() == expected, "binary response changed"
    # Confirm a warmed session really makes only one TLS connection server-side.
    before = tls.connections
    result = run(env, LOAD + '''
        zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny" || exit 1
        print -r -- $zcurl_new_connections
        repeat 10; do
            zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny" || exit 1
            (( zcurl_new_connections == 0 )) || exit 2
        done
        zmodload -u zcurl || exit 3
    ''')
    assert result == "1" and tls.connections - before == 1, "TLS connection not reused"
    print("PASS: all 256 byte values and trailing newlines round-trip exactly")
    print("PASS: 11 verified HTTPS requests use one server-observed connection")


def api_test(env, plain, temp):
    print(run(env, (ROOT / "tests" / "api.zsh").read_text()))
    posted = json.loads((temp / "post.json").read_bytes())
    assert posted["method"] == "POST"
    assert bytes.fromhex(posted["body"]) == b'{"message":"hello"}\n'
    headers = posted["headers"]
    assert [v for k, v in headers if k.lower() == "x-tag"] == ["one", "two"]
    assert [v for k, v in headers if k.lower() == "authorization"] == ["Bearer fixture-token"]
    assert [v for k, v in headers if k.lower() == "content-type"] == ["application/json"]
    following = json.loads((temp / "following.json").read_bytes())
    assert following["method"] == "GET" and following["body"] == ""
    assert not any(k.lower() in ("x-tag", "authorization", "content-type") for k, _ in following["headers"])
    assert (temp / "echo.bin").read_bytes() == bytes(range(256)) + b"\n\n"
    print("PASS: server-observed POST, JSON/auth/duplicate headers, request reset, binary upload")
    before = plain.request_count
    print(run(env, (ROOT / "tests" / "invalid.zsh").read_text()))
    assert plain.request_count == before, "invalid arguments caused a network request"
    print("PASS: invalid result targets, headers, methods and options cause no HTTP requests")


def loader_test(env):
    env = dict(env, ZCURL_TEST_ROOT=str(ROOT))
    print(run(env, '''
        setopt errexit nounset
        typeset -a original_path=( "${module_path[@]}" )
        alias zmodload=false emulate=false
        source "$ZCURL_TEST_ROOT/zcurl.zsh"
        [[ "${(j.:.)module_path}" == "${(j.:.)original_path}" ]] || exit 1
        zcurl "$ZCURL_TEST_HTTP/tiny"
        source "$ZCURL_TEST_ROOT/zcurl.zsh"
        [[ $zcurl_body == $'ok\\n' ]] || exit 2
        zcurl "$ZCURL_TEST_HTTP/tiny"
        (( zcurl_new_connections == 0 )) || exit 3
        [[ $aliases[zmodload] == false && $aliases[emulate] == false ]] || exit 4
        builtin zmodload -u zcurl
        print -r -- 'PASS: project loader is idempotent and preserves module_path and aliases'
    '''))
    result = subprocess.run(["zsh", "-df", str(ROOT / "examples" / "api-client.zsh"),
                             env["ZCURL_TEST_HTTP"] + "/bytes"], env=env, cwd="/",
                            capture_output=True, timeout=10)
    assert result.returncode == 0 and result.stdout == bytes(range(256)) + b"\n\n", result.stderr
    print("PASS: project example runs outside the checkout and preserves response bytes")


def interrupt_test(env, plain):
    plain.slow_started.clear()
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe("zsh", ["zsh", "-dfi"], dict(env, TERM="dumb", PS1="zcurl-test> "))
    collected = bytearray()

    def wait_for(marker, timeout=4):
        deadline = time.monotonic() + timeout
        while marker not in collected and time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                collected.extend(os.read(fd, 65536))
        if marker not in collected:
            raise AssertionError(f"PTY missing {marker!r}: {bytes(collected)!r}")

    try:
        os.write(fd, (LOAD + 'print -r -- PTY_READY\n').encode())
        wait_for(b"\r\nPTY_READY\r\n")
        os.write(fd, b'zcurl -t 10000 "$ZCURL_TEST_HTTP/hang"\n')
        assert plain.slow_started.wait(4), "PTY request never started"
        start = time.monotonic()
        os.write(fd, b"\x03")
        os.write(fd, b'zcurl "$ZCURL_TEST_HTTP/tiny"; print -r -- "RECOVERED:$zcurl_http_status"\n')
        wait_for(b"\r\nRECOVERED:200\r\n", timeout=3)
        elapsed = time.monotonic() - start
        print(f"PASS: PTY Ctrl-C interrupts a stalled request; next request succeeds ({elapsed:.2f}s)")
        os.write(fd, b'typeset -A response; TRAPUSR1() { unset response; typeset -g response=changed; }; print -r -- MUTATION_READY\n')
        wait_for(b"\r\nMUTATION_READY\r\n")
        plain.slow_started.clear()
        os.write(fd, b'zcurl -r response "$ZCURL_TEST_HTTP/slow"; print -r -- "MUTATION:$?:$zcurl_error_kind:$response"\n')
        assert plain.slow_started.wait(4), "mutation test request never started"
        os.kill(pid, signal.SIGUSR1)
        wait_for(b"\r\nMUTATION:2:result:changed\r\n")
        os.write(fd, b'TRAPUSR1() { zcurl "$ZCURL_TEST_HTTP/tiny"; print -r -- "REENTRY:$?"; zmodload -u zcurl; print -r -- "UNLOAD:$?"; }; print -r -- REENTRY_READY\n')
        wait_for(b"\r\nREENTRY_READY\r\n")
        plain.slow_started.clear()
        os.write(fd, b'zcurl "$ZCURL_TEST_HTTP/slow"; print -r -- "OUTER:$?:$zcurl_complete"\n')
        assert plain.slow_started.wait(4), "reentry test request never started"
        os.kill(pid, signal.SIGUSR1)
        wait_for(b"\r\nREENTRY:2\r\n")
        wait_for(b"\r\nUNLOAD:1\r\n")
        wait_for(b"\r\nOUTER:0:1\r\n")
        print("PASS: PTY signal traps cannot reenter/unload an active module or overwrite a changed result target")
        os.write(fd, b'unfunction TRAPUSR1; unset response; typeset -A response; zcurl ws open active -- "${ZCURL_TEST_HTTP/http:/ws:}/ws"; print -r -- WS_READY\n')
        wait_for(b"\r\nWS_READY\r\n")
        os.write(fd, b'TRAPUSR1() { zcurl ws drop active; print -r -- "WS_REENTRY:$?"; zmodload -u zcurl; print -r -- "WS_UNLOAD:$?"; unset response; typeset -g response=changed; }; print -r -- WS_TRAP_READY\n')
        wait_for(b"\r\nWS_TRAP_READY\r\n")
        os.write(fd, b'print -r -- WS_POLL_BEGIN; zcurl ws poll active -r response --timeout 1000; print -r -- "WS_MUTATION:$?:$zcurl_error_kind:$response:$zcurl_state"\n')
        wait_for(b"\r\nWS_POLL_BEGIN\r\n")
        os.kill(pid, signal.SIGUSR1)
        wait_for(b"\r\nWS_REENTRY:2\r\n")
        wait_for(b"\r\nWS_UNLOAD:1\r\n")
        wait_for(b"\r\nWS_MUTATION:2:result:changed:open\r\n")
        os.write(fd, b'unfunction TRAPUSR1; print -r -- WS_INTERRUPT_BEGIN; zcurl ws poll active --timeout 1000\n')
        wait_for(b"\r\nWS_INTERRUPT_BEGIN\r\n")
        start = time.monotonic()
        os.write(fd, b'\x03')
        os.write(fd, b'zcurl ws send active --data recovered; repeat 20; do zcurl ws poll active --timeout 100; [[ $zcurl_event == data ]] && break; done; print -r -- "WS_RECOVERED:$zcurl_body:$zcurl_state"\n')
        wait_for(b"\r\nWS_RECOVERED:recovered:open\r\n", timeout=2)
        assert time.monotonic() - start < 1.5, 'WebSocket poll cancellation was delayed'
        plain.slow_started.clear()
        os.write(fd, b'zcurl ws open hanging -- "${ZCURL_TEST_HTTP/http:/ws:}/ws-hang"\n')
        assert plain.slow_started.wait(4), 'WebSocket handshake never started'
        os.write(fd, b'\x03')
        os.write(fd, b'zcurl ws info active; print -r -- "WS_HANDSHAKE_RECOVERED:$?:$zcurl_state"; zcurl --reset\n')
        wait_for(b"\r\nWS_HANDSHAKE_RECOVERED:0:open\r\n", timeout=2)
        print('PASS: PTY WebSocket poll/handshake cancellation, reentry/unload guards, result mutation and connection recovery')
        os.write(fd, b'unset response; typeset -A response; zcurl http submit active --timeout 10000 -- "$ZCURL_TEST_HTTP/hang"; print -r -- HTTP_SUBMITTED\n')
        wait_for(b"\r\nHTTP_SUBMITTED\r\n")
        plain.slow_started.clear()
        os.write(fd, b'zcurl http poll --timeout 1000\n')
        assert plain.slow_started.wait(4), 'concurrent HTTP request never started'
        start = time.monotonic()
        os.write(fd, b'\x03')
        os.write(fd, b'zcurl http info active; print -r -- "HTTP_PRESERVED:$?:$zcurl_state"\n')
        wait_for(b"\r\nHTTP_PRESERVED:0:pending\r\n", timeout=2)
        assert time.monotonic() - start < 1.5, 'HTTP poll cancellation was delayed'
        os.write(fd, b'print -r -- HTTP_WAIT_BEGIN; zcurl http wait active --timeout 600000\n')
        wait_for(b"\r\nHTTP_WAIT_BEGIN\r\n")
        start = time.monotonic()
        os.write(fd, b'\x03')
        os.write(fd, b'zcurl http info active; print -r -- "HTTP_WAIT_PRESERVED:$?:$zcurl_state"\n')
        wait_for(b"\r\nHTTP_WAIT_PRESERVED:0:pending\r\n", timeout=2)
        assert time.monotonic() - start < 1.5, 'HTTP wait cancellation was delayed'
        os.write(fd, b'TRAPUSR1() { zcurl http cancel active; print -r -- "HTTP_REENTRY:$?"; zmodload -u zcurl; print -r -- "HTTP_UNLOAD:$?"; unset response; typeset -g response=changed; }; print -r -- HTTP_TRAP_READY\n')
        wait_for(b"\r\nHTTP_TRAP_READY\r\n")
        os.write(fd, b'zcurl http submit finishing -- "$ZCURL_TEST_HTTP/slow"; print -r -- HTTP_POLL_BEGIN; zcurl http poll -r response --timeout 1000; print -r -- "HTTP_MUTATION:$?:$zcurl_error_kind:$response"\n')
        wait_for(b"\r\nHTTP_POLL_BEGIN\r\n")
        os.kill(pid, signal.SIGUSR1)
        wait_for(b"\r\nHTTP_REENTRY:2\r\n")
        wait_for(b"\r\nHTTP_UNLOAD:1\r\n")
        wait_for(b"\r\nHTTP_MUTATION:2:result:changed\r\n")
        os.write(fd, b'unset response; typeset -A response; zcurl http submit wait_finishing -- "$ZCURL_TEST_HTTP/slow"; print -r -- HTTP_WAIT_MUTATION_BEGIN; zcurl http wait wait_finishing -r response --timeout 1000; print -r -- "HTTP_WAIT_MUTATION:$?:$zcurl_error_kind:$response:$zcurl_handle"\n')
        wait_for(b"\r\nHTTP_WAIT_MUTATION_BEGIN\r\n")
        os.kill(pid, signal.SIGUSR1)
        wait_for(b"\r\nHTTP_WAIT_MUTATION:2:result:changed:wait_finishing\r\n")
        os.write(fd, b'unfunction TRAPUSR1; unset response; typeset -A response; zcurl http collect wait_finishing -r response; print -r -- "HTTP_WAIT_RETAINED:$?:$response[http_status]:$response[complete]"; zcurl http collect finishing -r response; print -r -- "HTTP_RETAINED:$?:$response[http_status]:$response[complete]"; zcurl http cancel active; zcurl http collect active -r response; print -r -- "HTTP_CANCELLED:$?:$response[state]:$response[error_kind]"; zcurl --reset\n')
        wait_for(b"\r\nHTTP_WAIT_RETAINED:0:200:1\r\n")
        wait_for(b"\r\nHTTP_RETAINED:0:200:1\r\n")
        wait_for(b"\r\nHTTP_CANCELLED:42:cancelled:cancelled\r\n")
        print('PASS: PTY concurrent HTTP poll/wait interrupts preserve requests; reentry/unload and result mutation guards hold')
    finally:
        os.close(fd)
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)


def benchmark(env, tls, count):
    cases = {
        "native module": LOAD + '''
            repeat $ZCURL_BENCH_N; do
                zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny" || exit 1
            done
        ''',
        "curl process per request": '''
            repeat $ZCURL_BENCH_N; do
                command curl -q --silent --show-error --max-time 10 --cacert "$ZCURL_TEST_CA" \
                    "$ZCURL_TEST_HTTPS/tiny" -o /dev/null || exit 1
            done
        ''',
        "one curl process, all URLs": '''
            typeset -a requests=()
            repeat $ZCURL_BENCH_N; do
                requests+=( -o /dev/null "$ZCURL_TEST_HTTPS/tiny" )
            done
            command curl -q --silent --show-error --max-time 10 --cacert "$ZCURL_TEST_CA" \
                "${requests[@]}" || exit 1
        ''',
    }
    env = dict(env, ZCURL_BENCH_N=str(count))
    timings = {name: [] for name in cases}
    connections = {name: [] for name in cases}
    # Rotate order between rounds to reduce systematic warmup/order bias.
    names = list(cases)
    for round_no in range(3):
        for name in names[round_no:] + names[:round_no]:
            before = tls.connections
            start = time.perf_counter()
            run(env, cases[name])
            timings[name].append((time.perf_counter() - start) * 1000)
            connections[name].append(tls.connections - before)
    print(f"\nLocal verified HTTPS, {count} sequential 3-byte responses, 3 rounds:")
    for name in cases:
        print(f"{name}: median {statistics.median(timings[name]):.2f} ms; "
              f"connections/round {connections[name]}; "
              f"samples ms {[round(t, 2) for t in timings[name]]}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--valgrind", action="store_true", help="memory-check scripted tests (requires valgrind)")
    args = parser.parse_args()
    if not 1 <= args.count <= 1000:
        parser.error("--count must be between 1 and 1000")
    if args.valgrind and args.benchmark:
        parser.error("run memory checks and benchmarks separately")
    with fixture() as (env, plain, tls, temp):
        if args.valgrind:
            env["ZCURL_TEST_VALGRIND"] = "1"
        integration(env, plain, tls, temp)
        api_test(env, plain, temp)
        loader_test(env)
        before = plain.request_count
        run(env, LOAD + '''
            setopt errexit
            typeset -A response
            zcurl http submit untouched -- "$ZCURL_TEST_HTTP/tiny"
            zcurl http cancel untouched
            zcurl http collect untouched -r response && exit 1
            [[ $response[state] == cancelled && $response[bytes] == 0 ]] || exit 2
            zcurl http submit bad -r 'response[x]' -- "$ZCURL_TEST_HTTP/tiny" && exit 3
            zcurl http submit bad -H $'X: bad\\nfield' -- "$ZCURL_TEST_HTTP/tiny" && exit 4
            zmodload -u zcurl
        ''')
        assert plain.request_count == before, 'HTTP submission/cancellation or invalid inputs caused network I/O'
        print(run(env, (ROOT / 'tests' / 'concurrency.zsh').read_text()))
        assert (temp / 'concurrent.bin').read_bytes() == bytes(range(256)) + b'\n\n', 'owned async upload changed'
        batch = subprocess.run(
            ['zsh', '-df', str(ROOT / 'examples' / 'concurrent.zsh'),
             env['ZCURL_TEST_HTTP'] + '/parallel/one', env['ZCURL_TEST_HTTP'] + '/parallel/two'],
            env=env, cwd='/', capture_output=True, text=True, timeout=10)
        assert batch.returncode == 0, batch.stderr
        assert sorted(batch.stdout.splitlines()) == [
            'request_1: HTTP 200, 13 bytes', 'request_2: HTTP 200, 13 bytes'], batch.stdout
        print('PASS: concurrent batch example overlaps requests outside the checkout')
        ws_result = run(env, (ROOT / 'tests' / 'websocket.zsh').read_text())
        assert ws_result.startswith('PASS: WS/WSS'), 'WebSocket script ended before completing its assertions'
        print(ws_result)
        assert not plain.ws_errors and not tls.ws_errors, (plain.ws_errors, tls.ws_errors)
        assert any(op == 10 and data == b'heartbeat\0' for _, op, _, data in plain.ws_frames), 'automatic pong missing'
        assert any(op == 10 and data == b'unsolicited' for _, op, _, data in tls.ws_frames), 'explicit pong missing'
        interrupt_test(env, plain)
        if args.benchmark:
            benchmark(env, tls, args.count)
