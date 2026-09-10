/* Included by zcurl.c. Each session owns separate synchronous and concurrent
 * pools. Retained jobs pin the session until collection or drop. */
#define HTTP_SESSIONS 16

static void
session_standard_defaults(struct http_session *s)
{
    s->timeout = 10000;
    s->connect_timeout = 3000;
    s->max_body = BODY_LIMIT;
}

static struct http_session *
find_session(const char *name)
{
    struct http_session *s;
    for (s = named_sessions; s; s = s->next)
        if (!strcmp(s->name, name)) return s;
    return NULL;
}

/* Apply defaults only after parsing every request option, so --session order
 * cannot change explicit overrides. Submission snapshots these numeric values. */
static int
session_request_defaults(struct request *r, unsigned seen)
{
    struct http_session *s;
    if (!r->session_name) return 1;
    s = find_session(r->session_name);
    if (!s) {
        set_error("state", "unknown HTTP session; create it before requesting", 2);
        return 0;
    }
    if (!(seen & (1u << TIMEOUT))) r->timeout = s->timeout;
    if (!(seen & (1u << CONNECT_TIMEOUT))) r->connect_timeout = s->connect_timeout;
    if (!(seen & (1u << MAX_BODY))) r->max_body = s->max_body;
    return 1;
}

/* Validate a complete patch before committing it. Configuration never closes
 * pools, drives I/O, changes transfer globals, or alters retained jobs. */
static int
session_configure(struct http_session *s, char **args)
{
    long timeout = s->timeout, connect_timeout = s->connect_timeout, max_body = s->max_body;
    unsigned seen = 0;
    if (!*args) goto usage;
    if (!strcmp(*args, "--defaults") && !args[1]) {
        session_standard_defaults(s);
        return 0;
    }
    while (*args) {
        char *option = text_argument(*args++), *value;
        long *target, maximum;
        unsigned bit;
        if (!option) goto usage;
        if (!strcmp(option, "--timeout") || !strcmp(option, "-t")) {
            bit = 1; target = &timeout; maximum = 600000;
        } else if (!strcmp(option, "--connect-timeout")) {
            bit = 2; target = &connect_timeout; maximum = 600000;
        } else if (!strcmp(option, "--max-body")) {
            bit = 4; target = &max_body; maximum = MAX_BODY_LIMIT;
        } else goto usage;
        if ((seen & bit) || !*args || !(value = text_argument(*args++)) ||
            !decimal(value, 1, maximum, target)) goto usage;
        seen |= bit;
    }
    s->timeout = timeout;
    s->connect_timeout = connect_timeout;
    s->max_body = max_body;
    return 0;
usage:
    zwarnnam("zcurl session", "configure requires timeout/connect-timeout (1..600000 ms), max-body (1..67108864 bytes), or --defaults alone");
    return 2;
}

static void
sessions_cleanup(void)
{
    struct http_session *s;
    while ((s = named_sessions)) {
        named_sessions = s->next;
        close_session(s);
        free(s->name);
        free(s);
    }
    close_session(&default_session);
}

/* Publish owned metadata without touching transfer globals or driving jobs.
 * Signals remain queued and only ordinary hash parameters may be replaced. */
static int
session_info(struct http_session *s, char **args)
{
    const char *keys[] = {"name", "timeout", "connect_timeout", "max_body", "retained_jobs"};
    uintmax_t numbers[] = {(uintmax_t)s->timeout, (uintmax_t)s->connect_timeout,
                          (uintmax_t)s->max_body, (uintmax_t)s->http_jobs};
    char *option, *target, **values;
    size_t i;
    if (!args[0] || !args[1] || args[2] || !(option = text_argument(args[0])) ||
        (strcmp(option, "--result") && strcmp(option, "-r")) ||
        !(target = text_argument(args[1])) || !result_parameter(target)) {
        zwarnnam("zcurl session", "info requires --result ARRAY (a declared writable ordinary associative array)");
        return 2;
    }
    values = zalloc((2 * ARRAY_SIZE(keys) + 1) * sizeof(*values));
    for (i = 0; i < ARRAY_SIZE(keys); ++i) {
        char number[64];
        values[2 * i] = ztrdup(keys[i]);
        if (!i) values[2 * i + 1] = ztrdup(s->name);
        else {
            snprintf(number, sizeof(number), "%ju", numbers[i - 1]);
            values[2 * i + 1] = ztrdup(number);
        }
    }
    values[2 * i] = NULL;
    if (!sethparam(target, values)) {
        zwarnnam("zcurl session", "could not publish session information");
        return 2;
    }
    return 0;
}

/* Management preserves the last transfer result, including on failure.
 * The caller holds the normal owner/busy guard and queues signals. */
static int
sessions_command(char **args)
{
    struct http_session *s, **link;
    char *operation, *name;
    size_t count = 0;
    const char *message = "use zcurl session create|reset|drop|configure|info NAME (ASCII identifier, at most 64 characters)";
    int status = 2;
    if (!args[0] || !args[1] || !(operation = text_argument(args[0])) ||
        !(name = text_argument(args[1])) || !identifier(name) || strlen(name) > 64) goto error;
    if (!strcmp(operation, "configure") || !strcmp(operation, "info")) {
        s = find_session(name);
        if (!s) { message = "unknown HTTP session"; goto error; }
        return !strcmp(operation, "info") ? session_info(s, args + 2) : session_configure(s, args + 2);
    }
    if (args[2]) goto error;
    if (strcmp(operation, "create") && strcmp(operation, "reset") && strcmp(operation, "drop")) goto error;
    for (link = &named_sessions; *link; link = &(*link)->next) {
        count++;
        if (!strcmp((*link)->name, name)) break;
    }
    s = *link;
    if (!strcmp(operation, "create")) {
        if (s) { message = "HTTP session already exists"; goto error; }
        if (count >= HTTP_SESSIONS) { message = "at most 16 named HTTP sessions may exist"; goto error; }
        s = calloc(1, sizeof(*s));
        if (!s || !(s->name = strdup(name))) {
            free(s);
            status = 27;
            message = "could not allocate HTTP session";
            goto error;
        }
        *link = s;
        session_standard_defaults(s);
        return 0;
    }
    if (!s) { message = "unknown HTTP session"; goto error; }
    if (s->http_jobs) {
        message = "HTTP session has retained requests; collect or drop them first";
        goto error;
    }
    close_session(s);
    if (!strcmp(operation, "drop")) {
        *link = s->next;
        free(s->name);
        free(s);
    }
    return 0;
error:
    zwarnnam("zcurl session", "%s", message);
    return status;
}
