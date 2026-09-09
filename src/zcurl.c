/* Zsh/libcurl binding. See README.md for the supported contract. */
#define MODULE 1
#include "zsh.mdh"
#include "version.h"
#include <curl/curl.h>
#include <stdint.h>
#include <inttypes.h>
#include <poll.h>
#include <time.h>

#define ZCURL_VERSION "0.4.0-dev"
#define BODY_LIMIT (8L * 1024 * 1024)
#define MAX_BODY_LIMIT (64L * 1024 * 1024)
#define HEADER_LIMIT (256L * 1024)
#define ARRAY_SIZE(a) (sizeof(a) / sizeof(*(a)))

static CURL *session;
static CURLM *pool;
static pid_t owner;
static int initialized, busy;
static char *body, *headers, *error_text, *error_kind, *effective_url, *content_type;
static zlong http_status, curl_code, new_connections, total_us;
static zlong return_status, complete, received_bytes;
static char *handle_text, *event_text, *state_text, *ws_type, *ws_close_reason;
static zlong ws_offset, ws_bytesleft, ws_more, ws_message_end;
static zlong ws_queued_bytes, ws_queued_frames, ws_close_code;

enum buffer_failure { BUFFER_OK, BUFFER_LIMIT, BUFFER_MEMORY };
struct buffer {
    char *data;
    size_t len, capacity, limit;
    enum buffer_failure failure;
};

struct request {
    char *url, *ca, *method, *data, *result;
    size_t data_len;
    long timeout, connect_timeout, max_body;
    int fail_http, head, has_data;
    struct curl_slist *headers;
    size_t header_bytes;
};

static size_t
receive(char *data, size_t size, size_t count, void *context)
{
    struct buffer *b = context;
    size_t n, needed, capacity;
    char *p;
    if ((size && count > SIZE_MAX / size) || size * count > b->limit - b->len) {
        b->failure = BUFFER_LIMIT;
        return 0;
    }
    n = size * count;
    needed = b->len + n + 1;
    if (needed > b->capacity) {
        capacity = b->capacity ? b->capacity * 2 : 4096;
        if (capacity < needed)
            capacity = needed;
        if (capacity > b->limit + 1)
            capacity = b->limit + 1;
        p = realloc(b->data, capacity);
        if (!p) {
            b->failure = BUFFER_MEMORY;
            return 0;
        }
        b->data = p;
        b->capacity = capacity;
    }
    memcpy(b->data + b->len, data, n);
    b->len += n;
    b->data[b->len] = '\0';
    return n;
}

static int64_t
monotonic_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int
interrupted(void)
{
    return errflag || retflag || breaks || contflag;
}

static int
progress(UNUSED(void *context), UNUSED(curl_off_t dt), UNUSED(curl_off_t dn),
         UNUSED(curl_off_t ut), UNUSED(curl_off_t un))
{
    return interrupted();
}

/* All parameter publication happens with Zsh signals queued. */
static void
replace_text(char **target, const char *data, size_t len)
{
    char *next = metafy((char *)data, (int)len, META_DUP);
    zsfree(*target);
    *target = next;
}

static void
set_error(const char *kind, const char *message, int status)
{
    replace_text(&error_kind, kind, strlen(kind));
    replace_text(&error_text, message, strlen(message));
    return_status = status;
}

static void
clear_result(void)
{
    replace_text(&body, "", 0);
    replace_text(&headers, "", 0);
    replace_text(&error_text, "", 0);
    replace_text(&error_kind, "none", 4);
    replace_text(&effective_url, "", 0);
    replace_text(&content_type, "", 0);
    http_status = new_connections = total_us = received_bytes = complete = 0;
    return_status = 0;
    curl_code = -1; /* No transfer has been attempted. */
    replace_text(&handle_text, "", 0);
    replace_text(&event_text, "", 0);
    replace_text(&state_text, "", 0);
    replace_text(&ws_type, "", 0);
    replace_text(&ws_close_reason, "", 0);
    ws_offset = ws_bytesleft = ws_more = ws_message_end = 0;
    ws_queued_bytes = ws_queued_frames = ws_close_code = 0;
}

/* Arguments are metafied, even for a builtin. Data may contain embedded NUL. */
static char *
decode(char *value, size_t *length)
{
    int len;
    char *copy = dupstring(value);
    unmetafy(copy, &len);
    *length = (size_t)len;
    return copy;
}

