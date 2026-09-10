/* Included by zcurl.c. Each synchronous session owns an easy/multi pair;
 * no connection pool or libcurl share handle crosses session boundaries. */
#define HTTP_SESSIONS 16

static struct http_session *
find_session(const char *name)
{
    struct http_session *s;
    for (s = named_sessions; s; s = s->next)
        if (!strcmp(s->name, name)) return s;
    return NULL;
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

/* Management preserves the last transfer result, including on failure.
 * The caller holds the normal owner/busy guard and queues signals. */
static int
sessions_command(char **args)
{
    struct http_session *s, **link;
    char *operation, *name;
    size_t count = 0;
    const char *message = "use zcurl session create|reset|drop NAME (ASCII identifier, at most 64 characters)";
    int status = 2;
    if (!args[0] || !args[1] || args[2] || !(operation = text_argument(args[0])) ||
        !(name = text_argument(args[1])) || !identifier(name) || strlen(name) > 64) goto error;
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
        return 0;
    }
    if (!s) { message = "unknown HTTP session"; goto error; }
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
