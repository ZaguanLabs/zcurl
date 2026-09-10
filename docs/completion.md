# Native Zsh completion (0.19.0-dev)

`completions/_zcurl` provides optional compsys completion for the module's CLI.
It describes arguments without invoking `zcurl`, opening connections, driving
pending requests, or changing any `zcurl_*` result. The shared library need not
be built or loaded to use completion.

## Setup

Add the directory to `fpath` before the existing `compinit` call in your Zsh
startup configuration. Replace the example path with this checkout's location:

```zsh
fpath=( /absolute/path/to/zcurl/completions $fpath )
autoload -Uz compinit
compinit
```

If a framework initializes completion, put the `fpath` change before that
framework's completion setup. Keep its normal `compaudit` checks. The module's
`zcurl.zsh` loader does not initialize compsys, alter `fpath`, bind keys or change
completion styles.

For an already-initialized interactive shell, register the function directly:

```zsh
fpath=( /absolute/path/to/zcurl/completions $fpath )
autoload -Uz _zcurl
compdef _zcurl zcurl
```

Completion remains registered if the native module is unloaded. To remove it
from the current shell, use `compdef -d zcurl` and remove the directory from
your startup configuration.

## What completion offers

- Top-level `http`, `ws`, `headers`, control flags and synchronous HTTP options.
- Operation-specific HTTP and WebSocket options. Single-handle operations take
  the handle before options; `http poll` takes no handle. `http wait-any` accepts
  multiple handles interspersed with timeout/result options.
- Session create/reset/drop/configure operations and synchronous and concurrent `--session` selection.
  Existing names come from `zcurl_http_sessions`; create positions remain free
  text. Missing discovery features fall back to a name description. Configure
  offers its three numeric settings and the mutually exclusive `--defaults`.
- Existing handles from the native read-only discovery arrays, with separate
  HTTP and WebSocket namespaces. These include terminal records until released.
  New-name positions stay free text. Discovery is optional; completion still
  works when the module or either array feature is absent.
- Standard HTTP methods and WebSocket frame types. With `--head`, method
  suggestions are limited to HEAD; a request body excludes HEAD suggestions.
- `--subprotocol` only on `ws open`, with duplicate suppression and a literal
  token argument. Completion does not guess application protocols.
- Mutual exclusions among `--head`, literal bodies and file uploads. Repeated
  `--header` remains available. Short and long aliases suppress each other.
- `--compressed` for synchronous HTTP and `http submit`, with duplicate
  suggestions suppressed and no offer in WebSocket or other HTTP operations.
- Proxy/bypass options for HTTP requests and `ws open`, plus proxy URL scheme
  prefixes. Bypass lists remain literal input; completion does not discover proxies or look up hosts.
- CA-file paths using standard `_files` quoting, including spaces and shell
  metacharacters, for both `--cacert` and `--proxy-cacert`. HTTP URL positions
  offer `http://` and `https://`; WebSocket URL positions offer `ws://` and `wss://`.
- Ordinary global associative arrays for transfer snapshots, and indexed arrays
  for header values. Readonly, special/tied and converting arrays are filtered;
  indexed arrays with the unique attribute are also excluded. Parameter names
  must satisfy the native API's ASCII identifier grammar.
- Common response field names and the header lookup options.

Options may follow an HTTP URL, and option suggestions stop at `--`. Unsupported
attached arguments such as `--request=GET` and `-XGET` are not offered.
Completion uses the user's matcher, menu, grouping and quoting behavior.
Mid-word insertion follows Zsh's `COMPLETE_IN_WORD` option. Ordinary aliases
such as `alias zc='noglob zcurl'` are supported by compsys.

Numeric limits, payloads, raw header transcripts, new handles and descriptor
numbers have argument descriptions rather than generated values. Completion
does not enumerate private descriptors. URL completion offers
scheme prefixes, without generating hosts or paths. Unlisted custom HTTP
methods and header names remain valid when accepted by the builtin; completion
is guidance, while the native parser remains authoritative.

## Validation

`make check` parses the completion with `zsh -dfn`. `make test` runs an isolated
Zsh PTY with real `compinit` and ZLE completion. It checks inserted command
buffers for operation-specific flags, method/frame types, option exclusions,
result-array filtering, aliases, case-insensitive matcher styles, `--`,
mid-word insertion and filename escaping. It checks live handles, namespace
separation, drop, discovery-feature toggling, and completion after module unload.
A command-call guard and server request count check that completion
does not invoke `zcurl` or perform HTTP I/O; transfer results remain intact.

These PTY checks use installed Zsh 5.9.2. Framework-specific startup ordering,
other Zsh builds and arbitrary third-party completers remain untested.
