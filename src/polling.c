/* Included by zcurl.c. Shared explicit scheduling, without additional receive
 * queues: return immediately after consuming one WebSocket event. */
static unsigned poll_cursor;
static int poll_prefer_http;

static void
poll_channel(const char *channel)
{
    replace_text(&channel_text, channel, strlen(channel));
}

/* Wait on all pending HTTP pools and live WS sockets together. libcurl timers
 * and submission deadlines shorten the wait even when no socket is ready. */
static int
poll_wait(int64_t deadline)
{
    struct http_session *pools[HTTP_SESSIONS + 1];
    struct curl_waitfd extra[WS_HANDLES];
    struct pollfd sockets[WS_HANDLES];
    struct http_job *j;
    struct websocket *w;
    size_t count = 0, i;
    unsigned used = 0;
    int64_t remaining = deadline - monotonic_ms();
    for (j = http_jobs; j; j = j->next) {
        int64_t left;
        if (j->done) continue;
        left = j->deadline - monotonic_ms();
        if (left < remaining) remaining = left;
        for (i = 0; i < count; ++i)
            if (pools[i] == j->session) break;
        if (i == count) pools[count++] = j->session;
    }
    for (w = websockets; w; w = w->next) {
        curl_socket_t socket;
        if (!w->easy) continue;
        if (curl_easy_getinfo(w->easy, CURLINFO_ACTIVESOCKET, &socket) != CURLE_OK ||
            socket == CURL_SOCKET_BAD) {
            ws_fail(w, CURLE_RECV_ERROR, "transport", "WebSocket has no active socket");
            ws_snapshot(w);
            poll_channel("ws");
            return 0;
        }
        extra[used].fd = socket;
        extra[used].events = CURL_WAIT_POLLIN | (w->first ? CURL_WAIT_POLLOUT : 0);
        extra[used].revents = 0;
        sockets[used].fd = socket;
        sockets[used].events = POLLIN | (w->first ? POLLOUT : 0);
        sockets[used++].revents = 0;
    }
    if (!count && !used) return 0;
    if (remaining <= 0) return 1;
    if (remaining > 100) remaining = 100;
    if (count) {
        if (!http_wait_pools(pools, count, (int)remaining, extra, used)) {
            poll_channel("http");
            return 0;
        }
    } else if (poll(sockets, used, (int)remaining) < 0 && errno != EINTR) {
        set_error("transport", "shared socket poll failed; handles remain available", 2);
        ws_event_set("error");
        return 0;
    }
    return 1;
}

static void
poll_drive(long timeout, size_t chunk)
{
    int64_t deadline = monotonic_ms() + timeout;
    unsigned steps = 0;
    for (;;) {
        struct websocket *live[WS_HANDLES], *w;
        struct http_job *ready;
        unsigned count = 0, start, i;
        int moved = 0;
        clear_result();
        curl_code = CURLE_OK;
        ready = http_drive(0, NULL, 0);
        ++steps;
        if (return_status) { poll_channel("http"); return; }
        if (ready && poll_prefer_http) goto http_ready;
        for (w = websockets; w; w = w->next)
            if (w->easy) live[count++] = w;
        start = count ? poll_cursor % count : 0;
        for (i = 0; i < count && steps < 64; ++i) {
            unsigned index = (start + i) % count;
            int stop, received;
            w = live[index];
            unqueue_signals();
            stop = interrupted();
            queue_signals();
            if (stop) {
                curl_code = CURLE_ABORTED_BY_CALLBACK;
                set_error("interrupted", "shared polling interrupted; handles remain available", 42);
                ws_event_set("interrupted");
                return;
            }
            poll_cursor = index + 1;
            ++steps;
            moved |= ws_flush(w);
            if (w->failure || !w->easy) {
                if (!w->failure) ws_event_set("closed");
                goto ws_ready;
            }
            received = ws_receive(w, chunk);
            if (received == 1) goto ws_ready;
            moved |= received == 2;
            if (steps >= 64) break;
        }
        if (ready) goto http_ready;
        ws_event_set("idle");
        if (steps >= 64 || !timeout || monotonic_ms() >= deadline) return;
        if (!moved && !poll_wait(deadline)) return;
        continue;
ws_ready:
        ws_snapshot(w);
        poll_channel("ws");
        poll_prefer_http = 1;
        return;
http_ready:
        http_snapshot(ready, "ready");
        poll_channel("http");
        poll_prefer_http = 0;
        return;
    }
}

static void
polling_command(char **args)
{
    char *result = NULL;
    long timeout = 0, chunk = WS_CHUNK;
    unsigned seen = 0;
    while (*args) {
        char *option = text_argument(*args++), *value;
        unsigned bit;
        if (!option) goto usage;
        if (!strcmp(option, "--") && !*args) break;
        if (!strcmp(option, "--result") || !strcmp(option, "-r")) bit = 1;
        else if (!strcmp(option, "--timeout") || !strcmp(option, "-t")) bit = 2;
        else if (!strcmp(option, "--max-chunk")) bit = 4;
        else goto usage;
        if ((seen & bit) || !*args || !(value = text_argument(*args++))) goto usage;
        seen |= bit;
        if (bit == 1) {
            if (!result_parameter(value)) goto usage;
            result = value;
        } else if (!decimal(value, bit == 2 ? 0 : 1, bit == 2 ? 1000 : WS_CHUNK,
                            bit == 2 ? &timeout : &chunk)) goto usage;
    }
    poll_drive(timeout, (size_t)chunk);
    goto done;
usage:
    set_error("usage", "use zcurl poll [-t MS] [-r ARRAY] [--max-chunk BYTES]", 2);
done:
    if (result) publish_result(result, RESULT_POLL);
}
