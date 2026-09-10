"""Loopback-only HTTP forwarding and CONNECT proxy, independent of libcurl."""
import base64
import contextlib
import http.client
import http.server
import json
import select
import socket
import ssl
import subprocess
import threading
from pathlib import Path
from urllib.parse import urlsplit


class Proxy(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, origins):
        super().__init__(('127.0.0.1', 0), Handler)
        self.origins = origins
        self.records = []
        self.errors = []
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        self.require_auth = False
        self.reject_connect = False
        self.connect_subprotocol = None

    def handle_error(self, request, client_address):
        import traceback
        self.errors.append(traceback.format_exc())


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except (OSError, http.client.HTTPException):
            # Clients may reject TLS, cancel a request or reset the module.
            pass

    def admitted(self, host, port):
        with self.server.lock:
            self.server.records.append((self.command, self.path, dict(self.headers)))
        if (host, port) not in self.server.origins:
            self.send_error(403)
            return False
        expected = 'Basic ' + base64.b64encode(b'fixture:secret').decode()
        if self.server.require_auth and self.headers.get('Proxy-Authorization') != expected:
            self.send_error(407)
            return False
        return True

    def do_CONNECT(self):
        target = urlsplit('//' + self.path)
        if not self.admitted(target.hostname, target.port):
            return
        if self.server.reject_connect:
            self.send_error(403)
            return
        with socket.create_connection((target.hostname, target.port), timeout=5) as upstream:
            self.send_response(200, 'Connection established')
            if self.server.connect_subprotocol is not None:
                self.send_header('Sec-WebSocket-Protocol', self.server.connect_subprotocol)
            self.end_headers()
            self.close_connection = True
            self.connection.settimeout(5)
            while not self.server.stopping.is_set():
                # TLS can retain decrypted bytes after the fd stops being readable.
                if isinstance(self.connection, ssl.SSLSocket) and self.connection.pending():
                    readable = [self.connection]
                else:
                    readable, _, _ = select.select([self.connection, upstream], [], [], 0.2)
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    destination = upstream if source is self.connection else self.connection
                    destination.sendall(data)

    def do_GET(self):
        target = urlsplit(self.path)
        if target.scheme != 'http' or not self.admitted(target.hostname, target.port or 80):
            return
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        excluded = {'proxy-authorization', 'proxy-connection', 'connection', 'transfer-encoding'}
        headers = {k: v for k, v in self.headers.items() if k.lower() not in excluded}
        headers['Connection'] = 'close'
        path = target.path or '/'
        if target.query:
            path += '?' + target.query
        with contextlib.closing(http.client.HTTPConnection(target.hostname, target.port or 80, timeout=5)) as origin:
            origin.request(self.command, path, body=body, headers=headers)
            response = origin.getresponse()
            data = response.read()
            self.send_response(response.status)
            for name, value in response.getheaders():
                if name.lower() not in excluded | {'content-length'}:
                    self.send_header(name, value)
            self.send_header('Content-Length', response.getheader('Content-Length') if self.command == 'HEAD' else str(len(data)))
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(data)

    do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_GET


@contextlib.contextmanager
def fixture(env, tls_context=None):
    targets = [urlsplit(env[key]) for key in ('ZCURL_TEST_HTTP', 'ZCURL_TEST_HTTPS', 'ZCURL_TEST_MISMATCH')]
    server = Proxy({(target.hostname, target.port) for target in targets})
    if tls_context:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'https://localhost:{server.server_port}' if tls_context else f'http://127.0.0.1:{server.server_port}'
    try:
        yield server, dict(env, http_proxy=url, https_proxy=url, NO_PROXY='', ZCURL_TEST_PROXY=url)
    finally:
        server.stopping.set()
        server.shutdown()
        server.server_close()
        thread.join()
        assert not server.errors, server.errors