static char *
text_argument(char *value)
{
    size_t len;
    char *copy = decode(value, &len);
    return memchr(copy, '\0', len) ? NULL : copy;
}

static int
decimal(const char *value, long min, long max, long *out)
{
    char *end;
    long n;
    if (!*value || strspn(value, "0123456789") != strlen(value))
        return 0;
    errno = 0;
    n = strtol(value, &end, 10);
    if (errno || *end || n < min || n > max)
        return 0;
    *out = n;
    return 1;
}

/* An explicit ASCII grammar avoids subscript/arithmetic evaluation. */
static int
identifier(const char *value)
{
    const char *first = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_";
    const char *rest = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789";
    return *value && strchr(first, *value) && strspn(value, rest) == strlen(value);
}

static Param
result_parameter(char *name)
{
    Param pm;
    int forbidden = PM_READONLY | PM_SPECIAL | PM_TIED | PM_AUTOLOAD |
        PM_LEFT | PM_RIGHT_B | PM_RIGHT_Z | PM_LOWER | PM_UPPER | PM_RESTRICTED;
    if (!identifier(name))
        return NULL;
    pm = (Param)gethashnode2(paramtab, name);
    if (!pm || PM_TYPE(pm->node.flags) != PM_HASHED ||
        (pm->node.flags & forbidden) || pm->gsu.h != &stdhash_gsu)
        return NULL;
    return pm;
}

static int
token(const char *value, size_t len)
{
    return len && strspn(value,
        "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") >= len;
}

static int
add_header(struct request *r, const char *value)
{
    const char *colon = strchr(value, ':');
    const unsigned char *p = (const unsigned char *)value;
    struct curl_slist *next;
    size_t n = strlen(value);
    /* Accept one HTTP field per option, including curl's 'Name:' suppression. */
    if (!colon || !token(value, (size_t)(colon - value)))
        return 0;
    for (; *p; ++p)
        if ((*p < 32 && *p != '\t') || *p == 127)
            return 0;
    if (n + 2 > HEADER_LIMIT - r->header_bytes)
        return 0;
    next = curl_slist_append(r->headers, value);
    if (!next) {
        set_error("memory", "could not allocate request headers", 27);
        return 0;
    }
    r->headers = next;
    r->header_bytes += n + 2;
    return 1;
}

enum option_id { CA, TIMEOUT, CONNECT_TIMEOUT, METHOD, HEADER, DATA, RESULT,
                 MAX_BODY, FAIL_HTTP, HEAD };
struct option_spec { const char *short_name, *long_name; enum option_id id; int value; };
static const struct option_spec option_specs[] = {
    {"-c", "--cacert", CA, 1},
    {"-t", "--timeout", TIMEOUT, 1},
    {NULL, "--connect-timeout", CONNECT_TIMEOUT, 1},
    {"-X", "--request", METHOD, 1},
    {"-H", "--header", HEADER, 1},
    {"-d", "--data", DATA, 1},
    {"-r", "--result", RESULT, 1},
    {NULL, "--max-body", MAX_BODY, 1},
    {"-f", "--fail", FAIL_HTTP, 0},
    {"-I", "--head", HEAD, 0},
};

