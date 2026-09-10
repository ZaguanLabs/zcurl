# Private descriptor ownership (0.8.1-dev)

The module owns its HTTP/HTTPS and WS/WSS connection sockets and duplicates
of caller-provided upload/download descriptors. These private descriptors must
remain valid until their owning transfer or connection releases them.

Before 0.8.1-dev, libcurl could allocate a persistent connection socket in Zsh's
single-digit redirection range. Closing that number through shell syntax could
invalidate the cached connection. File duplicates used `FDT_MODULE`, whose
documented close protection did not match the tested Zsh 5.9.2 implementation:
`exec {fd}>&-` could close them too.

## Registration and lifetime

Connection sockets now use libcurl open/close callbacks. New sockets below 10
are moved above the single-digit range. Sockets already at or above 10 are kept
in place, avoiding an unnecessary duplicate and descriptor slot. Every owned
connection socket is marked close-on-exec and registered as `FDT_INTERNAL`.

The same internal registration is used for the private duplicates retained by
`--data-fd` and `--output-fd`. On this Zsh build it rejects ordinary `{fd}` close
syntax and redirection that duplicates a private descriptor. The caller's
original file descriptors remain caller-owned: they can still be closed after
successful submission, while the request uses its retained duplicates.

The socket close callback uses `zclose` to release the descriptor and clear
Zsh's descriptor-table entry. Connection callbacks contain no request-specific
userdata: a cached connection can outlive the easy handle that created it.
This matters when an HTTP job is collected but its connection remains reusable
in the concurrent pool.

The existing lifetimes remain in effect. File duplicates close when transfers
finish, fail or are cancelled/dropped. Idle HTTP sockets can remain in their
connection caches until eviction, reset or unload. WebSocket sockets close when
the connection terminates or is dropped. Reset and module unload release the
remaining connections and retained file descriptors.

Close-on-exec and Zsh's internal registration keep these descriptors out of
executed children. The existing owning-PID guard still rejects use of inherited
module handles from a subshell; this change does not enable forked HTTP workers.

## Scope

This is descriptor ownership within Zsh, not process isolation. Other native
code can bypass the shell's descriptor table. Libcurl's auxiliary resolver and
wakeup descriptors are managed internally and are outside its connection
open/close callbacks; this change does not claim protection for all process
descriptors. Use dynamically allocated `{fd}` descriptors for application files
and avoid claiming or closing unknown numeric descriptors.

Validation targets the installed Zsh 5.9.2 and libcurl 8.21.0 build. Different
Zsh descriptor-table behavior or libcurl backends require separate validation.

## Regression coverage

The loopback fixture keeps six connection sockets alive across synchronous and
concurrent HTTP/HTTPS and WS/WSS. It rejects close and duplication attempts on
each, then verifies HTTP connection reuse and WebSocket binary round trips.
Linux `/proc` checks verify actual close-on-exec flags and that socket identities
are absent in an executed child.

File-upload and file-output duplicates are subjected to the same close attempts,
then their originals are closed and an exact binary file-to-file transfer must
still succeed. Reset, drop and repeated unload/reload check socket release,
including cached connections whose original easy handles have been freed.
Another case starts with all single-digit descriptors occupied by the caller.

## References

- [libcurl connection socket creation callback](https://curl.se/libcurl/c/CURLOPT_OPENSOCKETFUNCTION.html)
- [Socket close callbacks and connection-cache lifetime](https://curl.se/libcurl/c/CURLOPT_CLOSESOCKETFUNCTION.html)
- Zsh 5.9.2 source: `Src/exec.c` (`REDIR_CLOSE`, `REDIR_MERGEIN/OUT`),
  `Src/utils.c` (`addmodulefd`, `zclose`), and `Src/zsh.h` (`FDT_*`). Behavior
  above was checked against both that source and the running shell.