def test(env, plain, temp, run):
    setup = '''
        setopt errexit nounset
        module_path=( "$ZCURL_MODULE_PATH" $module_path )
        zmodload zcurl
        typeset -A response
        check() { [[ $1 == $2 ]] || { print -ru2 -- "FAIL: $1 != $2"; exit 1; } }
    '''
    with fixture(env) as (server, proxy_env):
        def check(source, count, **overrides):
            before = len(server.records)
            output = run(dict(proxy_env, **overrides), setup + source + '\nprint PROXY_CASE_DONE\n')
            assert output.endswith('PROXY_CASE_DONE'), output
            assert len(server.records) == before + count, (source, server.records[before:])

        check('''
            zcurl "$ZCURL_TEST_HTTP/tiny"
            check "$zcurl_body" $'ok\\n'
            zcurl "$ZCURL_TEST_HTTP/tiny"
            check $zcurl_new_connections 0
        ''', 2)
        check('zcurl --proxy "" "$ZCURL_TEST_HTTP/tiny"', 0)
        check('zcurl --proxy "$ZCURL_TEST_PROXY" "$ZCURL_TEST_HTTP/tiny"', 0, NO_PROXY='*')
        check('zcurl --proxy "$ZCURL_TEST_PROXY" --noproxy "" "$ZCURL_TEST_HTTP/tiny"', 1, NO_PROXY='*')
        for bypass in ('*', '127.0.0.1', '127.0.0.0/8', 'example.invalid,127.0.0.1'):
            check('zcurl --noproxy "$BYPASS" "$ZCURL_TEST_HTTP/tiny"', 0, BYPASS=bypass)
        check('zcurl --noproxy localhost "$ZCURL_TEST_HTTP/tiny"', 1)
        check('''
            zcurl --proxy "" "$ZCURL_TEST_HTTP/tiny"
            zcurl "$ZCURL_TEST_HTTP/tiny"
            zcurl --noproxy '*' "$ZCURL_TEST_HTTP/tiny"
            zcurl "$ZCURL_TEST_HTTP/tiny"
            check "$http_proxy" "$ZCURL_TEST_PROXY"
            check "$NO_PROXY" ''
        ''', 2)

        check('''
            submit_local() {
                local route=$ZCURL_TEST_PROXY bypass=''
                zcurl http submit via --proxy "$route" --noproxy "$bypass" -- "$ZCURL_TEST_HTTP/parallel/one"
            }
            submit_local
            zcurl http submit direct --proxy '' -- "$ZCURL_TEST_HTTP/parallel/two"
            repeat 10; do typeset churn=${(pl:4096::x:)ZCURL_TEST_PROXY}; done
            zcurl http wait via
            zcurl http collect via -r response
            check "$response[body]" /parallel/one
            zcurl http wait direct
            zcurl http collect direct -r response
            check "$response[body]" /parallel/two
        ''', 1)

        before = len(server.records)
        check('''
            zcurl --proxy "$ZCURL_TEST_PROXY" --noproxy '' -c "$ZCURL_TEST_CA" \
                -H 'Authorization: Bearer fixture-only' -H 'X-Origin: private' \
                "$ZCURL_TEST_HTTPS/inspect"
            print -rn -- "$zcurl_body" > "$ZCURL_TEST_TMP/proxy-inspect.json"
            zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
            check $zcurl_new_connections 0
            check "$zcurl_body" $'ok\\n'
        ''', 1)
        method, _, headers = server.records[before]
        assert method == 'CONNECT'
        assert not {'authorization', 'x-origin', 'sec-websocket-protocol'} & {k.lower() for k in headers}
        origin_headers = dict(json.loads((temp / 'proxy-inspect.json').read_text())['headers'])
        assert origin_headers['Authorization'] == 'Bearer fixture-only'
        assert origin_headers['X-Origin'] == 'private'

        for source in ('zcurl "$ZCURL_TEST_HTTPS/tiny"',
                       'zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_MISMATCH/tiny"'):
            check(f'''if {source}; then exit 1; else check $? 60; fi
                      check $zcurl_complete 0''', 1)
        check('''
            integer output_fd
            exec {output_fd}>"$ZCURL_TEST_TMP/proxy-echo.bin"
            zcurl http submit echo --proxy "$ZCURL_TEST_PROXY" --noproxy '' \
                -c "$ZCURL_TEST_CA" --data $'through\\0proxy\\n\\n' \
                --output-fd "$output_fd" "$ZCURL_TEST_HTTPS/echo"
            exec {output_fd}>&-
            zcurl http wait echo
            zcurl http collect echo -r response
            check "$response[body]" ''
            check $response[complete] 1
        ''', 1)
        assert (temp / 'proxy-echo.bin').read_bytes() == b'through\0proxy\n\n'

        server.require_auth = True
        authenticated = proxy_env['ZCURL_TEST_PROXY'].replace('http://', 'http://fixture:secret@')
        check('''
            zcurl --proxy "$AUTH_PROXY" "$ZCURL_TEST_HTTP/inspect"
            check $zcurl_http_status 200
            print -rn -- "$zcurl_body" > "$ZCURL_TEST_TMP/proxy-auth.json"
        ''', 1, AUTH_PROXY=authenticated)
        auth_headers = json.loads((temp / 'proxy-auth.json').read_text())['headers']
        assert 'proxy-authorization' not in {name.lower() for name, _ in auth_headers}
        check('''
            zcurl --proxy "$AUTH_PROXY" -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/inspect"
            print -rn -- "$zcurl_body" > "$ZCURL_TEST_TMP/proxy-auth-tls.json"
        ''', 1, AUTH_PROXY=authenticated)
        tls_headers = json.loads((temp / 'proxy-auth-tls.json').read_text())['headers']
        assert 'proxy-authorization' not in {name.lower() for name, _ in tls_headers}
        check('''
            zcurl --proxy "$AUTH_PROXY" "$ZCURL_TEST_HTTP/tiny"
            check "$zcurl_body" $'ok\\n'
            if zcurl --fail "$ZCURL_TEST_HTTP/tiny"; then exit 1; else check $? 22; fi
            check $zcurl_http_status 407
        ''', 2, AUTH_PROXY=authenticated)
        server.require_auth = False
        server.reject_connect = True
        check('''
            if zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"; then exit 1; fi
            check $zcurl_error_kind transport
            check $zcurl_complete 0
        ''', 1)
        server.reject_connect = False

        # A bound, non-listening port reliably refuses connections without a
        # race to reserve an unused endpoint. Failure must not retry directly.
        with socket.socket() as refused:
            refused.bind(('127.0.0.1', 0))
            before = plain.request_count
            check('''
                if zcurl --proxy "$REFUSED_PROXY" "$ZCURL_TEST_HTTP/tiny"; then exit 1; else check $? 7; fi
                check $zcurl_error_kind transport
                check $zcurl_complete 0
            ''', 0, REFUSED_PROXY=f'http://127.0.0.1:{refused.getsockname()[1]}')
            assert plain.request_count == before

        before = plain.request_count
        check('''
            for flag in --proxy --noproxy; do
                if zcurl "$flag"; then exit 1; else check $? 2; fi
                if zcurl "$flag" '' "$flag" '' "$ZCURL_TEST_HTTP/tiny"; then exit 1; else check $? 2; fi
                if zcurl "$flag" $'bad\\0tail' "$ZCURL_TEST_HTTP/tiny"; then exit 1; else check $? 2; fi
            done
            if zcurl ws send invalid --proxy ''; then exit 1; else check $? 2; fi
        ''', 0)
        assert plain.request_count == before
        assert not server.errors, server.errors
    print('PASS: HTTP proxy routing, bypass/reset, concurrent ownership, CONNECT TLS, credentials and binary output')
    test_websockets(env, plain, run, setup)
    test_https_proxy(env, plain, temp, run, setup)


