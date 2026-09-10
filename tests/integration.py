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
import shutil
import signal
import socket
import ssl
import statistics
import subprocess
import tempfile
import threading
import time
import websocket_fixture
import completion
import compression
import proxy

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
        self.stream_release = threading.Event()
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
        if self.path.startswith('/compressed/'):
            compression.serve(self, request_body)
            return
        if self.path == "/release-ws":
            self.server.ws_release.set()
        if self.path == "/release-http":
            self.server.http_release.set()
        if self.path == "/release-stream":
            self.server.stream_release.set()
        if self.path.startswith("/parallel/"):
            # Neither response can finish until both requests arrive.
            self.server.http_barrier.wait(timeout=5)
        if self.path in ("/held", "/stream-held"):
            self.send_response(200)
            self.send_header("Content-Length", "10")
            self.end_headers()
            self.wfile.write(b"part")
            self.server.slow_started.set()
            release = self.server.stream_release if self.path == "/stream-held" else self.server.http_release
            assert release.wait(10), "held HTTP request was never released"
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
def fixture(module_dir=None, ubsan=False, asan_runtime=None):
    module_dir = (module_dir or ROOT / 'build').resolve()
    if not (module_dir / 'zcurl.so').is_file():
        raise FileNotFoundError(f'no zcurl.so in {module_dir}; build the selected module first')
    with tempfile.TemporaryDirectory(prefix="zcurl-test-ø-") as temp:
        temp = Path(temp)
        project = ROOT
        if module_dir != ROOT / 'build':
            # The loader intentionally resolves build/ relative to its source.
            # Stage real loader/example files beside the selected library so
            # these tests cannot silently fall back to the normal module.
            project = temp / 'project'
            (project / 'build').mkdir(parents=True)
            (project / 'build' / 'zcurl.so').symlink_to(module_dir / 'zcurl.so')
            shutil.copy2(ROOT / 'zcurl.zsh', project / 'zcurl.zsh')
            shutil.copytree(ROOT / 'examples', project / 'examples')
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
        env.update(NO_PROXY="*", ZCURL_MODULE_PATH=str(module_dir), ZCURL_TEST_ROOT=str(project),
                   ZCURL_TEST_CA=str(cert), ZCURL_TEST_TMP=str(temp),
                   ZCURL_TEST_HTTP=f"http://127.0.0.1:{plain.server_port}",
                   ZCURL_TEST_HTTPS=f"https://localhost:{tls.server_port}",
                   ZCURL_TEST_MISMATCH=f"https://127.0.0.1:{tls.server_port}")
        if ubsan or asan_runtime:
            # Reports from expected-failure subshells must fail the whole suite
            # too. Per-process logs also preserve diagnostics from PTY shells.
            env['UBSAN_OPTIONS'] = f'halt_on_error=1:print_stacktrace=1:log_path={temp}/ubsan'
        if asan_runtime:
            # Zsh is not ASan-linked: load the matching runtime before the module.
            env['LD_PRELOAD'] = str(asan_runtime) + (':' + env['LD_PRELOAD'] if env.get('LD_PRELOAD') else '')
            env['ASAN_OPTIONS'] = f'detect_leaks=0:halt_on_error=1:log_path={temp}/asan'
        try:
            yield env, plain, tls, temp
        finally:
            for server, thread in zip((plain, tls), threads):
                server.shutdown()
                server.server_close()
                thread.join()
            if ubsan or asan_runtime:
                reports = sorted([*temp.glob('ubsan.*'), *temp.glob('asan.*')])
                if reports:
                    diagnostics = '\n'.join(f'{p.name}:\n{p.read_text()}' for p in reports)
                    raise AssertionError(f'Sanitizer reported errors:\n{diagnostics}')


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
    project = Path(env['ZCURL_TEST_ROOT'])
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
    result = subprocess.run(["zsh", "-df", str(project / "examples" / "api-client.zsh"),
                             env["ZCURL_TEST_HTTP"] + "/bytes"], env=env, cwd="/",
                            capture_output=True, timeout=10)
    assert result.returncode == 0 and result.stdout == bytes(range(256)) + b"\n\n", result.stderr
    print("PASS: project example runs outside the checkout and preserves response bytes")