static int
parse_request(char **args, struct request *r)
{
    int options = 1;
    unsigned seen = 0;
    while (*args) {
        char *arg = text_argument(*args++), *value = NULL;
        const struct option_spec *spec = NULL;
        size_t i;
        if (!arg)
            goto invalid;
        if (options && !strcmp(arg, "--")) {
            options = 0;
            continue;
        }
        if (!options || arg[0] != '-' || !arg[1]) {
            if (r->url || !*arg) {
                set_error("usage", "expected exactly one nonempty URL", 2);
                return 0;
            }
            r->url = arg;
            continue;
        }
        for (i = 0; i < ARRAY_SIZE(option_specs); ++i) {
            const struct option_spec *s = &option_specs[i];
            if (!strcmp(arg, s->long_name) || (s->short_name && !strcmp(arg, s->short_name))) {
                spec = s;
                break;
            }
        }
        if (!spec) {
            set_error("usage", "unknown option; use zcurl --help (option values must be separate words)", 2);
            return 0;
        }
        if (spec->id != HEADER && (seen & (1u << spec->id))) {
            set_error("usage", "only --header may be repeated", 2);
            return 0;
        }
        seen |= 1u << spec->id;
        if (spec->value) {
            if (!*args) {
                set_error("usage", "missing option value", 2);
                return 0;
            }
            if (spec->id == DATA) {
                r->data = decode(*args++, &r->data_len);
                r->has_data = 1;
                continue;
            }
            if (!(value = text_argument(*args++)))
                goto invalid;
        }
        switch (spec->id) {
        case CA: r->ca = value; if (!*value) goto invalid; break;
        case METHOD:
            if (!token(value, strlen(value))) goto invalid;
            r->method = value;
            break;
        case TIMEOUT:
            if (!decimal(value, 1, 600000, &r->timeout)) goto invalid;
            break;
        case CONNECT_TIMEOUT:
            if (!decimal(value, 1, 600000, &r->connect_timeout)) goto invalid;
            break;
        case MAX_BODY:
            if (!decimal(value, 1, MAX_BODY_LIMIT, &r->max_body)) goto invalid;
            break;
        case HEADER:
            if (!add_header(r, value)) {
                if (!return_status)
                    set_error("usage", "invalid header or request headers exceed 256 KiB", 2);
                return 0;
            }
            break;
        case RESULT:
            if (!result_parameter(value)) {
                set_error("usage", "--result requires a declared, writable, ordinary associative array", 2);
                return 0;
            }
            r->result = value;
            break;
        case FAIL_HTTP: r->fail_http = 1; break;
        case HEAD: r->head = 1; break;
        case DATA: break;
        }
    }
    if (!r->url) {
        set_error("usage", "expected one URL; use zcurl --help", 2);
        return 0;
    }
    if (r->method && !strcmp(r->method, "HEAD"))
        r->head = 1;
    if (r->head && (r->has_data || (r->method && strcmp(r->method, "HEAD")))) {
        set_error("usage", "HEAD cannot be combined with data or a different method", 2);
        return 0;
    }
    return 1;
invalid:
    set_error("usage", "invalid option value, method, or embedded NUL outside request data", 2);
    return 0;
}

static void
close_session(void)
{
    if (session)
        curl_easy_cleanup(session);
    session = NULL;
    if (pool)
        curl_multi_cleanup(pool);
    pool = NULL;
}

/* Enter/leave with signals queued. Shell traps run only outside libcurl. */
static CURLcode
drive_request(char *diagnostic, int *started)
{
    CURLMcode mc = curl_multi_add_handle(pool, session);
    CURLcode rc = CURLE_FAILED_INIT;
    int attached = mc == CURLM_OK;
    while (mc == CURLM_OK) {
        int stop, running, remaining;
        CURLMsg *message;
        unqueue_signals();
        stop = interrupted();
        queue_signals();
        if (stop) {
            rc = CURLE_ABORTED_BY_CALLBACK;
            break;
        }
        *started = 1;
        mc = curl_multi_perform(pool, &running);
        if (mc != CURLM_OK)
            break;
        message = curl_multi_info_read(pool, &remaining);
        if (message && message->msg == CURLMSG_DONE && message->easy_handle == session) {
            rc = message->data.result;
            break;
        }
        if (!running) {
            snprintf(diagnostic, CURL_ERROR_SIZE, "libcurl completed without a transfer result");
            break;
        }
        /* libcurl shortens this further when its own timer is due. */
        mc = curl_multi_poll(pool, NULL, 0, 100, NULL);
    }
    if (attached) {
        CURLMcode removed = curl_multi_remove_handle(pool, session);
        if (mc == CURLM_OK)
            mc = removed;
    }
    if (mc != CURLM_OK) {
        snprintf(diagnostic, CURL_ERROR_SIZE, "libcurl multi: %s", curl_multi_strerror(mc));
        rc = CURLE_FAILED_INIT;
        /* A failed multi stack must not be reused for subsequent transfers. */
        curl_multi_cleanup(pool);
        pool = NULL;
    }
    return rc;
}

/* libcurl copies string options. Persistent uploads need their own byte copy;
 * header lists and callback storage remain owned by the caller. */
