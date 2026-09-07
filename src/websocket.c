/* Included by zcurl.c: shares byte decoding, result publication and the
 * owning-shell/reentry guard. No Zsh callbacks run inside a libcurl call. */
#define WS_HANDLES 32
#define WS_FRAMES 256
#define WS_CHUNK 65536
#define WS_STEPS 64

struct ws_utf8 { unsigned value, minimum, left; };
struct ws_frame {
    struct ws_frame *next;
    size_t len, sent;
    unsigned flags;
    int started;
    char data[];
};
struct websocket {
    struct websocket *next;
    char *name;
    CURL *easy;
    CURLM *multi;
    int attached, closing, close_sent, close_received;
    CURLcode failure;
    const char *failure_kind;
    char diagnostic[CURL_ERROR_SIZE];
    struct buffer handshake;
    struct curl_slist *request_headers;
    struct ws_frame *first, *last;
    size_t queue_bytes, queue_storage, queue_frames, max_queue, max_message;
    size_t send_message_bytes, recv_message_bytes;
    unsigned send_type, recv_type;
    struct ws_utf8 send_utf8, recv_utf8;
    unsigned char control[125];
    size_t control_len;
    unsigned close_code;
    char close_reason[124];
    size_t close_reason_len;
};
static struct websocket *websockets;

static int
ws_utf8_feed(struct ws_utf8 *u, const char *data, size_t len)
{
    size_t i;
    for (i = 0; i < len; ++i) {
        unsigned c = (unsigned char)data[i];
        if (u->left) {
            if ((c & 0xc0) != 0x80) return 0;
            u->value = (u->value << 6) | (c & 0x3f);
            if (!--u->left && (u->value < u->minimum || u->value > 0x10ffff ||
                              (u->value >= 0xd800 && u->value <= 0xdfff))) return 0;
        } else if (c < 0x80) {
            continue;
        } else if (c >= 0xc2 && c <= 0xdf) {
            u->value = c & 0x1f; u->minimum = 0x80; u->left = 1;
        } else if (c >= 0xe0 && c <= 0xef) {
            u->value = c & 0x0f; u->minimum = 0x800; u->left = 2;
        } else if (c >= 0xf0 && c <= 0xf4) {
            u->value = c & 7; u->minimum = 0x10000; u->left = 3;
        } else return 0;
    }
    return 1;
}

static int
ws_valid_close(long code)
{
    return (code >= 1000 && code <= 1014 && code != 1004 && code != 1005 && code != 1006) ||
           (code >= 3000 && code <= 4999);
}

static void
ws_event_set(const char *event)
{
    replace_text(&ws_event, event, strlen(event));
}

static void
ws_free_frames(struct websocket *w)
{
    struct ws_frame *f;
    while ((f = w->first)) {
        w->first = f->next;
        free(f);
    }
    w->last = NULL;
    w->queue_bytes = w->queue_storage = w->queue_frames = 0;
}

static void
ws_disconnect(struct websocket *w)
{
    if (w->attached) curl_multi_remove_handle(w->multi, w->easy);
    w->attached = 0;
    if (w->easy) curl_easy_cleanup(w->easy);
    if (w->multi) curl_multi_cleanup(w->multi);
    w->easy = NULL;
    w->multi = NULL;
    curl_slist_free_all(w->request_headers);
    w->request_headers = NULL;
    free(w->handshake.data);
    w->handshake.data = NULL;
    ws_free_frames(w);
}

static void
ws_destroy(struct websocket *w)
{
    struct websocket **p = &websockets;
    while (*p && *p != w) p = &(*p)->next;
    if (*p) *p = w->next;
    ws_disconnect(w);
    free(w->name);
    free(w);
}

static void
websocket_cleanup(void)
{
    while (websockets) ws_destroy(websockets);
}

