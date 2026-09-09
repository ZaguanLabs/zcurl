/* Included by zcurl.c. Explicitly driven HTTP jobs share one connection pool.
 * All retained pointers belong to a job or libcurl, never to a builtin's heap. */
#define HTTP_JOBS 32
#define HTTP_STORAGE (128u * 1024 * 1024)
#define HTTP_STEPS 64

struct http_job {
    struct http_job *next;
    char *name;
    CURL *easy;
    struct curl_slist *request_headers;
    struct buffer body, headers;
    char diagnostic[CURL_ERROR_SIZE];
    size_t reserved;
    int attached, done, cancelled, started, fail_http;
    int64_t deadline;
    CURLcode code;
};
static struct http_job *http_jobs;
static CURLM *http_pool;
static size_t http_reserved;

static struct http_job *
http_find(const char *name)
{
    struct http_job *j;
    for (j = http_jobs; j; j = j->next)
        if (!strcmp(j->name, name)) return j;
    return NULL;
}

static void
http_destroy(struct http_job *j)
{
    struct http_job **p = &http_jobs;
    while (*p && *p != j) p = &(*p)->next;
    if (*p) {
        *p = j->next;
        http_reserved -= j->reserved;
    }
    if (j->attached) curl_multi_remove_handle(http_pool, j->easy);
    if (j->easy) curl_easy_cleanup(j->easy);
    close_output(&j->body);
    curl_slist_free_all(j->request_headers);
    free(j->body.data);
    free(j->headers.data);
    free(j->name);
    free(j);
}

static void
http_cleanup(void)
{
    while (http_jobs) http_destroy(http_jobs);
    if (http_pool) curl_multi_cleanup(http_pool);
    http_pool = NULL;
    http_reserved = 0;
}

/* A multi-stack failure invalidates every attached transfer, but completed
 * records remain collectable. Subsequent submits get a fresh pool. */
static void
http_pool_fail(CURLMcode mc)
{
    struct http_job *j;
    for (j = http_jobs; j; j = j->next) {
        if (!j->attached) continue;
        curl_multi_remove_handle(http_pool, j->easy);
        j->attached = 0;
        j->done = 1;
        j->code = CURLE_FAILED_INIT;
        close_output(&j->body);
        snprintf(j->diagnostic, sizeof(j->diagnostic), "libcurl multi: %s", curl_multi_strerror(mc));
    }
    curl_multi_cleanup(http_pool);
    http_pool = NULL;
    set_error("transport", "concurrent HTTP pool failed; collect affected requests", 2);
    curl_code = CURLE_FAILED_INIT;
    replace_text(&event_text, "error", 5);
}

static int
http_finish(struct http_job *j, CURLcode code)
{
    CURLMcode mc = curl_multi_remove_handle(http_pool, j->easy);
    if (mc != CURLM_OK) {
        http_pool_fail(mc);
        return 0;
    }
    j->attached = 0;
    j->done = 1;
    if (!close_output(&j->body) && code == CURLE_OK) code = CURLE_WRITE_ERROR;
    j->code = code;
    return 1;
}

static void
http_snapshot(struct http_job *j, const char *event)
{
    const char *state = j->cancelled ? "cancelled" : j->done ? "done" : "pending";
    replace_text(&handle_text, j->name, strlen(j->name));
    replace_text(&state_text, state, strlen(state));
    replace_text(&event_text, event, strlen(event));
    received_bytes = (zlong)j->body.len;
}

