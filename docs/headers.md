# Response header lookup (0.7.0-dev)

```zsh
zcurl headers FIELD --from RAW --result ARRAY [--trailers]
```

This command reads a saved HTTP header transcript and replaces a caller-owned
indexed array with the matching field values. It performs no network I/O and
preserves all `zcurl_*` parameters, including any transfer error, HTTP handle,
and event. The raw transcript and response snapshot remain unchanged.

```zsh
typeset -A response
typeset -a cookies trailers
zcurl --result response -- https://api.example.com/data || return
zcurl headers Set-Cookie --from "$response[headers]" --result cookies
zcurl headers Digest --from "$response[headers]" --trailers --result trailers
```

An explicit `--from` makes the same lookup work with synchronous responses,
collected concurrent responses, and snapshots retained after reset or module
reload. The module must be loaded to run the command; published arrays survive
unload. The field name comes first; options may follow in any order, once each.
`-r` is an alias for `--result`.

## Values and response selection

Field-name comparison uses ASCII case-insensitive matching. Each occurrence
becomes one array element, in wire order. Duplicate and empty values are
preserved. Commas are not split or used to combine occurrences; this keeps
`Set-Cookie` and other fields with field-specific syntax intact.

Outer spaces and tabs are removed from each value. Legacy continuation lines
are unfolded with a separating space, then outer whitespace is trimmed.
Internal value whitespace and bytes above ASCII are retained. Values are data:
the command never evaluates shell syntax, decodes quoted strings, or interprets
the semantics of a particular field.

A new HTTP status line starts a new response block and discards matches from
the previous block. Thus proxy CONNECT, authentication, and informational
blocks do not leak into a later response. Only the last block is selected;
1xx fields are excluded, except for the terminal 101 protocol upgrade response.
If the transcript contains only a 100 or 103 response, the result is empty.

Ordinary lookup stops selecting fields at the blank line ending the last
response's header section. `--trailers` selects only fields following that
separator. Header and trailer values are never merged. A completed trailer
section can have a final blank line, but libcurl's callback transcript need
not include it.

This is a view of captured lines, not proof of a complete or successful
transfer. A partial transfer can still expose complete header lines, including
a header section whose terminating blank line has not arrived. Inspect the
response's `complete`, `code` and `http_status` separately.

## Results and errors

Success returns 0 and replaces the entire destination array. A missing field
also succeeds with an empty array. An explicitly empty field yields one empty
element, distinguishable by the array's length:

```zsh
typeset -a etags
if zcurl headers ETag --from "$response[headers]" -r etags; then
    if (( ${#etags} )); then
        print -r -- "First ETag: $etags[1]"
    fi
fi
```

Targets must be ordinary writable indexed arrays with a plain ASCII identifier.
Subscripts, scalars, associative arrays, special/tied/readonly arrays and
attributes that convert values or remove duplicates are rejected. Dynamic
scope is supported, and the command does not change the caller's shell options.

Bad options, targets or malformed input return 2 with a diagnostic on stderr;
failure to allocate parsing storage returns 27. Validation finishes before any
array assignment, so those failures preserve the destination. Unlike transfer
commands, lookup errors do not overwrite `zcurl_status` or `zcurl_error`.
Use the command's exit status to check lookup success.

Input is bounded to 256 KiB, matching the response-header capture limit. Empty
input is accepted as an empty result. Nonempty input must start with an HTTP
status line. CRLF and LF line endings are accepted; every captured line must
have a terminator. Status lines support the HTTP/1.x, HTTP/2 and HTTP/3 forms
emitted by libcurl. Invalid field names, orphan continuation lines, embedded
NUL, bare CR and other control bytes (except horizontal tab) are rejected.
Malformed lines in an earlier or unselected section also fail the lookup.

The parser uses bounded linear storage and compacts folded values in one pass.
It does not retain hidden header state or depend on a live libcurl handle.

## References

- [HTTP field names, values and duplicate field ordering (RFC 9110)](https://www.rfc-editor.org/rfc/rfc9110.html#section-5)
- [libcurl header callbacks, response boundaries and trailers](https://curl.se/libcurl/c/CURLOPT_HEADERFUNCTION.html)
- [Zsh arrays and parameter attributes](https://zsh.sourceforge.io/Doc/Release/Parameters.html)
