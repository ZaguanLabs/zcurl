# HTTP proxy routing (0.12.0-dev)

Synchronous HTTP and `zcurl http submit` accept per-request routing controls:

| Option | Behavior |
| --- | --- |
| `-x URL`, `--proxy URL` | Choose a proxy; `''` disables proxy use even when the environment specifies one |
| `--noproxy HOSTS` | Replace the bypass list with comma-separated hosts/domains/IP ranges; `'*'` bypasses every host and `''` bypasses none |

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

Each accepted request retains copies of explicit proxy/bypass strings. The
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

The tested proxy is an HTTP proxy: HTTP requests use forwarding, and HTTPS
requests use CONNECT followed by origin TLS. Certificate and hostname
verification remain enabled; `--cacert` supplies trust for the origin server.
Request headers supplied through `--header` are not added to CONNECT. For a
plain HTTP forwarded request, those headers necessarily pass through the proxy.
This uses libcurl's [separate header policy](https://curl.se/libcurl/c/CURLOPT_HEADEROPT.html).

Proxy URLs may contain credentials using libcurl's URL syntax. The fixture tests
Basic proxy authentication and verifies that proxy authorization is absent from
the tunneled origin request. There is no separate proxy-header or authentication
method option. Per-request routing does not provide named-session isolation:
connection and authentication caches remain managed by libcurl's shared pools.

Only HTTP proxy forwarding and HTTPS-over-HTTP CONNECT are validated here.
HTTPS proxy servers, SOCKS proxies, other authentication methods and platform
combinations need separate integration tests. `--cacert` does not configure
trust for a TLS connection to an HTTPS proxy. These new options are HTTP-only;
WebSocket operations retain their existing environment-based proxy behavior.

## Validation

The loopback proxy only accepts the test fixture's origin addresses. Tests
observe proxy requests and origin payloads independently, covering environment
defaults, explicit direct routing, bypass wildcards/hosts/CIDR, empty-list
overrides, settings and credential reset, persistent connection reuse, mixed
direct/proxied concurrent dependencies, TLS failures, CONNECT rejection, binary
file output and parser failures before I/O. No external proxy is contacted.
