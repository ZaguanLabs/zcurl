"""Loopback-only HTTP forwarding and CONNECT proxy, independent of libcurl."""
import base64
import contextlib
import http.client
import http.server
import json
import select
import socket
import threading
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
            self.end_headers()
            self.close_connection = True
            self.connection.settimeout(5)
            while not self.server.stopping.is_set():
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
def fixture(env):
    targets = [urlsplit(env[key]) for key in ('ZCURL_TEST_HTTP', 'ZCURL_TEST_HTTPS', 'ZCURL_TEST_MISMATCH')]
    server = Proxy({(target.hostname, target.port) for target in targets})
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}'
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
        assert not {'authorization', 'x-origin'} & {k.lower() for k in headers}
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
            if zcurl ws open invalid --proxy '' "${ZCURL_TEST_HTTP/http:/ws:}/ws"; then exit 1; else check $? 2; fi
        ''', 0)
        assert plain.request_count == before
        assert not server.errors, server.errors
    print('PASS: HTTP proxy routing, bypass/reset, concurrent ownership, CONNECT TLS, credentials and binary output')