def streaming_test(env, plain, temp):
    before = plain.request_count
    print(run(env, LOAD + '''
        setopt errexit
        typeset -A response
        exec {input}<"$ZCURL_TEST_CA"
        exec {device}>/dev/null
        for fd in "$input" "$device" -1 2147483647 '1+1'; do
            zcurl -r response --output-fd "$fd" -- "$ZCURL_TEST_HTTP/tiny" && exit 1
            [[ $response[status] == 2 && $response[code] == -1 ]] || exit 2
            zcurl http submit invalid -r response --output-fd "$fd" -- "$ZCURL_TEST_HTTP/tiny" && exit 3
            [[ $response[status] == 2 ]] || exit 4
        done
        zcurl --output-fd 1 "$ZCURL_TEST_HTTP/tiny" && exit 5
        # stdout here is a pipe; unsupported descriptors must never start I/O.
        print -r -- 'PASS: invalid/read-only/nonregular output descriptors rejected before HTTP'
    '''))
    assert plain.request_count == before, 'invalid output descriptor caused HTTP I/O'
    print(run(env, (ROOT / 'tests' / 'streaming.zsh').read_text()))
    binary = bytes(range(256)) + b'\n\n'
    assert (temp / 'stream-sync.bin').read_bytes() == b'prefix' + binary + b'suffix'
    assert (temp / 'stream-async.bin').read_bytes() == binary
    assert (temp / 'stream-reused.bin').read_bytes() == b'untouched'
    assert (temp / 'stream-append.bin').read_bytes() == b'start' + b'ok\n' * 2
    assert (temp / 'stream-http-error.bin').read_bytes() == b'ok\n'
    assert (temp / 'stream-partial.bin').read_bytes() == b'part'
    assert (temp / 'stream-limit.bin').read_bytes() == b''
    assert (temp / 'stream-large.bin').read_bytes() == b'x' * (8 * 1024 * 1024 + 1)
    # A per-shell file-size limit forces a short write followed by EFBIG.
    # Ignore SIGXFSZ so the module can report the write failure and byte count.
    count = int(run(env, LOAD + '''
        setopt errexit
        trap '' XFSZ
        ulimit -f 1
        exec {out}>"$ZCURL_TEST_TMP/stream-write-error.bin"
        typeset -A response
        zcurl -r response --output-fd "$out" --max-body 16777216 -- "$ZCURL_TEST_HTTP/large" && exit 1
        [[ $response[status] == 23 && $response[code] == 23 &&
           $response[error_kind] == output && $response[complete] == 0 && -z $response[body] ]] || exit 2
        exec {out}>&-
        print -r -- "$response[bytes]"
    '''))
    assert 0 < count < 8 * 1024 * 1024
    assert (temp / 'stream-write-error.bin').read_bytes() == b'x' * count
    print('PASS: direct file bytes, partial write failures and descriptor ownership independently verified')


