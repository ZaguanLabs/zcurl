/* Test-only Linux interposer: block actual socket writes during the first
 * nonempty curl_ws_send. The real libcurl encoder must retain its state.
 * Never fake curl_ws_send's result: that would miss the boundary under test. */
#define _GNU_SOURCE
#include <curl/curl.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>

static int block_send, injected, retry;

ssize_t send(int fd, const void *buffer, size_t length, int flags)
{
    static ssize_t (*real_send)(int, const void *, size_t, int);
    if (!real_send) real_send = dlsym(RTLD_NEXT, "send");
    if (!real_send) abort();
    if (block_send) {
        injected = 1;
        errno = EAGAIN;
        return -1;
    }
    return real_send(fd, buffer, length, flags);
}

CURLcode curl_ws_send(CURL *easy, const void *buffer, size_t length,
                      size_t *sent, curl_off_t fragsize, unsigned flags)
{
    static CURLcode (*real_ws_send)(CURL *, const void *, size_t, size_t *, curl_off_t, unsigned);
    CURLcode rc;
    int forced;
    if (!real_ws_send) {
        void *library = dlopen("libcurl.so.4", RTLD_NOW);
        if (!library) abort();
        real_ws_send = dlsym(library, "curl_ws_send");
        if (!real_ws_send) abort();
    }
    forced = block_send = !injected && length > 0;
    rc = real_ws_send(easy, buffer, length, sent, fragsize, flags);
    block_send = 0;
    if (forced || retry)
        fprintf(stderr, "AGAIN-PROBE %s size=%lld code=%d sent=%zu injected=%d\n",
                forced ? "first" : "retry", (long long)fragsize, (int)rc, *sent, injected);
    retry = forced;
    return rc;
}
