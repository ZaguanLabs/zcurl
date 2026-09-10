# Handle discovery (0.9.0-dev)

The native module exposes read-only special indexed arrays:

| Parameter | Contents |
| --- | --- |
| `zcurl_http_handles` | All retained concurrent HTTP request names, in submission order |
| `zcurl_ws_handles` | All retained WebSocket names, in successful open order |
| `zcurl_http_sessions` | Named HTTP sessions, in creation order; see [session lifecycle](sessions.md) |

Each expansion reads the current registry without invoking `zcurl`, touching
the network, processing deadlines, or changing transfer results. The arrays
are independent of result snapshots and contain names only, with no status
filter. The namespaces remain separate, so the same name can appear in both.
Synchronous requests have no job handle; their named session registry is separate.

HTTP entries remain after completion or cancellation until collection or drop
releases them. WebSocket entries remain after closure or error until drop.
Failed submissions/opens add no entry. Reusing a released name adds it at the
end. Global reset empties all three arrays; unloading removes the parameters entirely.

Copy an array directly in the owning shell when it must survive later changes:

```zsh
typeset -a requests=( "${zcurl_http_handles[@]}" )
typeset -a channels=( "${zcurl_ws_handles[@]}" )

# Release all retained HTTP requests when this shell owns the whole registry.
for request in "${requests[@]}"; do
    zcurl http drop "$request"
done
```

Copies survive reset and unload, but do not keep handles alive. A stored name
can become stale or be reused; scripts sharing the module should track their
own accepted names for cleanup. Reading the array makes no ownership claim.

The parameters cannot be assigned or unset normally. They are separate module
features; disabling discovery does not release handles, and reenabling it
exposes the current registry:

```zsh
zmodload -F zcurl -p:zcurl_http_handles
zmodload -F zcurl +p:zcurl_http_handles
```

An inherited child shell sees empty discovery arrays. It cannot operate on
the parent's connections. Use direct array expansion, rather than a command
substitution or subshell, to discover handles in the owner.

[Completion](completion.md) reads these arrays for existing-handle arguments.
It offers all retained names, including terminal records. Selecting one does
not imply that every operation is valid in its current state. New-name
positions (`http submit` and `ws open`) remain free text. When a discovery
feature is absent, completion still describes arguments and options.