static void
ws_fail(struct websocket *w, CURLcode code, const char *kind, const char *message)
{
    w->failure = code;
    w->failure_kind = kind;
    if (message != w->diagnostic)
        snprintf(w->diagnostic, sizeof(w->diagnostic), "%s", message);
    if (!w->close_received) w->close_code = 1006;
    ws_disconnect(w);
    ws_event_set("error");
}

static void
ws_snapshot(struct websocket *w)
{
    const char *state = w->failure ? "error" : !w->easy ? "closed" : w->closing ? "closing" : "open";
    replace_text(&ws_handle, w->name, strlen(w->name));
    replace_text(&ws_state, state, strlen(state));
    ws_queued_bytes = (zlong)w->queue_bytes;
    ws_queued_frames = (zlong)w->queue_frames;
    ws_close_code = w->close_code;
    replace_text(&ws_close_reason, w->close_reason, w->close_reason_len);
    if (w->failure) {
        curl_code = w->failure;
        set_error(w->failure_kind, w->diagnostic, (int)w->failure);
        ws_event_set("error");
    }
}

/* Internal control replies have two reserved slots and 250 reserved bytes.
 * Priority insertion never interrupts a frame already handed to libcurl. */
static int
ws_enqueue(struct websocket *w, const char *data, size_t len, unsigned flags, int internal)
{
    struct ws_frame *f;
    size_t cap = w->max_queue + (internal ? 250 : 0);
    if (w->queue_frames >= WS_FRAMES + (internal ? 2u : 0u) ||
        w->queue_storage > cap || len > cap - w->queue_storage) {
        set_error("queue-limit", "WebSocket send queue is full; poll before retrying", 2);
        return 0;
    }
    f = malloc(sizeof(*f) + len + 1);
    if (!f) {
        set_error("memory", "could not allocate WebSocket frame", 27);
        return 0;
    }
    memset(f, 0, sizeof(*f));
    f->len = len;
    f->flags = flags;
    memcpy(f->data, data, len);
    f->data[len] = 0;
    if (internal && w->first) {
        if (w->first->started) {
            f->next = w->first->next;
            w->first->next = f;
            if (w->last == w->first) w->last = f;
        } else {
            f->next = w->first;
            w->first = f;
        }
    } else {
        if (w->last) w->last->next = f;
        else w->first = f;
        w->last = f;
    }
    w->queue_frames++;
    w->queue_bytes += len;
    w->queue_storage += len;
    return 1;
}

/* One bounded send step. Keep storage through AGAIN and partial consumption. */
static int
ws_flush(struct websocket *w)
{
    struct ws_frame *f = w->first;
    size_t sent = 0, amount;
    CURLcode rc;
    if (!f || !w->easy) return 0;
    amount = f->len - f->sent;
    if (amount > WS_CHUNK) amount = WS_CHUNK;
    /* OFFSET lets each native call consume at most WS_CHUNK bytes. */
    rc = curl_ws_send(w->easy, f->data + f->sent, amount, &sent,
                      f->started ? 0 : (curl_off_t)f->len,
                      f->flags | (f->len ? CURLWS_OFFSET : 0));
    f->started = 1;
    if (sent > amount) {
        ws_fail(w, CURLE_SEND_ERROR, "transport", "libcurl reported an invalid send length");
        return 0;
    }
    f->sent += sent;
    w->queue_bytes -= sent;
    if (rc != CURLE_OK && rc != CURLE_AGAIN) {
        ws_fail(w, rc, "transport", curl_easy_strerror(rc));
        return 0;
    }
    if (rc == CURLE_OK && f->sent == f->len) {
        if (f->flags & CURLWS_CLOSE) w->close_sent = 1;
        w->first = f->next;
        if (!w->first) w->last = NULL;
        w->queue_frames--;
        w->queue_storage -= f->len;
        free(f);
        if (w->close_sent && w->close_received) ws_disconnect(w);
        return 1;
    }
    return sent != 0;
}