def test_websockets(env, plain, run, setup):
    setup += '''
        typeset ws_url=${ZCURL_TEST_HTTP/http:/ws:}
        typeset wss_url=${ZCURL_TEST_HTTPS/https:/wss:}
    '''
    with fixture(env) as (server, proxy_env):
        def check(source, count, **overrides):
            before = len(server.records)
            output = run(dict(proxy_env, **overrides), setup + source + '\nprint WS_PROXY_CASE_DONE\n')
            assert output.endswith('WS_PROXY_CASE_DONE'), output
            records = server.records[before:]
            assert len(records) == count, (source, records)
            for method, _, headers in records:
                assert method == 'CONNECT', records
                assert not {'authorization', 'x-origin', 'sec-websocket-protocol'} & {k.lower() for k in headers}, headers

        for endpoint in ('$ws_url', '$wss_url'):
            opening = f'zcurl ws open via -c "$ZCURL_TEST_CA" "{endpoint}/ws"'
            check(opening + '\nzcurl ws drop via', 1)
            check(opening + " --proxy ''\nzcurl ws drop via", 0)
            check(opening + ' --proxy "$ZCURL_TEST_PROXY"\nzcurl ws drop via', 0, NO_PROXY='*')
            check(opening + ' --proxy "$ZCURL_TEST_PROXY" --noproxy ""\nzcurl ws drop via', 1, NO_PROXY='*')
            check(opening + ' --noproxy "*"\nzcurl ws drop via', 0)

        check('''
            zcurl ws open direct --proxy '' "$ws_url/ws"
            zcurl ws drop direct
            zcurl ws open inherited "$ws_url/ws"
            zcurl ws drop inherited
            check "$http_proxy" "$ZCURL_TEST_PROXY"
            check "$NO_PROXY" ''
        ''', 1)
        server.require_auth = True
        authenticated = proxy_env['ZCURL_TEST_PROXY'].replace('http://', 'http://fixture:secret@')
        check(Path(__file__).with_name('websocket-proxy.zsh').read_text(), 4, AUTH_PROXY=authenticated)
        server.connect_subprotocol = 'fixture.v1'
        check('''
            for url in "$ws_url" "$wss_url"; do
                zcurl ws open required --proxy "$AUTH_PROXY" -c "$ZCURL_TEST_CA" \
                    --subprotocol fixture.v1 "$url/ws-protocol/match"
                zcurl ws drop required
            done
        ''', 2, AUTH_PROXY=authenticated)
        check('''
            for url in "$ws_url" "$wss_url"; do
                if zcurl ws open rejected --proxy "$AUTH_PROXY" -c "$ZCURL_TEST_CA" \
                    --subprotocol fixture.v1 "$url/ws-protocol/missing"; then exit 1; else check $? 8; fi
                check $zcurl_error_kind protocol
                check ${#zcurl_ws_handles} 0
            done
        ''', 2, AUTH_PROXY=authenticated)
        server.connect_subprotocol = None
        check('''
            if zcurl ws open denied "$ws_url/ws"; then exit 1; fi
            check $zcurl_error_kind transport
            check $zcurl_complete 0
            check ${#zcurl_ws_handles} 0
        ''', 1)
        server.require_auth = False
        for source in ('zcurl ws open bad "$wss_url/ws"',
                       'zcurl ws open bad -c "$ZCURL_TEST_CA" "${ZCURL_TEST_MISMATCH/https:/wss:}/ws"'):
            check(f'''if {source}; then exit 1; else check $? 60; fi
                      check $zcurl_complete 0
                      check ${{#zcurl_ws_handles}} 0''', 1)
        server.reject_connect = True
        check('''
            if zcurl ws open rejected "$ws_url/ws"; then exit 1; fi
            check $zcurl_error_kind transport
            check ${#zcurl_ws_handles} 0
        ''', 1)
        server.reject_connect = False
        with socket.socket() as refused:
            refused.bind(('127.0.0.1', 0))
            before = plain.request_count
            check('''
                if zcurl ws open refused -x "$REFUSED_PROXY" "$ws_url/ws"; then exit 1; else check $? 7; fi
                check $zcurl_error_kind transport
                check ${#zcurl_ws_handles} 0
            ''', 0, REFUSED_PROXY=f'http://127.0.0.1:{refused.getsockname()[1]}')
            assert plain.request_count == before

        before = plain.request_count
        check('''
            for flag in --proxy --noproxy; do
                if zcurl ws open bad "$flag"; then exit 1; else check $? 2; fi
                if zcurl ws open bad "$flag" '' "$flag" '' "$ws_url/ws"; then exit 1; else check $? 2; fi
                if zcurl ws open bad "$flag" $'bad\\0tail' "$ws_url/ws"; then exit 1; else check $? 2; fi
                for operation in send recv poll close info drop; do
                    if zcurl ws "$operation" bad "$flag" ''; then exit 1; else check $? 2; fi
                done
            done
            if zcurl ws open bad -x '' --proxy '' "$ws_url/ws"; then exit 1; else check $? 2; fi
            check ${#zcurl_ws_handles} 0
        ''', 0)
        assert plain.request_count == before
    print('PASS: WS/WSS proxy routing, CONNECT headers/authentication, binary frames, fragmentation, ping/pong, close and cleanup')


