# HTTP file uploads (0.6.0-dev)

Use `--data-fd FD` to upload bytes from an already-open readable regular file.
It works with synchronous HTTP and `zcurl http submit`, including requests that
also use `--output-fd`. The module never opens a filename or loads the whole
source file into memory.

```zsh
typeset -A event response
integer input_fd
exec {input_fd}<payload.bin || return
{
    zcurl http submit upload --request PUT --data-fd "$input_fd" \
        --header 'Content-Type: application/octet-stream' \
        -- https://api.example.com/object || return
} always {
    exec {input_fd}<&-
}
{
    zcurl http wait upload -r event || return
    zcurl http collect upload -r response
} always {
    if zcurl http info upload; then
        zcurl http drop upload
    fi
}
```

Like `--data`, this sends a raw request body and implies POST unless an explicit
method is supplied. Content types are not inferred; add the appropriate header.
`--data` and `--data-fd` are mutually exclusive. Neither is allowed with HEAD.
This is a whole request body, not a multipart form or a filename convention for
`--data`.

## Captured range and ownership

The descriptor must be a separate unsigned decimal argument in 0..INT_MAX and
must already refer to a readable regular file. Read-only and read/write files
are accepted. Closed or write-only descriptors, pipes, sockets, directories,
terminals and devices are rejected with status 2 before network I/O.

The module captures the current offset and remaining file length when the
synchronous request is accepted or the concurrent request is submitted. That
length becomes the upload size. An offset at or beyond EOF sends an empty body.
An unrepresentable upload length is rejected before network I/O.

Each request owns a close-on-exec duplicate registered with Zsh as private/internal.
Ordinary `{fd}` closure or duplication of that private descriptor is rejected;
see [descriptor ownership](descriptors.md).
The original can be closed or reused immediately after submission. The duplicate
is released at transfer completion, failure, timeout or cancellation, and on
drop, reset or unload. Concurrent completion releases it before collection;
collecting only retrieves the retained result.

Reads use `pread` with a per-request cursor. They never change the caller's file
offset. Later seeks through the original descriptor do not change a submitted
upload; two submissions using the same descriptor can capture different ranges
and progress independently. Libcurl can rewind within a captured range for
retries without seeking the caller's descriptor.

Only the range is captured, not the contents. Keep the source contents and file
status flags stable until the request finishes. Appended bytes beyond the
captured range are ignored; changes within the range may change the uploaded
data. Truncation that causes premature EOF fails the request. Do not use the
source as the response output file. Filesystem reads can block, so network poll
deadlines do not bound disk I/O.

## Limits and results

Uploads read incrementally into libcurl's buffers. The file size does not count
against the concurrent pool's 128 MiB storage reservation. Its usual reservations
for response buffers, headers and copied configuration still apply, as does the
32-handle limit. Each live file upload adds one owned descriptor. `--max-body`
limits the response, not the request file.

The HTTP result shape is unchanged. `body` and `bytes` describe the response;
there is no uploaded-byte field. With file output, `body` is empty and `bytes`
counts response bytes written. HTTP status, TLS verification, `--fail` and
explicit concurrent scheduling retain their ordinary semantics.

Short reads continue from the next byte. Interrupted reads are retried. A read
error or premature EOF aborts the callback and yields libcurl code/status 42,
`error_kind=input`, and `complete=0`. The diagnostic distinguishes an OS read
error from a file ending before its captured length. This differs from explicit
HTTP cancellation, which also uses 42 but reports `error_kind=cancelled`.
Failure to duplicate a validated descriptor returns status 2 with
`error_kind=input` before a transfer starts.

An upload error can happen after the server has received part of a request.
Local failure or cancellation does not roll back server-side effects. A server
can also respond early without consuming the whole body; a successful HTTP
transfer is not a guarantee that the application stored every input byte.

## References

- [libcurl read callback and explicit abort semantics](https://curl.se/libcurl/c/CURLOPT_READFUNCTION.html)
- [Streaming POST bodies and known lengths](https://curl.se/libcurl/c/CURLOPT_POST.html)
- [Rewinding an upload stream](https://curl.se/libcurl/c/CURLOPT_SEEKFUNCTION.html)
- [Positioned reads without changing the file offset](https://man7.org/linux/man-pages/man2/pread.2.html)