static int64_t
ws_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static CURLcode
ws_handshake(struct websocket *w, long timeout)
{
    int64_t deadline = ws_now() + timeout;
    CURLMcode mc = curl_multi_add_handle(w->multi, w->easy);
    if (mc != CURLM_OK) return CURLE_FAILED_INIT;
    w->attached = 1;
    for (;;) {
        int stop, running, remaining;
        int64_t wait_ms;
        CURLMsg *msg;
        unqueue_signals();
        stop = interrupted();
        queue_signals();
        if (stop) return CURLE_ABORTED_BY_CALLBACK;
        if (ws_now() >= deadline) return CURLE_OPERATION_TIMEDOUT;
        mc = curl_multi_perform(w->multi, &running);
        if (mc != CURLM_OK) return CURLE_FAILED_INIT;
        while ((msg = curl_multi_info_read(w->multi, &remaining)))
            if (msg->msg == CURLMSG_DONE) return msg->data.result;
        if (!running) return CURLE_FAILED_INIT;
        wait_ms = deadline - ws_now();
        if (wait_ms <= 0) return CURLE_OPERATION_TIMEDOUT;
        mc = curl_multi_poll(w->multi, NULL, 0, wait_ms > 100 ? 100 : (int)wait_ms, NULL);
        if (mc != CURLM_OK) return CURLE_FAILED_INIT;
    }
}