static CURLcode
configure_http(CURL *easy, struct request *r, struct buffer *b,
               struct buffer *h, char *diagnostic, int persistent)
{
    CURLcode rc;
#define SET(option, value) do { \
    rc = curl_easy_setopt(easy, option, value); \
    if (rc != CURLE_OK) return rc; \
} while (0)
    SET(CURLOPT_URL, r->url);
    SET(CURLOPT_DEFAULT_PROTOCOL, "https");
    SET(CURLOPT_PROTOCOLS_STR, "http,https");
    SET(CURLOPT_REDIR_PROTOCOLS_STR, "https");
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_TIMEOUT_MS, r->timeout);
    SET(CURLOPT_CONNECTTIMEOUT_MS, r->connect_timeout);
    SET(CURLOPT_ERRORBUFFER, diagnostic);
    SET(CURLOPT_WRITEFUNCTION, receive);
    SET(CURLOPT_WRITEDATA, b);
    SET(CURLOPT_HEADERFUNCTION, receive);
    SET(CURLOPT_HEADERDATA, h);
    SET(CURLOPT_NOPROGRESS, persistent ? 1L : 0L);
    SET(CURLOPT_XFERINFOFUNCTION, progress);
    SET(CURLOPT_HTTPHEADER, r->headers);
    SET(CURLOPT_HEADEROPT, (long)CURLHEADER_SEPARATE);
    if (r->ca)
        SET(CURLOPT_CAINFO, r->ca);
    if (r->has_data || (r->method && !strcmp(r->method, "POST"))) {
        SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)r->data_len);
        SET(persistent ? CURLOPT_COPYPOSTFIELDS : CURLOPT_POSTFIELDS, r->has_data ? r->data : "");
    }
    if (r->head)
        SET(CURLOPT_NOBODY, 1L);
    else if (r->method)
        SET(CURLOPT_CUSTOMREQUEST, r->method);

    return CURLE_OK;
#undef SET
}

static void
http_result(struct buffer *b, struct buffer *h, CURLcode rc,
            const char *diagnostic, int fail_http)
{
    replace_text(&body, b->data ? b->data : "", b->len);
    replace_text(&headers, h->data ? h->data : "", h->len);
    curl_code = rc;
    received_bytes = (zlong)b->len;
    complete = rc == CURLE_OK;
    return_status = (int)rc;
    if (b->failure == BUFFER_LIMIT)
        set_error("body-limit", "response body exceeds --max-body", (int)rc);
    else if (h->failure == BUFFER_LIMIT)
        set_error("header-limit", "response headers exceed 256 KiB", (int)rc);
    else if (b->failure == BUFFER_MEMORY || h->failure == BUFFER_MEMORY || rc == CURLE_OUT_OF_MEMORY)
        set_error("memory", "could not allocate transfer storage", (int)rc);
    else if (rc != CURLE_OK)
        set_error("transport", diagnostic[0] ? diagnostic : curl_easy_strerror(rc), (int)rc);
    else if (fail_http && http_status >= 400)
        set_error("http", "HTTP response status is 400 or higher", 22);
}

