# HTTP file output (0.5.0-dev)

Use `--output-fd FD` to write response bytes directly to an already-open writable
regular file. It works with synchronous HTTP and `zcurl http submit`.
It can be combined with [file uploads](file-input.md) using `--data-fd`.
The module does not open a filename, truncate a file, seek, or create a temporary
file; the caller chooses those actions through normal Zsh redirections.

```zsh
typeset -A response
integer output_fd
exec {output_fd}>response.bin || return
{
    zcurl --result response --fail --output-fd "$output_fd" \
        -- https://api.example.com/export
} always {
    exec {output_fd}>&-
}
```

For concurrent requests, the module owns a duplicate after successful submission,
so the caller can close its original descriptor immediately:

```zsh
typeset -A event response
integer output_fd
exec {output_fd}>response.bin || return
{
    zcurl http submit export --fail --output-fd "$output_fd" \
        -- https://api.example.com/export || return
} always {
    exec {output_fd}>&-
}
{
    zcurl http wait export -r event || return
    zcurl http collect export -r response
} always {
    # collect releases the handle even when the HTTP response is an error.
    if zcurl http info export; then
        zcurl http drop export
    fi
}
```

Both examples create/truncate `response.bin` when the shell opens it, before any
network request. Use `>>` for append, respect the caller's `noclobber` policy,
or open a temporary file and rename it after successful collection if atomic
replacement is needed. Failed requests do not roll back file writes.

## Descriptor ownership

The descriptor must be a separate unsigned decimal argument in 0..INT_MAX.
It must already refer to an open writable regular file. Read-only descriptors,
closed descriptors, pipes, sockets, terminals and devices are rejected with
status 2 before network I/O. Pipe and socket sinks need a separate backpressure
implementation; they are not supported by this option.

The module duplicates the descriptor, marks the duplicate close-on-exec, and
registers it with Zsh as private/internal. Ordinary `{fd}` closure or duplication
of the private descriptor is rejected; see [descriptor ownership](descriptors.md).
Closing or reusing the original descriptor
does not redirect an existing download. The module never closes the caller's
original descriptor. It releases its duplicate when the request finishes,
fails, times out, is cancelled/dropped, or is discarded by reset/unload.
For concurrent jobs this happens before collection; metadata remains available.

The duplicate shares its open-file offset and file status flags with the
original. Writes start at the current offset, or at the end if opened in append
mode. Do not seek, change flags, or write through another descriptor sharing
that open file description while the request runs. Concurrent requests targeting
the same file can interleave; use one destination per request unless that is
intentional.

Regular-file writes can block on the filesystem. The network poll timeout does
not bound disk I/O, and successful writes are not a durability guarantee. The
module does not call `fsync`; applications requiring durable storage must manage
that separately through their own file-handling code.

## Results, limits and failures

No body is accumulated in memory for file output. `body` is empty in both global
results and snapshots, while `bytes` counts bytes successfully written by this
request. Headers and all other HTTP metadata keep their existing semantics and
result shape. For pending concurrent jobs, `info` also exposes the number of
bytes already written. `collect` reports the result without rereading the file.

`--max-body` still limits raw response bytes: default 8 MiB, maximum 64 MiB.
The option bounds total output for this request, not the file's existing size.
A callback chunk that would cross the limit is rejected before any of that
chunk is written, matching the in-memory body-limit behavior. Earlier chunks
remain in the file. The error is status/code 23 with `error_kind=body-limit`.

Short writes are retried with the remaining bytes. A write error returns
status/code 23 and `error_kind=output`, with an OS diagnostic and the exact
successful byte count. A reported close error also makes an otherwise successful
transfer fail with 23. `complete=0` indicates failure, including an incomplete
file after cancellation, timeout, limit, or transport error. There is no rollback.

`--fail` still retains HTTP error responses: an HTTP 404 body is written to the
file, then the command (or `collect`) returns 22 with `code=0` and `complete=1`.
TLS verification failures before response data leave the file contents unchanged
by the module; the caller's earlier redirection may already have truncated it.
A failed result-array publication also leaves any file writes intact.

Concurrent admission does not reserve a scalar body buffer for file output.
The 128 MiB limit still reserves headers and copied request data/configuration;
the 32-handle limit also remains. Each live output adds one owned descriptor.
File payload storage is managed by the filesystem rather than the shell scalar.

## References

- [libcurl write-callback contract](https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html)
- [Duplicated descriptor offsets, status flags and close-on-exec](https://man7.org/linux/man-pages/man2/dup.2.html)
- [Short writes, errors and file offsets](https://man7.org/linux/man-pages/man2/write.2.html)
