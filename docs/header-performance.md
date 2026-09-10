# Request-header construction (0.26.0-dev)

Repeated `-H` / `--header` arguments now build the request list in linear time
with respect to header count and total text length. The command syntax, duplicate
ordering, validation and 256 KiB aggregate limit are unchanged. Synchronous HTTP,
concurrent HTTP submissions and WebSocket opens share this builder.

Previously, each append passed the list's head to `curl_slist_append`, walking
all preceding nodes. Constructing N headers therefore required quadratic list
traversal. The request now retains both the head and the last node. Appending
through the last node gives libcurl a one-node sublist; the original head still
owns the complete list. Only libcurl allocates and links nodes, following its
[list ownership contract](https://curl.se/libcurl/c/curl_slist_append.html).

Failed appends preserve the existing head/tail and byte count. HTTP submissions
and WebSocket opens transfer the complete list to the retained handle and clear
both builder pointers. Validation failures, collection, drop, reset and unload
release lists through `curl_slist_free_all` as before.

## Reproduce the measurement

```sh
make benchmark-headers
# Compare another compatible module build without replacing the current one:
zsh -df scripts/benchmark-headers.zsh /path/to/other/module-directory
```

The script constructs 4,096 through 65,536 repetitions of `-H 'a:'`, then times
three calls per size. Each call deliberately fails result-target validation
after parsing all headers. No URL is supplied and no transfer is attempted.
65,536 specifications, charged four bytes each including line endings, exactly
fill the 256 KiB header budget. Output gives median, minimum and maximum seconds.

Timing includes shell argument expansion, native parsing, string allocation and
list cleanup. Array construction and result checks are outside the timed region.
This measures parser cost, not HTTP throughput, network latency or libcurl's
subsequent processing of outgoing headers. Run it without concurrent sanitizer
or benchmark workloads; shared-host scheduling and allocation affect the result.

## Local result

Three-sample medians on the existing Mageia x86_64 / Zsh 5.9.2 / libcurl 8.21.0
checkout, using the normal `-O2 -g` module build, on 2026-09-10. The baseline is
commit `c364603`; the comparison is the 0.26.0-dev working build:

| Headers | Before, milliseconds | After, milliseconds |
| ---: | ---: | ---: |
| 4,096 | 19.015 | 0.761 |
| 8,192 | 55.449 | 1.769 |
| 16,384 | 208.725 | 2.945 |
| 32,768 | 818.087 | 5.933 |
| 65,536 | 3,600.294 | 12.614 |

The maximum-count median improved by about 285×. The old build's samples ranged
from 2.33 to 5.34 seconds at that size; the new build ranged from 11.87 to 12.81
milliseconds. These measurements describe this host and workload, not a general
transfer-speed guarantee. No timing threshold is part of the test suite.

Functional tests exercise the exact header budget and an extra field, ordered
duplicates observed independently by the HTTP and WebSocket fixtures, list
ownership after submission, the generated subprotocol field appended last, and
partial-list cleanup. All run through the normal, ASan, UBSan and Valgrind suites.