static struct http_job *
http_submit(const char *name, struct request *r)
{
    struct http_job *j, **tail = &http_jobs;
    size_t count = 0, reserve = (r->has_output ? 0 : (size_t)r->max_body) + HEADER_LIMIT;
    size_t sizes[] = {r->data_len, r->header_bytes, strlen(r->url) + 1,
                     r->ca ? strlen(r->ca) + 1 : 0,
                     r->method ? strlen(r->method) + 1 : 0};
    size_t i;
    CURLcode rc;
    CURLMcode mc;
    for (j = http_jobs; j; j = j->next) { count++; tail = &j->next; }
    if (http_find(name)) {
        set_error("state", "HTTP handle already exists; collect or drop it first", 2);
        return NULL;
    }
    for (i = 0; i < ARRAY_SIZE(sizes); ++i) {
        if (sizes[i] > HTTP_STORAGE - reserve) goto limit;
        reserve += sizes[i];
    }
    if (count >= HTTP_JOBS || reserve > HTTP_STORAGE - http_reserved) goto limit;
    j = calloc(1, sizeof(*j));
    if (!j) goto memory;
    j->name = strdup(name);
    j->easy = curl_easy_init();
    j->body.limit = (size_t)r->max_body;
    j->headers.limit = HEADER_LIMIT;
    j->fail_http = r->fail_http;
    j->reserved = reserve;
    if (!http_pool) http_pool = curl_multi_init();
    if (!j->name || !j->easy || !http_pool) {
        http_destroy(j);
        goto memory;
    }
    if (!prepare_output(r, &j->body)) {
        http_destroy(j);
        return NULL;
    }
    rc = configure_http(j->easy, r, &j->body, &j->headers, j->diagnostic, 1);
    if (rc != CURLE_OK) {
        curl_code = rc;
        set_error(rc == CURLE_OUT_OF_MEMORY ? "memory" : "transport", curl_easy_strerror(rc), (int)rc);
        http_destroy(j);
        return NULL;
    }
    mc = curl_multi_add_handle(http_pool, j->easy);
    if (mc != CURLM_OK) {
        set_error("transport", curl_multi_strerror(mc), 2);
        http_destroy(j);
        return NULL;
    }
    j->attached = 1;
    j->request_headers = r->headers;
    r->headers = NULL;
    j->deadline = monotonic_ms() + r->timeout;
    *tail = j;
    http_reserved += reserve;
    return j;
limit:
    set_error("queue-limit", "concurrent HTTP limit: 32 handles or 128 MiB reserved storage; collect or drop requests", 2);
    return NULL;
memory:
    set_error("memory", "could not allocate concurrent HTTP request", 27);
    return NULL;
}

/* Return a retained completion without consuming it. A target selects wait
 * semantics: drive every job, but ignore unrelated completions and continue
 * until this target finishes or the caller's deadline/signal stops the wait. */
static struct http_job *
http_drive(long timeout, struct http_job *target)
{
    int64_t deadline = monotonic_ms() + timeout;
    int steps = 0;
    replace_text(&event_text, "idle", 4);
    do {
        struct http_job *j, *ready = NULL;
        int stop, running = 0, remaining;
        int64_t now, wait_ms;
        CURLMcode mc;
        CURLMsg *msg;
        unqueue_signals();
        stop = interrupted();
        queue_signals();
        if (stop) {
            curl_code = CURLE_ABORTED_BY_CALLBACK;
            set_error("interrupted", "HTTP polling/wait interrupted; requests remain available", 42);
            replace_text(&event_text, "interrupted", 11);
            return NULL;
        }
        now = monotonic_ms();
        for (j = http_jobs; j; j = j->next) {
            if (!j->done && now >= j->deadline) {
                snprintf(j->diagnostic, sizeof(j->diagnostic), "HTTP request exceeded its submission deadline");
                if (!http_finish(j, CURLE_OPERATION_TIMEDOUT)) return NULL;
            }
            if (!j->done) j->started = 1;
        }
        if (http_pool) {
            mc = curl_multi_perform(http_pool, &running);
            if (mc != CURLM_OK) { http_pool_fail(mc); return NULL; }
            while ((msg = curl_multi_info_read(http_pool, &remaining))) {
                CURLcode code;
                if (msg->msg != CURLMSG_DONE) continue;
                for (j = http_jobs; j; j = j->next)
                    if (j->easy == msg->easy_handle) break;
                /* Copy the completion code before removing its easy handle. */
                code = msg->data.result;
                if (j && code == CURLE_OK && monotonic_ms() >= j->deadline) {
                    /* A blocking backend step can outlast the remaining
                     * submission budget even if libcurl's own timer did not. */
                    code = CURLE_OPERATION_TIMEDOUT;
                    snprintf(j->diagnostic, sizeof(j->diagnostic), "HTTP request exceeded its submission deadline");
                }
                if (j && !http_finish(j, code)) return NULL;
            }
        }
        now = monotonic_ms();
        wait_ms = deadline - now;
        for (j = http_jobs; j; j = j->next) {
            if (j->done && (!target || j == target) && !ready) ready = j;
            if (!j->done && j->deadline - now < wait_ms)
                wait_ms = j->deadline - now;
        }
        if (ready) return ready;
        if (!running || now >= deadline) return NULL;
        /* A different request's deadline may have expired during this step.
         * Process it without treating it as the selected wait's deadline. */
        if (wait_ms <= 0) continue;
        mc = curl_multi_poll(http_pool, NULL, 0, wait_ms > 100 ? 100 : (int)wait_ms, NULL);
        if (mc != CURLM_OK) { http_pool_fail(mc); return NULL; }
    } while (target || ++steps < HTTP_STEPS);
    return NULL;
}

