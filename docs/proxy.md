# HTTP and WebSocket proxy routing (0.14.0-dev)

Synchronous HTTP, `zcurl http submit` and `zcurl ws open` accept routing controls:

| Option | Behavior |
| --- | --- |
| `-x URL`, `--proxy URL` | Choose a proxy; `''` disables proxy use even when the environment specifies one |
| `--noproxy HOSTS` | Replace the bypass list with comma-separated hosts/domains/IP ranges; `'*'` bypasses every host and `''` bypasses none |
| `--proxy-cacert FILE` | PEM CA bundle for an HTTPS proxy, independent of the origin's `--cacert` |

```zsh
typeset -A response
# Force this request through the selected proxy, overriding environment bypasses.
zcurl --proxy http://127.0.0.1:8080 --noproxy '' -r response \
    -- https://api.example.com/items

# Explicit direct routing, without changing http_proxy/https_proxy/NO_PROXY.
zcurl --proxy '' -r response -- https://api.example.com/items
```

The two options are independent. Setting `--proxy` alone still respects the
environment's bypass list. Setting `--noproxy` alone uses the environment's
proxy choice. Neither option changes any shell environment variable. Omitted
options retain libcurl's environment behavior; specify both when a concurrent
request needs a fixed routing policy independent of later environment changes.

Values are separate literal shell words, including empty strings. Duplicate
options and embedded NUL are rejected. Proxy parsing and bypass matching follow
libcurl, including domain matching and IP CIDR entries. Specify a scheme and
port explicitly. See [proxy selection](https://curl.se/libcurl/c/CURLOPT_PROXY.html)
and [bypass matching](https://curl.se/libcurl/c/CURLOPT_NOPROXY.html).

## Concurrent requests and results

```zsh
zcurl http submit proxied --proxy http://127.0.0.1:8080 --noproxy '' \
    -- https://api.example.com/items
zcurl http submit direct --proxy '' -- https://api.example.com/status
zcurl http wait-any proxied direct -r response
# Collect response[handle], then wait for and collect the remaining request.
```

Each accepted request retains copies of explicit proxy/bypass strings and proxy CA paths. The
strings count toward the existing 128 MiB concurrent storage reservation.
Submitting-function locals can disappear before polling. Subsequent synchronous
requests reset these options; concurrent jobs keep their own settings.

The existing result shapes, transfer deadlines, body limits and file input/output
semantics are unchanged. An unreachable proxy fails the request; the module
does not retry directly. An HTTP forward proxy's error response follows ordinary
HTTP status/`--fail` behavior. A refused CONNECT tunnel is a transport failure.
Raw headers can contain a proxy CONNECT response before the origin response;
`zcurl headers` continues to select the final response block.

## HTTPS and authentication

Tests cover HTTP and HTTPS proxies: HTTP requests use forwarding, and HTTPS
requests use CONNECT followed by origin TLS. Certificate and hostname
verification remain enabled; `--cacert` supplies trust for the origin server.
Request headers supplied through `--header` are not added to CONNECT. For a
plain HTTP forwarded request, those headers necessarily pass through the proxy.
This uses libcurl's [separate header policy](https://curl.se/libcurl/c/CURLOPT_HEADEROPT.html).

Proxy URLs may contain credentials using libcurl's URL syntax. The fixture tests
Basic proxy authentication and verifies that proxy authorization is absent from
the tunneled origin request. There is no separate proxy-header or authentication
method option. Per-request routing alone does not separate connection and
authentication caches. Synchronous requests and concurrent submissions can select independent pools
with [named sessions](sessions.md). Each session has separate synchronous and
concurrent pools.

For an HTTPS proxy with a private CA, set `--proxy-cacert FILE`:

```zsh
zcurl --proxy https://proxy.example.com:8443 --noproxy '' \
    --proxy-cacert /path/to/proxy-ca.pem --cacert /path/to/origin-ca.pem \
    -r response -- https://api.example.com/items
```

Proxy certificate and hostname checks remain enabled independently of origin
checks. `--cacert` does not grant trust to the proxy; `--proxy-cacert` does not
grant trust to the origin. When omitted, proxy CA configuration uses libcurl's
default trust bundle. The option also works with an environment-selected HTTPS
proxy. It does not choose a proxy or affect a direct request or plain HTTP proxy.
See libcurl's [proxy CA option](https://curl.se/libcurl/c/CURLOPT_PROXY_CAINFO.html).

The path must be a nonempty literal word; duplicate options and embedded NUL are
rejected. Libcurl copies the path, but reads the file during TLS setup: keep the
file available until the transfer or open handshake completes. Concurrent requests
count the copied path toward their storage reservation. Subsequent synchronous
requests reset the setting, and concurrent jobs and WS handles retain their own
configuration. Existing result fields report TLS failures as transport errors.

## WebSocket connections

```zsh
zcurl ws open events --proxy http://127.0.0.1:8080 --noproxy '' \
    -r response -- wss://api.example.com/events
# Queue sends and poll events normally; routing is fixed at open.
zcurl ws send events --data hello
zcurl ws poll events --timeout 100 -r response
```

Both `ws://` and `wss://` use CONNECT through HTTP and HTTPS proxies in the tested
libcurl build. The proxy must permit tunnels to the origin port, including
plain WS ports. WSS performs origin TLS inside the tunnel; plain WS remains
unencrypted. Handshake headers are excluded from the CONNECT request, but a
plain WS tunnel still exposes its traffic to the proxy.
For an HTTPS proxy, `open` accepts `--proxy-cacert FILE` to verify the outer TLS
connection. WSS still uses `--cacert` for the origin inside that connection.

`open` accepts the same empty-string, bypass and environment rules as HTTP.
Explicit strings are copied by libcurl and may come from function locals.
Each WebSocket has its own connection; direct and proxied handles can coexist.
Other WebSocket operations do not accept routing options. Failed opens retain
no handle, and proxy failures do not trigger a direct retry. Drop, reset and
module unload release tunnels through the ordinary WebSocket cleanup path.

## Scope

HTTP forwarding and HTTPS/WS/WSS CONNECT through HTTP and HTTPS proxies are
validated here with libcurl's OpenSSL backend. SOCKS proxies, other TLS backends,
other authentication methods and platform combinations need separate integration
tests. There is no proxy client-certificate, CA-directory or verification-disable option.

## Validation

The loopback proxy only accepts the test fixture's origin addresses. Tests
observe proxy requests and origin payloads independently, covering environment
defaults, explicit direct routing, bypass wildcards/hosts/CIDR, empty-list
overrides, settings and credential reset, persistent connection reuse, mixed
direct/proxied concurrent dependencies, TLS failures, CONNECT rejection, binary
file output and parser failures before I/O. WS/WSS tests also cover mixed
direct/proxied handles, binary frames, fragmented UTF-8, interleaved ping/pong,
graceful close, authenticated tunnels and reset/unload cleanup. Origin handshake
authentication is checked independently of proxy authentication, with no proxy
credentials in the origin request. No external proxy is contacted.

The HTTPS proxy has its own generated certificate. Tests reject untrusted proxy
certificates and incorrect proxy hostnames, reject origin certificates trusted
only by the proxy bundle, verify settings reset and concurrent path ownership,
and exchange binary HTTP bodies and WS/WSS frames through nested TLS connections.