def upload_test(env, plain, temp):
    before = plain.request_count
    print(run(env, LOAD + '''
        setopt errexit
        typeset -A response
        exec {output}>"$ZCURL_TEST_TMP/upload-invalid.bin"
        exec {device}</dev/null
        exec {directory}<"$ZCURL_TEST_TMP"
        exec {input}<"$ZCURL_TEST_CA"
        for fd in "$output" "$device" "$directory" -1 2147483647 '1+1'; do
            zcurl -r response --data-fd "$fd" -- "$ZCURL_TEST_HTTP/echo" && exit 1
            [[ $response[status] == 2 && $response[code] == -1 && $response[error_kind] == usage ]] || exit 2
            zcurl http submit invalid -r response --data-fd "$fd" -- "$ZCURL_TEST_HTTP/echo" && exit 3
            [[ $response[status] == 2 && $response[code] == -1 ]] || exit 4
        done
        for option in --head --data --data-fd; do
            args=( "$option" )
            [[ $option == --head ]] || args+=( "$input" )
            for mode in sync async; do
                cmd=( zcurl -r response )
                [[ $mode == sync ]] || cmd=( zcurl http submit invalid -r response )
                "$cmd[@]" --data-fd "$input" "$args[@]" -- "$ZCURL_TEST_HTTP/echo" && exit 5
                [[ $response[status] == 2 && $response[code] == -1 ]] || exit 6
            done
        done
        zcurl --data-fd 0 -- "$ZCURL_TEST_HTTP/echo" </dev/null && exit 7
        # Pipe sources are rejected too, without reading or starting HTTP.
        print -r -- payload | zcurl -r response --data-fd 0 -- "$ZCURL_TEST_HTTP/echo" && exit 8
        [[ $response[status] == 2 && $response[error_kind] == usage && $response[code] == -1 ]] || exit 9
        print -r -- 'PASS: invalid/nonregular input descriptors and conflicting options rejected before HTTP'
    '''))
    assert plain.request_count == before, 'invalid upload caused HTTP I/O'
    binary = bytes(range(256)) + b'\n\n'
    (temp / 'upload-source.bin').write_bytes(b'prefix' + binary)
    (temp / 'upload-empty.bin').write_bytes(b'')
    large = bytes(range(256)) * 32768 + b'\n'
    (temp / 'upload-large.bin').write_bytes(large)
    with (temp / 'upload-sparse.bin').open('wb') as source:
        source.truncate(160 * 1024 * 1024)
    print(run(env, (ROOT / 'tests' / 'uploads.zsh').read_text()))
    assert (temp / 'upload-sync.bin').read_bytes() == binary
    assert (temp / 'upload-first.bin').read_bytes() == binary
    assert (temp / 'upload-second.bin').read_bytes() == binary[1:]
    assert (temp / 'upload-large-echo.bin').read_bytes() == large
    assert (temp / 'upload-source.bin').read_bytes() == b'prefix' + binary
    assert (temp / 'upload-cleanup.bin').read_bytes() == b''
    print('PASS: binary upload ranges and large file-to-file HTTPS round trip independently verified')


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
        os.write(fd, b'zcurl session create interrupted; zcurl --session interrupted -t 10000 "$ZCURL_TEST_HTTP/hang"\n')
        assert plain.slow_started.wait(4), "PTY request never started"
        start = time.monotonic()
        os.write(fd, b"\x03")
        os.write(fd, b'zcurl --session interrupted "$ZCURL_TEST_HTTP/tiny"; print -r -- "RECOVERED:$zcurl_http_status"\n')
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
        os.write(fd, b'TRAPUSR1() { zcurl "$ZCURL_TEST_HTTP/tiny"; print -r -- "REENTRY:$?"; zcurl session drop interrupted; print -r -- "SESSION_DROP:$?"; zmodload -u zcurl; print -r -- "UNLOAD:$?"; }; print -r -- REENTRY_READY\n')
        wait_for(b"\r\nREENTRY_READY\r\n")
        plain.slow_started.clear()
        os.write(fd, b'zcurl --session interrupted "$ZCURL_TEST_HTTP/slow"; print -r -- "OUTER:$?:$zcurl_complete"\n')
        assert plain.slow_started.wait(4), "reentry test request never started"
        os.kill(pid, signal.SIGUSR1)
        wait_for(b"\r\nREENTRY:2\r\n")
        wait_for(b"\r\nSESSION_DROP:2\r\n")
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
        os.write(fd, b'zcurl session create async_other; zcurl http submit any_other --session async_other -- "$ZCURL_TEST_HTTP/hang"; print -r -- HTTP_ANY_BEGIN; zcurl http wait-any active any_other --timeout 600000\n')
        wait_for(b"\r\nHTTP_ANY_BEGIN\r\n")
        start = time.monotonic()
        os.write(fd, b'\x03')
        os.write(fd, b'zcurl http info any_other; print -r -- "HTTP_ANY_PRESERVED:$?:$zcurl_state"; zcurl http drop any_other; zcurl session drop async_other\n')
        wait_for(b"\r\nHTTP_ANY_PRESERVED:0:pending\r\n", timeout=2)
        assert time.monotonic() - start < 1.5, 'HTTP wait-any cancellation was delayed'
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
        os.write(fd, b'unset response; typeset -A response; zcurl http submit any_finishing -- "$ZCURL_TEST_HTTP/slow"; print -r -- HTTP_ANY_MUTATION_BEGIN; zcurl http wait-any active any_finishing -r response --timeout 1000; print -r -- "HTTP_ANY_MUTATION:$?:$zcurl_error_kind:$response:$zcurl_handle"\n')
        wait_for(b"\r\nHTTP_ANY_MUTATION_BEGIN\r\n")
        os.kill(pid, signal.SIGUSR1)
        wait_for(b"\r\nHTTP_ANY_MUTATION:2:result:changed:any_finishing\r\n")
        os.write(fd, b'unfunction TRAPUSR1; unset response; typeset -A response; zcurl http collect any_finishing -r response; print -r -- "HTTP_ANY_RETAINED:$?:$response[http_status]:$response[complete]"\n')
        wait_for(b"\r\nHTTP_ANY_RETAINED:0:200:1\r\n")
        os.write(fd, b'zcurl http collect wait_finishing -r response; print -r -- "HTTP_WAIT_RETAINED:$?:$response[http_status]:$response[complete]"; zcurl http collect finishing -r response; print -r -- "HTTP_RETAINED:$?:$response[http_status]:$response[complete]"; zcurl http cancel active; zcurl http collect active -r response; print -r -- "HTTP_CANCELLED:$?:$response[state]:$response[error_kind]"; zcurl --reset\n')
        wait_for(b"\r\nHTTP_WAIT_RETAINED:0:200:1\r\n")
        wait_for(b"\r\nHTTP_RETAINED:0:200:1\r\n")
        wait_for(b"\r\nHTTP_CANCELLED:42:cancelled:cancelled\r\n")
        print('PASS: PTY concurrent HTTP poll/wait/wait-any interrupts preserve requests; reentry/unload and result mutation guards hold')
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
    parser.add_argument("--module-dir", type=Path,
                        help="directory containing the module to test (also used by loader/examples)")
    sanitizers = parser.add_mutually_exclusive_group()
    sanitizers.add_argument("--ubsan", action="store_true", help="check undefined behavior in all child shells")
    sanitizers.add_argument("--asan", action="store_true", help="check address and undefined behavior errors in all child shells")
    parser.add_argument("--asan-runtime", type=Path, help="matching shared libasan runtime (required with --asan)")
    args = parser.parse_args()
    if not 1 <= args.count <= 1000:
        parser.error("--count must be between 1 and 1000")
    if args.valgrind and args.benchmark:
        parser.error("run memory checks and benchmarks separately")
    if (args.ubsan or args.asan) and (args.valgrind or args.benchmark):
        parser.error("run sanitizers separately from Valgrind and benchmarks")
    if args.asan != (args.asan_runtime is not None):
        parser.error('--asan and --asan-runtime must be supplied together')
    if args.asan:
        args.asan_runtime = args.asan_runtime.resolve()
        if not args.asan_runtime.is_file() or any(c.isspace() or c == ':' for c in str(args.asan_runtime)):
            parser.error('--asan-runtime must be a file whose absolute path contains no whitespace or colon')
    if args.module_dir is None:
        args.module_dir = ROOT / ('build/asan' if args.asan else 'build/ubsan' if args.ubsan else 'build')
    if not (args.module_dir / 'zcurl.so').is_file():
        parser.error(f'no zcurl.so in {args.module_dir}; build the selected module first')
    if args.ubsan or args.asan:
        symbols = subprocess.run(['nm', '-D', str(args.module_dir / 'zcurl.so')],
                                 capture_output=True, text=True, check=True, timeout=10)
        if '__ubsan_handle_' not in symbols.stdout:
            parser.error('selected module has no UBSan runtime checks; rebuild with the requested sanitizer target')
        if args.asan and '__asan_init' not in symbols.stdout:
            parser.error('selected module has no ASan runtime checks; run make asan')
        if args.ubsan and '__asan_init' in symbols.stdout:
            parser.error('selected module also requires ASan; use --asan with --asan-runtime')
    with fixture(args.module_dir, args.ubsan, args.asan_runtime) as (env, plain, tls, temp):
        print(f'Testing module: {Path(env["ZCURL_MODULE_PATH"]) / "zcurl.so"}', flush=True)
        if args.valgrind:
            env["ZCURL_TEST_VALGRIND"] = "1"
        integration(env, plain, tls, temp)
        api_test(env, plain, temp)
        loader_test(env)
        completion.test(env, plain, temp)
        compression.test(env, plain, temp, run)
        proxy.test(env, plain, temp, run)
        session_before = (plain.connections, tls.connections, plain.request_count, tls.request_count)
        session_result = run(env, (ROOT / 'tests' / 'sessions.zsh').read_text())
        session_after = (plain.connections, tls.connections, plain.request_count, tls.request_count)
        assert tuple(b - a for a, b in zip(session_before, session_after)) == (3, 6, 3, 17), (session_before, session_after)
        assert session_result.startswith('PASS: named HTTP sessions'), session_result
        print(session_result)
        alpha = json.loads((temp / 'session-alpha.json').read_text())
        assert alpha['method'] == 'POST' and bytes.fromhex(alpha['body']) == b'owned\0\n\n'
        assert dict(alpha['headers'])['Authorization'] == 'Bearer alpha'
        for name in ('reset', 'beta'):
            reply = json.loads((temp / f'session-{name}.json').read_text())
            assert reply['method'] == 'GET' and reply['body'] == ''
            assert 'authorization' not in {k.lower() for k, _ in reply['headers']}
        assert (temp / 'session-output.bin').read_bytes() == b'file\0session\n\n'
        tls_before = (tls.connections, tls.request_count)
        concurrent_sessions = run(env, (ROOT / 'tests' / 'session-concurrency.zsh').read_text())
        assert concurrent_sessions.startswith('PASS: named concurrent sessions'), concurrent_sessions
        print(concurrent_sessions)
        assert (tls.connections - tls_before[0], tls.request_count - tls_before[1]) == (6, 15), 'named concurrent pools did not preserve independent reuse'
        assert (temp / 'session-job-output.bin').read_bytes() == b'named\0concurrent\n\n'
        before = plain.request_count
        isolated = run(env, LOAD + '''
            setopt errexit
            zcurl session create isolated
            zcurl http submit deferred --session isolated "$ZCURL_TEST_HTTP/tiny"
            zcurl --session isolated "$ZCURL_TEST_HTTP/tiny"
            zcurl http info deferred
            [[ $zcurl_state == pending ]] || exit 1
            zcurl http drop deferred
            zcurl session drop isolated
            zmodload -u zcurl
            print 'PASS: synchronous calls leave concurrent jobs undriven'
        ''')
        assert isolated.startswith('PASS: synchronous calls'), isolated
        assert plain.request_count == before + 1, 'synchronous request drove a concurrent job in the same session'
        print(isolated)
        before = plain.request_count
        print(run(env, (ROOT / 'tests' / 'handles.zsh').read_text()))
        assert plain.request_count == before + 4, 'handle discovery caused unexpected HTTP I/O'
        streaming_test(env, plain, temp)
        upload_test(env, plain, temp)
        print(run(env, (ROOT / 'tests' / 'descriptors.zsh').read_text()))
        assert (temp / 'protected-output.bin').read_bytes() == b'file\0payload\n\n'
        before = plain.request_count
        print(run(env, (ROOT / 'tests' / 'headers.zsh').read_text()))
        assert plain.request_count == before + 5, 'header lookups caused unexpected HTTP I/O'
        before = plain.request_count
        run(env, LOAD + '''
            setopt errexit
            typeset -A response
            zcurl session create deferred
            zcurl http submit untouched --session deferred -- "$ZCURL_TEST_HTTP/tiny"
            zcurl http cancel untouched
            zcurl http collect untouched -r response && exit 1
            [[ $response[state] == cancelled && $response[bytes] == 0 ]] || exit 2
            zcurl http submit bad -r 'response[x]' -- "$ZCURL_TEST_HTTP/tiny" && exit 3
            zcurl http submit bad -H $'X: bad\\nfield' -- "$ZCURL_TEST_HTTP/tiny" && exit 4
            zmodload -u zcurl
        ''')
        assert plain.request_count == before, 'HTTP submission/cancellation or invalid inputs caused network I/O'
        print(run(env, (ROOT / 'tests' / 'concurrency.zsh').read_text()))
        before = plain.request_count
        wait_result = run(env, (ROOT / 'tests' / 'wait-any.zsh').read_text())
        assert wait_result.startswith('PASS: wait-any'), 'wait-any script ended before completing its assertions'
        print(wait_result)
        assert plain.request_count == before + 6, 'invalid wait-any selection caused HTTP I/O'
        assert (temp / 'concurrent.bin').read_bytes() == bytes(range(256)) + b'\n\n', 'owned async upload changed'
        batch = subprocess.run(
            ['zsh', '-df', str(Path(env['ZCURL_TEST_ROOT']) / 'examples' / 'concurrent.zsh'),
             env['ZCURL_TEST_HTTP'] + '/parallel/one', env['ZCURL_TEST_HTTP'] + '/parallel/two'],
            env=env, cwd='/', capture_output=True, text=True, timeout=10)
        assert batch.returncode == 0, batch.stderr
        assert sorted(batch.stdout.splitlines()) == [
            'request_1: HTTP 200, 13 bytes', 'request_2: HTTP 200, 13 bytes'], batch.stdout
        print('PASS: concurrent batch example overlaps requests outside the checkout')
        ws_result = run(env, (ROOT / 'tests' / 'websocket.zsh').read_text())
        assert ws_result.startswith('PASS: WS/WSS'), 'WebSocket script ended before completing its assertions'
        print(ws_result)
        before = plain.request_count + tls.request_count
        protocol_result = run(env, (ROOT / 'tests' / 'websocket-protocol.zsh').read_text())
        assert protocol_result.startswith('PASS: required WebSocket subprotocol'), protocol_result
        assert plain.request_count + tls.request_count == before + 29, 'unexpected subprotocol request count'
        print(protocol_result)
        assert not plain.ws_errors and not tls.ws_errors, (plain.ws_errors, tls.ws_errors)
        assert any(op == 10 and data == b'heartbeat\0' for _, op, _, data in plain.ws_frames), 'automatic pong missing'
        assert any(op == 10 and data == b'unsolicited' for _, op, _, data in tls.ws_frames), 'explicit pong missing'
        interrupt_test(env, plain)
        if args.benchmark:
            benchmark(env, tls, args.count)
    if args.ubsan:
        print('PASS: UBSan module checks, including loader, examples, completion and signal PTYs')
    if args.asan:
        print('PASS: ASan/UBSan module checks, including loader, examples, completion and signal PTYs')
