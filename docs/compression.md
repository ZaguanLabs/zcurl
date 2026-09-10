# HTTP response compression (0.10.0-dev)

Use `--compressed` to negotiate HTTP content compression and decode the response
body before publishing it or writing it to `--output-fd`. The flag works with
synchronous HTTP and `zcurl http submit`, including HEAD and file uploads:

```zsh
typeset -A response
zcurl --compressed --fail -r response -- https://api.example.com/items

zcurl http submit items --compressed --max-body 1048576 \
    -- https://api.example.com/items
zcurl http wait items
zcurl http collect items -r response
```

The option advertises every content encoding supported by the linked libcurl.
Available decoders depend on that library's build. Gzip and deflate are tested
here; Brotli and Zstandard are not covered by this module's fixtures. A server
can also return an uncompressed body, which passes through normally. This uses
[libcurl's automatic content decoding](https://curl.se/libcurl/c/CURLOPT_ACCEPT_ENCODING.html).

Without `--compressed`, zcurl neither generates `Accept-Encoding` nor decodes
content compression. A server's compressed bytes are returned as received.
This is per-request behavior: subsequent synchronous calls and other concurrent
jobs do not inherit the flag. HTTP transfer framing, such as chunked encoding,
continues to be handled by libcurl independently of content compression.

An explicit `-H 'Accept-Encoding: gzip'` overrides the negotiated request header;
`-H 'Accept-Encoding:'` suppresses it. Neither changes the flag's decoding policy.
A literal request header alone does not enable decoding. WebSocket message
compression is outside this HTTP option's scope.

## Results and limits

With `--compressed`, `body` contains decoded bytes, preserving NUL and trailing
newlines. File output receives the same decoded bytes and leaves `body` empty.
`bytes`, concurrent `info` byte counts and `--max-body` all measure bytes stored
or written after decoding. Existing result-array shapes remain unchanged.

The response header transcript is preserved exactly as delivered by libcurl.
`Content-Encoding` still names the encoding, and `Content-Length` describes the
encoded entity. Neither is rewritten to describe the decoded body. Do not use
that length as the expected decoded byte count or decode the body a second time.

The default 8 MiB body limit and 64 MiB maximum apply after expansion. A decoded
callback chunk that would exceed the limit is rejected before storage or file
output; earlier bytes remain available. Limit failure returns status/code 23
with `error_kind=body-limit` and `complete=0`. The limit bounds retained body
bytes, not libcurl's decoder workspace or CPU time.

Unsupported encodings and malformed compressed streams are reported as libcurl
transport failures. The tested unsupported/gzip-corruption cases return 61 with
`error_kind=transport` and `complete=0`; other damaged/truncated streams can
produce other transport outcomes. Retained bytes and files are not rolled back.
Successful decoding alone does not establish application-level data integrity.

`--fail` still retains decoded HTTP error bodies and returns 22 after a completed
HTTP 400-or-higher response. HEAD retains headers with an empty body. Upload
bytes are unaffected: the flag applies only to response content.

## Validation

Loopback HTTP and verified HTTPS fixtures independently generate gzip and zlib
deflate payloads. Tests cover all 256 byte values and trailing newlines, scalar
and file output, mixed concurrent decoding settings, file uploads, literal
header overrides, HEAD, HTTP errors, corrupt/unknown encodings, decoder failure
recovery, the inclusive scalar limit and a small gzip payload expanding beyond
the file-output limit. Python independently checks output files. Request counts
also check that duplicate flags and non-HTTP uses fail before network I/O.
