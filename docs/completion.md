# Native Zsh completion (0.8.0-dev)

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
- Operation-specific HTTP and WebSocket options. Handle arguments come before
  options, matching the module's grammar; `http poll` takes no handle.
- Standard HTTP methods and WebSocket frame types. With `--head`, method
  suggestions are limited to HEAD; a request body excludes HEAD suggestions.
- Mutual exclusions among `--head`, literal bodies and file uploads. Repeated
  `--header` remains available. Short and long aliases suppress each other.
- CA-file paths using standard `_files` quoting, including spaces and shell
  metacharacters. HTTP URL positions offer `http://` and `https://`; WebSocket
  URL positions offer `ws://` and `wss://`.
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

Numeric limits, payloads, raw header transcripts, handles and descriptor numbers
have argument descriptions rather than generated values. Completion does not
enumerate live module handles or private descriptors. URL completion offers
scheme prefixes, without generating hosts or paths. Unlisted custom HTTP
methods and header names remain valid when accepted by the builtin; completion
is guidance, while the native parser remains authoritative.

## Validation

`make check` parses the completion with `zsh -dfn`. `make test` runs an isolated
Zsh PTY with real `compinit` and ZLE completion. It checks inserted command
buffers for operation-specific flags, method/frame types, option exclusions,
result-array filtering, aliases, case-insensitive matcher styles, `--`,
mid-word insertion and filename escaping. The test also completes after module
unload. A command-call guard and server request count check that completion
does not invoke `zcurl` or perform HTTP I/O; transfer results remain intact.

These PTY checks use installed Zsh 5.9.2. Framework-specific startup ordering,
other Zsh builds and arbitrary third-party completers remain untested.