static void
http_collect(struct http_job *j)
{
    long status = 0, connects = 0;
    curl_off_t elapsed = 0;
    char *info = NULL;
    if (j->started) {
        curl_easy_getinfo(j->easy, CURLINFO_RESPONSE_CODE, &status);
        curl_easy_getinfo(j->easy, CURLINFO_NUM_CONNECTS, &connects);
        curl_easy_getinfo(j->easy, CURLINFO_TOTAL_TIME_T, &elapsed);
        if (curl_easy_getinfo(j->easy, CURLINFO_EFFECTIVE_URL, &info) == CURLE_OK && info)
            replace_text(&effective_url, info, strlen(info));
        info = NULL;
        if (curl_easy_getinfo(j->easy, CURLINFO_CONTENT_TYPE, &info) == CURLE_OK && info)
            replace_text(&content_type, info, strlen(info));
    }
    http_status = status;
    new_connections = connects;
    total_us = (zlong)elapsed;
    http_result(&j->body, &j->headers, j->code, j->diagnostic, j->fail_http);
    if (j->cancelled) set_error("cancelled", "HTTP request cancelled", 42);
    http_snapshot(j, "collected");
}

static void
http_command(char **args)
{
    struct request r = {0};
    struct http_job *j = NULL;
    char *op, *name = NULL;
    long timeout = 0;
    unsigned seen = 0;
    int collect = 0, waiting;
    r.timeout = 10000; r.connect_timeout = 3000; r.max_body = BODY_LIMIT;
    if (!*args || !(op = text_argument(*args++))) goto usage;
    waiting = !strcmp(op, "wait");
    if (strcmp(op, "submit") && strcmp(op, "poll") && strcmp(op, "collect") &&
        strcmp(op, "cancel") && strcmp(op, "drop") && strcmp(op, "info") && !waiting) goto usage;
    if (waiting) timeout = 10000;
    if (strcmp(op, "poll")) {
        if (!*args || !(name = text_argument(*args++)) || !identifier(name) || strlen(name) > 64) goto usage;
        replace_text(&handle_text, name, strlen(name));
    }
    if (!strcmp(op, "submit")) {
        if (parse_request(args, &r) && (j = http_submit(name, &r))) {
            curl_code = CURLE_OK;
            http_snapshot(j, "submitted");
        }
        goto done;
    }
    while (*args) {
        char *arg = text_argument(*args++), *value;
        unsigned bit;
        if (!arg) goto usage;
        if (!strcmp(arg, "--") && !*args) break;
        if (!strcmp(arg, "-r") || !strcmp(arg, "--result")) bit = 1;
        else if ((!strcmp(arg, "-t") || !strcmp(arg, "--timeout")) && (waiting || !strcmp(op, "poll"))) bit = 2;
        else goto usage;
        if ((seen & bit) || !*args || !(value = text_argument(*args++))) goto usage;
        seen |= bit;
        if (bit == 1) {
            if (!result_parameter(value)) goto usage;
            r.result = value;
        } else if (!decimal(value, 0, waiting ? 600000 : 1000, &timeout)) goto usage;
    }
    curl_code = CURLE_OK;
    if (!strcmp(op, "poll")) {
        j = http_drive(timeout, NULL);
        if (j) http_snapshot(j, "ready");
        goto done;
    }
    j = http_find(name);
    if (!j) { set_error("state", "unknown HTTP handle", 2); goto done; }
    if (waiting) {
        if (http_drive(timeout, j)) {
            http_snapshot(j, "ready");
        } else if (!return_status) {
            http_snapshot(j, "timeout");
            set_error("wait-timeout", "HTTP wait timed out; request remains available", 28);
        } else {
            http_snapshot(j, !strcmp(error_kind, "interrupted") ? "interrupted" : "error");
        }
        goto done;
    }
    http_snapshot(j, "info");
    if (!strcmp(op, "info")) goto done;
    if (!strcmp(op, "collect")) {
        if (!j->done) { set_error("state", "HTTP request is pending; poll before collecting", 2); goto done; }
        http_collect(j);
        collect = 1;
    } else if (!strcmp(op, "cancel")) {
        if (j->done) { set_error("state", "HTTP request has already finished", 2); goto done; }
        if (!http_finish(j, CURLE_ABORTED_BY_CALLBACK)) goto done;
        j->cancelled = 1;
        http_snapshot(j, "cancelled");
    } else {
        http_destroy(j); j = NULL;
        replace_text(&event_text, "dropped", 7);
        replace_text(&state_text, "dropped", 7);
        received_bytes = 0;
    }
    goto done;
usage:
    if (!return_status) set_error("usage", "invalid HTTP operation, handle, or option; see docs/concurrency.md", 2);
done:
    /* Failed publication must never consume a collectable response. A
     * successfully published HTTP/transport error still consumes the record. */
    if (r.result && !publish_result(r.result, RESULT_ASYNC)) collect = 0;
    if (collect) http_destroy(j);
    curl_slist_free_all(r.headers);
}