def test_https_proxy(env, plain, temp, run, setup):
    cert, key = temp / 'proxy trust[1].pem', temp / 'proxy-key.pem'
    subprocess.run([
        'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', str(key), '-out', str(cert), '-days', '1',
        '-subj', '/CN=proxy-fixture', '-addext', 'subjectAltName=DNS:localhost',
        '-addext', 'basicConstraints=critical,CA:TRUE',
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    setup += '''
        typeset ws_url=${ZCURL_TEST_HTTP/http:/ws:}
        typeset wss_url=${ZCURL_TEST_HTTPS/https:/wss:}
    '''
    with fixture(env, context) as (server, proxy_env):
        proxy_env['PROXY_CA'] = str(cert)

        def check(source, count, **overrides):
            before = len(server.records)
            output = run(dict(proxy_env, **overrides), setup + source + '\nprint HTTPS_PROXY_CASE_DONE\n')
            assert output.endswith('HTTPS_PROXY_CASE_DONE'), output
            assert len(server.records) == before + count, (source, server.records[before:])

        check('''
            zcurl --proxy-cacert "$PROXY_CA" "$ZCURL_TEST_HTTP/tiny"
            check "$zcurl_body" $'ok\\n'
            zcurl --proxy-cacert "$PROXY_CA" "$ZCURL_TEST_HTTP/tiny"
            check "$zcurl_body" $'ok\\n'
        ''', 2)
        # Trust of the proxy and the origin must be independent, including reset.
        before = plain.request_count
        for flags in ('', '--cacert "$PROXY_CA"', '--proxy-cacert "$ZCURL_TEST_CA"'):
            check(f'''if zcurl {flags} "$ZCURL_TEST_HTTP/tiny"; then exit 1; else check $? 60; fi
                      check $zcurl_complete 0''', 0)
        check('''
            if zcurl --proxy-cacert "$PROXY_CA" --proxy "${ZCURL_TEST_PROXY/localhost/127.0.0.1}" \
                "$ZCURL_TEST_HTTP/tiny"; then exit 1; else check $? 60; fi
        ''', 0)
        assert plain.request_count == before
        check('''
            zcurl --proxy-cacert "$PROXY_CA" "$ZCURL_TEST_HTTP/tiny"
            if zcurl "$ZCURL_TEST_HTTP/tiny"; then exit 1; else check $? 60; fi
        ''', 1)
        for flags in ('', '--cacert "$PROXY_CA"'):
            check(f'''if zcurl --proxy-cacert "$PROXY_CA" {flags} "$ZCURL_TEST_HTTPS/tiny"; then exit 1; else check $? 60; fi''', 1)
        check('''
            if zcurl --proxy-cacert "$PROXY_CA" -c "$ZCURL_TEST_CA" "$ZCURL_TEST_MISMATCH/tiny"; then exit 1; else check $? 60; fi
        ''', 1)
        check('''
            submit_local() {
                local trust=$PROXY_CA
                zcurl http submit via --proxy-cacert "$trust" -c "$ZCURL_TEST_CA" \
                    --data $'nested\\0tls\\n\\n' "$ZCURL_TEST_HTTPS/echo"
            }
            submit_local
            repeat 10; do typeset churn=${(pl:4096::x:)PROXY_CA}; done
            zcurl http submit untrusted -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/tiny"
            zcurl http wait via
            zcurl http collect via -r response
            check "$response[body]" $'nested\\0tls\\n\\n'
            zcurl http wait untrusted
            if zcurl http collect untrusted -r response; then exit 1; else check $? 60; fi
            check ${#zcurl_http_handles} 0
        ''', 1)
        # Origin authorization must stay inside the TLS tunnel in both APIs.
        server.require_auth = True
        authenticated = proxy_env['ZCURL_TEST_PROXY'].replace('https://', 'https://fixture:secret@')
        before = len(server.records)
        check('''
            zcurl --proxy "$AUTH_PROXY" --proxy-cacert "$PROXY_CA" -c "$ZCURL_TEST_CA" \
                -H 'Authorization: Bearer private' "$ZCURL_TEST_HTTPS/inspect"
            print -rn -- "$zcurl_body" > "$ZCURL_TEST_TMP/https-proxy-inspect.json"
        ''', 1, AUTH_PROXY=authenticated)
        origin = json.loads((temp / 'https-proxy-inspect.json').read_text())['headers']
        assert dict(origin)['Authorization'] == 'Bearer private'
        assert 'proxy-authorization' not in {k.lower() for k, _ in origin}
        # Reuse the frame/lifecycle script with proxy trust supplied on each open.
        source = Path(__file__).with_name('websocket-proxy.zsh').read_text()
        # Function wrapper keeps the handle position required by the native parser.
        wrapper = '''
            zcurl() {
                if [[ $1 == ws && ${2-} == open ]]; then
                    local handle=$3
                    shift 3
                    builtin zcurl ws open "$handle" --proxy-cacert "$PROXY_CA" "$@"
                else
                    builtin zcurl "$@"
                fi
            }
        '''
        check(wrapper + source, 4, AUTH_PROXY=authenticated)
        check('''
            for url in "$ws_url" "$wss_url"; do
                zcurl ws open required --proxy "$AUTH_PROXY" --proxy-cacert "$PROXY_CA" \
                    -c "$ZCURL_TEST_CA" --subprotocol fixture.v1 "$url/ws-protocol/match"
                zcurl ws drop required
            done
        ''', 2, AUTH_PROXY=authenticated)
        for method, _, headers in server.records[before:]:
            assert method == 'CONNECT'
            assert not {'authorization', 'x-origin', 'sec-websocket-protocol'} & {k.lower() for k in headers}
        server.require_auth = False
        for flags in ('', '--cacert "$PROXY_CA"'):
            check(f'''if zcurl ws open bad {flags} "$ws_url/ws"; then exit 1; else check $? 60; fi
                      check ${{#zcurl_ws_handles}} 0''', 0)
        check('''
            if zcurl ws open bad --proxy-cacert "$PROXY_CA" "$wss_url/ws"; then exit 1; else check $? 60; fi
            check ${#zcurl_ws_handles} 0
        ''', 1)
        before = plain.request_count
        check('''
            for prefix in '' 'http submit bad' 'ws open bad'; do
                target=$ZCURL_TEST_HTTP/tiny
                [[ $prefix == 'ws open bad' ]] && target=$ws_url/ws
                for value in '' $'bad\\0tail'; do
                    if zcurl ${=prefix} --proxy-cacert "$value" "$target"; then exit 1; else check $? 2; fi
                done
                if zcurl ${=prefix} --proxy-cacert; then exit 1; else check $? 2; fi
                if zcurl ${=prefix} --proxy-cacert a --proxy-cacert b "$target"; then exit 1; else check $? 2; fi
            done
        ''', 0)
        assert plain.request_count == before
    print('PASS: HTTPS proxy trust, independent origin verification, hostname rejection, reset, concurrent ownership and WS/WSS tunnels')