static struct websocket *
ws_open(const char *name, struct request *r, long max_queue, long max_message)
{
    struct websocket *w = calloc(1, sizeof(*w));
    CURLcode rc = CURLE_OUT_OF_MEMORY;
    long status = 0;
    char *url = NULL;
    if (!w) {
        set_error("memory", "could not allocate WebSocket handle", 27);
        return NULL;
    }
    w->name = strdup(name);
    w->easy = curl_easy_init();
    w->multi = curl_multi_init();
    w->max_queue = (size_t)max_queue;
    w->max_message = (size_t)max_message;
    w->handshake.limit = HEADER_LIMIT;
    w->request_headers = r->headers;
    r->headers = NULL;
    if (!w->name || !w->easy || !w->multi) goto done;
#define WSET(option, value) do { rc = curl_easy_setopt(w->easy, option, value); if (rc) goto done; } while (0)
    WSET(CURLOPT_URL, r->url);
    WSET(CURLOPT_PROTOCOLS_STR, "ws,wss");
    WSET(CURLOPT_FOLLOWLOCATION, 0L);
    WSET(CURLOPT_CONNECT_ONLY, 2L);
    WSET(CURLOPT_WS_OPTIONS, (long)CURLWS_NOAUTOPONG);
    WSET(CURLOPT_SSL_VERIFYPEER, 1L);
    WSET(CURLOPT_SSL_VERIFYHOST, 2L);
    WSET(CURLOPT_NOSIGNAL, 1L);
    WSET(CURLOPT_TIMEOUT_MS, r->timeout);
    WSET(CURLOPT_CONNECTTIMEOUT_MS, r->connect_timeout);
    WSET(CURLOPT_ERRORBUFFER, w->diagnostic);
    WSET(CURLOPT_HEADERFUNCTION, receive);
    WSET(CURLOPT_HEADERDATA, &w->handshake);
    WSET(CURLOPT_WRITEFUNCTION, receive);
    WSET(CURLOPT_WRITEDATA, &w->handshake);
    WSET(CURLOPT_HTTPHEADER, w->request_headers);
    if (r->ca) WSET(CURLOPT_CAINFO, r->ca);
    rc = ws_handshake(w, r->timeout);
    curl_easy_getinfo(w->easy, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_getinfo(w->easy, CURLINFO_EFFECTIVE_URL, &url);
    if (url) replace_text(&effective_url, url, strlen(url));
done:
    http_status = status;
    curl_code = rc;
    replace_text(&headers, w->handshake.data ? w->handshake.data : "", w->handshake.len);
    if (rc == CURLE_OK) {
        w->next = websockets;
        websockets = w;
        complete = 1;
        ws_event_set("open");
        return w;
    }
    set_error(w->handshake.failure == BUFFER_LIMIT ? "header-limit" :
              rc == CURLE_OUT_OF_MEMORY || w->handshake.failure == BUFFER_MEMORY ? "memory" : "transport",
              w->diagnostic[0] ? w->diagnostic : curl_easy_strerror(rc), (int)rc);
    ws_event_set("error");
    ws_destroy(w);
    return NULL;
#undef WSET
}

/* On peer close discard unstarted application frames. Finish only an already
 * started frame before replying, since RFC 6455 forbids interleaving frames. */
static void
ws_peer_close(struct websocket *w)
{
    struct ws_frame *active = w->first && w->first->started ? w->first : NULL;
    if (active) w->first = active->next;
    ws_free_frames(w);
    if (active) {
        active->next = NULL;
        w->first = w->last = active;
        w->queue_frames = 1;
        w->queue_bytes = active->len - active->sent;
        w->queue_storage = active->len;
    }
    if (!w->close_sent && !(active && (active->flags & CURLWS_CLOSE)) &&
        !ws_enqueue(w, (char *)w->control, w->control_len, CURLWS_CLOSE, 1))
        ws_fail(w, CURLE_OUT_OF_MEMORY, "memory", "could not queue close reply");
    if (w->close_sent) ws_disconnect(w);
}

/* Read one payload chunk. Control payloads are accumulated separately and
 * never disturb the data message's fragmentation/UTF-8 state. */
static int
ws_receive(struct websocket *w, size_t chunk)
{
    char data[WS_CHUNK];
    size_t n = 0;
    const struct curl_ws_frame *meta;
    struct curl_ws_frame m;
    CURLcode rc;
    unsigned type;
    if (!w->easy || w->close_received) return 0;
    rc = curl_ws_recv(w->easy, data, chunk, &n, &meta);
    if (rc == CURLE_AGAIN) return 0;
    if (rc != CURLE_OK) {
        ws_fail(w, rc, "transport", curl_easy_strerror(rc));
        return 1;
    }
    if (!meta) {
        ws_fail(w, CURLE_RECV_ERROR, "protocol", "missing WebSocket frame metadata");
        return 1;
    }
    m = *meta;
    type = m.flags & (CURLWS_TEXT | CURLWS_BINARY | CURLWS_PING | CURLWS_PONG | CURLWS_CLOSE);
    if (m.offset < 0 || m.bytesleft < 0 || !type || (type & (type - 1))) goto protocol;
    if (type & (CURLWS_PING | CURLWS_PONG | CURLWS_CLOSE)) {
        struct ws_utf8 u = {0};
        if ((m.flags & CURLWS_CONT) || m.offset != (curl_off_t)w->control_len ||
            n > 125 - w->control_len || m.bytesleft > (curl_off_t)(125 - w->control_len - n)) goto protocol;
        memcpy(w->control + w->control_len, data, n);
        w->control_len += n;
        if (m.bytesleft) return 2; /* Progress, but not yet a control event. */
        if (type == CURLWS_CLOSE) {
            if (w->control_len == 1) goto protocol;
            w->close_code = w->control_len ? (unsigned)w->control[0] * 256 + w->control[1] : 1005;
            if (w->control_len && (!ws_valid_close(w->close_code) ||
                !ws_utf8_feed(&u, (char *)w->control + 2, w->control_len - 2) || u.left)) goto protocol;
            w->close_reason_len = w->control_len ? w->control_len - 2 : 0;
            memcpy(w->close_reason, w->control + 2, w->close_reason_len);
            w->close_received = w->closing = 1;
            ws_peer_close(w);
        } else if (type == CURLWS_PING && !w->close_sent) {
            if (!ws_enqueue(w, (char *)w->control, w->control_len, CURLWS_PONG, 1)) {
                ws_fail(w, CURLE_OUT_OF_MEMORY, "queue-limit", "could not queue automatic pong");
                return 1;
            }
        }
        replace_text(&body, (char *)w->control, w->control_len);
        received_bytes = (zlong)w->control_len;
        w->control_len = 0;
        ws_event_set(type == CURLWS_PING ? "ping" : type == CURLWS_PONG ? "pong" : "close");
        replace_text(&ws_type, type == CURLWS_PING ? "ping" : type == CURLWS_PONG ? "pong" : "close", type == CURLWS_CLOSE ? 5 : 4);
        complete = 1;
        return 1;
    }
    if (w->recv_type && w->recv_type != type) goto protocol;
    w->recv_type = type;
    if (n > w->max_message - w->recv_message_bytes ||
        m.bytesleft > (curl_off_t)(w->max_message - w->recv_message_bytes - n)) {
        ws_fail(w, CURLE_WRITE_ERROR, "message-limit", "WebSocket message exceeds --max-message");
        return 1;
    }
    w->recv_message_bytes += n;
    ws_message_end = !m.bytesleft && !(m.flags & CURLWS_CONT);
    if (type == CURLWS_TEXT && (!ws_utf8_feed(&w->recv_utf8, data, n) ||
                                (ws_message_end && w->recv_utf8.left))) goto protocol;
    replace_text(&body, data, n);
    received_bytes = (zlong)n;
    replace_text(&ws_type, type == CURLWS_TEXT ? "text" : "binary", type == CURLWS_TEXT ? 4 : 6);
    ws_offset = (zlong)m.offset;
    ws_bytesleft = (zlong)m.bytesleft;
    ws_more = !!(m.flags & CURLWS_CONT);
    complete = ws_message_end;
    ws_event_set("data");
    if (ws_message_end) {
        w->recv_message_bytes = w->recv_type = 0;
        memset(&w->recv_utf8, 0, sizeof(w->recv_utf8));
    }
    return 1;
protocol:
    ws_fail(w, CURLE_RECV_ERROR, "protocol", "invalid WebSocket frame, close payload, or UTF-8 text");
    return 1;
}

static void
ws_poll(struct websocket *w, long timeout, size_t chunk, int receive_only)
{
    int64_t deadline = ws_now() + timeout;
    int steps;
    ws_event_set(w->easy ? "idle" : "closed");
    for (steps = 0; steps < WS_STEPS && w->easy; ++steps) {
        int stop, received, moved = 0;
        int64_t remaining;
        curl_socket_t socket;
        struct pollfd fd;
        unqueue_signals();
        stop = interrupted();
        queue_signals();
        if (stop) {
            /* Cancellation stops this poll, preserving the connection/queue. */
            curl_code = CURLE_ABORTED_BY_CALLBACK;
            set_error("interrupted", "WebSocket poll interrupted", 42);
            ws_event_set("interrupted");
            return;
        }
        if (!receive_only) moved = ws_flush(w);
        if (w->failure) return;
        if (!w->easy) { ws_event_set("closed"); return; }
        received = ws_receive(w, chunk);
        if (received == 1) return;
        if (received == 2) moved = 1;
        if (w->failure || receive_only) return;
        remaining = deadline - ws_now();
        if (remaining <= 0) return;
        if (moved) continue;
        if (curl_easy_getinfo(w->easy, CURLINFO_ACTIVESOCKET, &socket) != CURLE_OK || socket == CURL_SOCKET_BAD) {
            ws_fail(w, CURLE_RECV_ERROR, "transport", "WebSocket has no active socket");
            return;
        }
        fd.fd = socket;
        fd.events = POLLIN | (w->first ? POLLOUT : 0);
        fd.revents = 0;
        if (poll(&fd, 1, remaining > 100 ? 100 : (int)remaining) < 0 && errno != EINTR) {
            ws_fail(w, CURLE_RECV_ERROR, "transport", "WebSocket socket poll failed");
            return;
        }
    }
}

enum ws_operation { WS_OPEN, WS_SEND, WS_RECV, WS_POLL, WS_CLOSE, WS_DROP, WS_INFO };

static void
websocket_command(char **args)
{
    static const char *const operations[] = {"open", "send", "recv", "poll", "close", "drop", "info"};
    struct request r = {0};
    struct websocket *w = NULL, *p;
    char *op, *name, *type = "text", *reason = "";
    size_t data_len = 0, reason_len = 0, count = 0;
    char *data = "";
    long timeout = 0, max_queue = BODY_LIMIT, max_message = BODY_LIMIT, chunk = WS_CHUNK, close_code = 1000;
    unsigned seen = 0, flags = CURLWS_TEXT;
    int operation = -1, more = 0, end_options = 0;
    size_t i;
    r.timeout = 10000; r.connect_timeout = 3000;
    if (!args[0] || !(op = text_argument(*args++))) goto usage;
    for (i = 0; i < ARRAY_SIZE(operations); ++i)
        if (!strcmp(op, operations[i])) operation = (int)i;
    if (operation < 0 || !args[0] || !(name = text_argument(*args++)) ||
        !identifier(name) || strlen(name) > 64) goto usage;
    while (*args) {
        char *arg = text_argument(*args++), *value;
        unsigned bit;
        int allowed;
        if (!arg) goto usage;
        if (!end_options && !strcmp(arg, "--")) { end_options = 1; continue; }
        if (end_options || arg[0] != '-') {
            if (operation != WS_OPEN || r.url || !*arg) goto usage;
            r.url = arg; continue;
        }
        if (!strcmp(arg, "--result") || !strcmp(arg, "-r")) { bit = 1u; allowed = 1; }
        else if (!strcmp(arg, "--cacert") || !strcmp(arg, "-c")) { bit = 2u; allowed = operation == WS_OPEN; }
        else if (!strcmp(arg, "--header") || !strcmp(arg, "-H")) { bit = 4u; allowed = operation == WS_OPEN; }
        else if (!strcmp(arg, "--timeout") || !strcmp(arg, "-t")) { bit = 8u; allowed = operation == WS_OPEN || operation == WS_POLL; }
        else if (!strcmp(arg, "--connect-timeout")) { bit = 16u; allowed = operation == WS_OPEN; }
        else if (!strcmp(arg, "--max-queue")) { bit = 32u; allowed = operation == WS_OPEN; }
        else if (!strcmp(arg, "--max-message")) { bit = 64u; allowed = operation == WS_OPEN; }
        else if (!strcmp(arg, "--max-chunk")) { bit = 128u; allowed = operation == WS_POLL || operation == WS_RECV; }
        else if (!strcmp(arg, "--data") || !strcmp(arg, "-d")) { bit = 256u; allowed = operation == WS_SEND; }
        else if (!strcmp(arg, "--type")) { bit = 512u; allowed = operation == WS_SEND; }
        else if (!strcmp(arg, "--more")) { bit = 1024u; allowed = operation == WS_SEND; }
        else if (!strcmp(arg, "--code")) { bit = 2048u; allowed = operation == WS_CLOSE; }
        else if (!strcmp(arg, "--reason")) { bit = 4096u; allowed = operation == WS_CLOSE; }
        else goto usage;
        if (!allowed || (bit != 4u && (seen & bit))) goto usage;
        seen |= bit;
        if (bit == 1024u) { more = 1; continue; }
        if (!*args) goto usage;
        if (bit == 256u) { data = decode(*args++, &data_len); continue; }
        if (bit == 4096u) { reason = decode(*args++, &reason_len); continue; }
        if (!(value = text_argument(*args++))) goto usage;
        switch (bit) {
        case 1u: if (!result_parameter(value)) goto usage; r.result = value; break;
        case 2u: if (!*value) goto usage; r.ca = value; break;
        case 4u: if (!add_header(&r, value)) goto usage; break;
        case 8u:
            if (!decimal(value, operation == WS_OPEN ? 1 : 0, operation == WS_OPEN ? 600000 : 1000, &timeout)) goto usage;
            r.timeout = timeout; break;
        case 16u: if (!decimal(value, 1, 600000, &r.connect_timeout)) goto usage; break;
        case 32u: if (!decimal(value, 1, MAX_BODY_LIMIT, &max_queue)) goto usage; break;
        case 64u: if (!decimal(value, 1, MAX_BODY_LIMIT, &max_message)) goto usage; break;
        case 128u: if (!decimal(value, 1, WS_CHUNK, &chunk)) goto usage; break;
        case 512u: type = value; break;
        case 2048u: if (!decimal(value, 1000, 4999, &close_code) || !ws_valid_close(close_code)) goto usage; break;
        }
    }
    for (p = websockets; p; p = p->next) {
        if (!strcmp(p->name, name)) w = p;
        count++;
    }
    replace_text(&ws_handle, name, strlen(name));
    if (operation == WS_OPEN) {
        if (w || count >= WS_HANDLES || !r.url ||
            (strncasecmp(r.url, "ws://", 5) && strncasecmp(r.url, "wss://", 6))) goto usage;
        w = ws_open(name, &r, max_queue, max_message);
        goto done;
    }
    if (!w) goto usage;
    curl_code = CURLE_OK;
    if (operation == WS_DROP) {
        ws_snapshot(w);
        ws_destroy(w); w = NULL;
        clear_result();
        replace_text(&ws_handle, name, strlen(name));
        replace_text(&ws_state, "closed", 6);
        ws_event_set("dropped"); curl_code = 0; complete = 1;
        goto done;
    }
    if (operation == WS_INFO) { ws_event_set("info"); goto done; }
    if (operation == WS_POLL || operation == WS_RECV) {
        ws_poll(w, timeout, (size_t)chunk, operation == WS_RECV); goto done;
    }
    if (!w->easy || w->closing) {
        set_error("state", "WebSocket is not open for sending", 2); goto done;
    }
    if (operation == WS_CLOSE) {
        struct ws_utf8 u = {0};
        char payload[125];
        if (reason_len > 123 || !ws_utf8_feed(&u, reason, reason_len) || u.left) goto usage;
        payload[0] = (char)(close_code >> 8); payload[1] = (char)close_code;
        memcpy(payload + 2, reason, reason_len);
        if (ws_enqueue(w, payload, reason_len + 2, CURLWS_CLOSE, 0)) {
            w->closing = 1; ws_event_set("queued");
        }
        goto done;
    }
    if (!strcmp(type, "text")) flags = CURLWS_TEXT;
    else if (!strcmp(type, "binary")) flags = CURLWS_BINARY;
    else if (!strcmp(type, "ping")) flags = CURLWS_PING;
    else if (!strcmp(type, "pong")) flags = CURLWS_PONG;
    else goto usage;
    if (flags & (CURLWS_PING | CURLWS_PONG)) {
        if (more || data_len > 125) goto usage;
        if (ws_enqueue(w, data, data_len, flags, 0)) ws_event_set("queued");
    } else {
        struct ws_utf8 u = w->send_utf8;
        if (w->send_type && w->send_type != flags) goto usage;
        if (data_len > w->max_message - w->send_message_bytes) {
            set_error("message-limit", "WebSocket message exceeds --max-message", 2); goto done;
        }
        if (flags == CURLWS_TEXT && (!ws_utf8_feed(&u, data, data_len) || (!more && u.left))) goto usage;
        if (ws_enqueue(w, data, data_len, flags | (more ? CURLWS_CONT : 0), 0)) {
            w->send_type = more ? flags : 0;
            w->send_message_bytes = more ? w->send_message_bytes + data_len : 0;
            w->send_utf8 = more ? u : (struct ws_utf8){0};
            ws_event_set("queued");
        }
    }
    goto done;
usage:
    if (!return_status) set_error("usage", "invalid WebSocket operation, handle, option, or payload; see docs/websocket.md", 2);
done:
    if (w) ws_snapshot(w);
    if (r.result) publish_result(r.result, 1);
    curl_slist_free_all(r.headers);
}