static void
perform_request(struct request *r)
{
    struct buffer b = {NULL, 0, 0, (size_t)r->max_body, BUFFER_OK};
    struct buffer h = {NULL, 0, 0, HEADER_LIMIT, BUFFER_OK};
    char diagnostic[CURL_ERROR_SIZE] = {0};
    long status = 0, connects = 0;
    curl_off_t elapsed = 0;
    CURLcode rc = CURLE_OK;
    char *info = NULL;
    int started = 0;

    if (!session && !(session = curl_easy_init())) {
        rc = CURLE_OUT_OF_MEMORY;
        goto done;
    }
    if (!pool && !(pool = curl_multi_init())) {
        rc = CURLE_OUT_OF_MEMORY;
        goto done;
    }
    /* Reset per-request options; preserve the connection, DNS and TLS caches. */
    curl_easy_reset(session);
    rc = configure_http(session, r, &b, &h, diagnostic, 0);
    if (rc != CURLE_OK) goto done;

    rc = drive_request(diagnostic, &started);
    if (!started)
        goto done; /* getinfo may otherwise report a previous transfer. */
    curl_easy_getinfo(session, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_getinfo(session, CURLINFO_NUM_CONNECTS, &connects);
    curl_easy_getinfo(session, CURLINFO_TOTAL_TIME_T, &elapsed);
    if (curl_easy_getinfo(session, CURLINFO_EFFECTIVE_URL, &info) == CURLE_OK && info)
        replace_text(&effective_url, info, strlen(info));
    info = NULL;
    if (curl_easy_getinfo(session, CURLINFO_CONTENT_TYPE, &info) == CURLE_OK && info)
        replace_text(&content_type, info, strlen(info));
done:
    /* Remove every pointer to this request before releasing its storage. */
    if (session)
        curl_easy_reset(session);
    http_status = status;
    new_connections = connects;
    total_us = (zlong)elapsed;
    http_result(&b, &h, rc, diagnostic, r->fail_http);
    free(b.data);
    free(h.data);
}

/* The same field table drives module parameters and caller-owned snapshots. */
struct result_field { const char *key; int integer; void *value; };
static const struct result_field result_fields[] = {
    {"body", 0, &body}, {"headers", 0, &headers}, {"error", 0, &error_text},
    {"error_kind", 0, &error_kind}, {"effective_url", 0, &effective_url},
    {"content_type", 0, &content_type}, {"http_status", 1, &http_status},
    {"code", 1, &curl_code}, {"new_connections", 1, &new_connections},
    {"total_us", 1, &total_us}, {"status", 1, &return_status},
    {"complete", 1, &complete}, {"bytes", 1, &received_bytes},
    {"handle", 0, &handle_text}, {"event", 0, &event_text},
    {"state", 0, &state_text}, {"frame_type", 0, &ws_type},
    {"offset", 1, &ws_offset}, {"bytesleft", 1, &ws_bytesleft},
    {"more", 1, &ws_more}, {"message_end", 1, &ws_message_end},
    {"queued_bytes", 1, &ws_queued_bytes}, {"queued_frames", 1, &ws_queued_frames},
    {"close_code", 1, &ws_close_code}, {"close_reason", 0, &ws_close_reason},
};

enum result_shape { RESULT_HTTP, RESULT_WS, RESULT_ASYNC };

static int
publish_result(char *name, enum result_shape shape)
{
    char **values;
    /* HTTP jobs share handle/event/state with WS, retaining both older shapes. */
    size_t i, count = shape == RESULT_WS ? ARRAY_SIZE(result_fields) :
                      shape == RESULT_ASYNC ? 16 : 13;
    /* A trap may have changed the destination during the transfer. */
    if (!result_parameter(name)) {
        set_error("result", "result array changed during the request; see zcurl_* parameters", 2);
        return 0;
    }
    values = zalloc((2 * count + 1) * sizeof(*values));
    for (i = 0; i < count; ++i) {
        const struct result_field *f = &result_fields[i];
        char number[64];
        values[2 * i] = ztrdup(f->key);
        if (f->integer) {
            snprintf(number, sizeof(number), "%jd", (intmax_t)*(zlong *)f->value);
            values[2 * i + 1] = ztrdup(number);
        } else
            values[2 * i + 1] = ztrdup(*(char **)f->value ? *(char **)f->value : "");
    }
    values[2 * i] = NULL;
    if (!sethparam(name, values)) {
        set_error("result", "could not publish result array; see zcurl_* parameters", 2);
        return 0;
    }
    return 1;
}

static void
help(void)
{
    puts("zcurl [options] URL\n"
         "  -c, --cacert FILE         PEM trust file\n"
         "  -t, --timeout MS          Total timeout (1..600000; default 10000)\n"
         "      --connect-timeout MS  Connection timeout (default 3000)\n"
         "  -X, --request METHOD      HTTP method (default GET, or POST with data)\n"
         "  -I, --head                HEAD request, without a response body\n"
         "  -H, --header FIELD        Request header (repeatable)\n"
         "  -d, --data BYTES          Literal request body; preserves NUL bytes\n"
         "  -r, --result ARRAY        Replace a declared ordinary associative array\n"
         "  -f, --fail                Return 22 for HTTP >=400; retain the response\n"
         "      --max-body BYTES      Response limit (default 8 MiB; maximum 64 MiB)\n"
         "      --                    End options\n"
         "zcurl --reset               Close HTTP/WS sessions and clear results\n"
         "zcurl --version             Show module, build Zsh and libcurl versions\n"
         "zcurl --help                Show this help\n"
         "zcurl http submit HANDLE [HTTP options] URL\n"
         "zcurl http poll [-t MS] [-r ARRAY]\n"
         "zcurl http collect|cancel|drop|info HANDLE [-r ARRAY]\n"
         "  See docs/concurrency.md for scheduling, limits and result ownership.\n"
         "zcurl ws OP HANDLE [options] [URL]\n"
         "  OP: open, send, recv, poll, close, drop, info\n"
         "  See docs/websocket.md for options, events and connection lifecycle.\n"
         "Option values must be separate words; short options cannot be clustered.\n"
         "Results are in zcurl_* parameters, and optionally ARRAY. No body is printed.");
}

#include "websocket.c"
#include "http_async.c"

static int
bin_zcurl(char *name, char **args, UNUSED(Options ops), UNUSED(int func))
{
    struct request r = {0};
    int result;
    char *control;
    if (busy || owner != getpid()) {
        zwarnnam(name, "requires the owning shell and no reentry");
        return 2;
    }
    queue_signals();
    busy = 1;
    clear_result();
    r.timeout = 10000;
    r.connect_timeout = 3000;
    r.max_body = BODY_LIMIT;
    if (args[0] && (control = text_argument(args[0])) && !strcmp(control, "ws")) {
        websocket_command(args + 1);
        goto done;
    }
    if (args[0] && (control = text_argument(args[0])) && !strcmp(control, "http")) {
        http_command(args + 1);
        goto done;
    }
    if (args[0] && !args[1] && (control = text_argument(args[0]))) {
        if (!strcmp(control, "--help")) {
            help();
            goto done;
        }
        if (!strcmp(control, "--version")) {
            printf("zcurl %s; built for Zsh %s; %s\n", ZCURL_VERSION, ZSH_VERSION, curl_version());
            goto done;
        }
        if (!strcmp(control, "--reset")) {
            close_session();
            websocket_cleanup();
            http_cleanup();
            goto done;
        }
    }
    if (parse_request(args, &r))
        perform_request(&r);
    if (r.result)
        publish_result(r.result, RESULT_HTTP);
    if (!strcmp(error_kind, "usage"))
        zwarnnam(name, "%s", error_text);
done:
    curl_slist_free_all(r.headers);
    result = (int)return_status;
    busy = 0;
    unqueue_signals();
    return result;
}

static struct builtin builtins[] = {
    BUILTIN("zcurl", BINF_HANDLES_OPTS, bin_zcurl, 0, -1, 0, NULL, NULL),
};

/* Initialized from result_fields by setup_; names must live until finish_. */
static struct paramdef parameters[ARRAY_SIZE(result_fields)];
static struct features module_features = {
    builtins, ARRAY_SIZE(builtins), NULL, 0, NULL, 0,
    parameters, ARRAY_SIZE(parameters), 0
};

int setup_(UNUSED(Module m))
{
    size_t i;
    char *running = getsparam("ZSH_VERSION");
    if (!running || strcmp(running, ZSH_VERSION)) {
        zwarn("zcurl: rebuild for this Zsh version (module built for %s)", ZSH_VERSION);
        return 1;
    }
    owner = getpid();
    initialized = curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK;
    if (!initialized)
        return 1;
    for (i = 0; i < ARRAY_SIZE(result_fields); ++i) {
        const struct result_field *f = &result_fields[i];
        struct paramdef *p = &parameters[i];
        p->name = ztrdup(dyncat("zcurl_", f->key));
        p->flags = (f->integer ? PM_INTEGER : PM_SCALAR) | PM_READONLY;
        p->var = f->value;
    }
    clear_result();
    return 0;
}
int features_(Module m, char ***features)
{
    *features = featuresarray(m, &module_features);
    return 0;
}
int enables_(Module m, int **enables)
{
    if (busy && *enables)
        return 1;
    return handlefeatures(m, &module_features, enables);
}
int boot_(UNUSED(Module m)) { return 0; }
int cleanup_(Module m)
{
    if (busy)
        return 1;
    return setfeatureenables(m, &module_features, NULL);
}
int finish_(UNUSED(Module m))
{
    size_t i;
    /* Never send TLS shutdown on a connection inherited from the parent. */
    if (getpid() == owner) {
        websocket_cleanup();
        http_cleanup();
        close_session();
        if (initialized)
            curl_global_cleanup();
    }
    session = NULL;
    pool = NULL;
    websockets = NULL;
    http_jobs = NULL;
    http_pool = NULL;
    http_reserved = 0;
    initialized = busy = 0;
    for (i = 0; i < ARRAY_SIZE(result_fields); ++i) {
        if (!result_fields[i].integer) {
            char **value = result_fields[i].value;
            zsfree(*value);
            *value = NULL;
        }
        zsfree(parameters[i].name);
        memset(&parameters[i], 0, sizeof(parameters[i]));
    }
    return 0;
}
