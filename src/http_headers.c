/* Included by zcurl.c. Query saved raw headers without touching transfer state.
 * Signals remain queued throughout parsing and transactional publication. */
/* ASCII only: field-name matching must not depend on the shell's locale. */
static int
header_name_equal(const char *line, size_t length, const char *field, size_t field_length)
{
    size_t i;
    if (field_length != length) return 0;
    for (i = 0; i < length; ++i) {
        unsigned char a = line[i], b = field[i];
        if (a >= 'A' && a <= 'Z') a += 'a' - 'A';
        if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
        if (a != b) return 0;
    }
    return 1;
}

static int
header_status(const char *line, size_t length)
{
    size_t i = 5;
    int code;
    if (length < 10 || memcmp(line, "HTTP/", 5)) return 0;
    /* libcurl renders HTTP/1.x, HTTP/2 and HTTP/3 status lines here. */
    if (line[i] < '0' || line[i] > '9') return 0;
    while (i < length && line[i] >= '0' && line[i] <= '9') i++;
    if (i < length && line[i] == '.') {
        i++;
        if (i == length || line[i] < '0' || line[i] > '9') return 0;
        while (i < length && line[i] >= '0' && line[i] <= '9') i++;
    }
    if (length - i < 4 || line[i++] != ' ') return 0;
    if (line[i] < '1' || line[i] > '5' || line[i + 1] < '0' || line[i + 1] > '9' ||
        line[i + 2] < '0' || line[i + 2] > '9') return 0;
    code = (line[i] - '0') * 100 + (line[i + 1] - '0') * 10 + line[i + 2] - '0';
    i += 3;
    return i == length || line[i] == ' ' ? code : 0;
}

/* Compact selected values into storage no larger than the input. Folded lines
 * append in place, so even adversarial folding takes linear time and space. */
static int
parse_headers(char *raw, size_t length, const char *field, int trailers,
              char *storage, char **values, size_t *count)
{
    char *line = raw, *end = raw + length;
    size_t used = 0, field_length = strlen(field);
    int phase = 0, eligible = 0, previous = 0, matching = 0;
    *count = 0;
    while (line < end) {
        char *next = memchr(line, '\n', (size_t)(end - line));
        char *stop, *p, *value;
        size_t n;
        if (!next) return 0;
        stop = next;
        if (stop > line && stop[-1] == '\r') stop--;
        for (p = line; p < stop; ++p)
            if (((unsigned char)*p < 32 && *p != '\t') || (unsigned char)*p == 127) return 0;
        n = (size_t)(stop - line);
        if (!n) {
            if (!phase || phase == 3) return 0;
            phase++;
            previous = matching = 0;
        } else if (n >= 5 && !memcmp(line, "HTTP/", 5)) {
            int code = header_status(line, n);
            if (!code || phase == 1) return 0;
            phase = 1;
            eligible = code >= 200 || code == 101;
            previous = matching = 0;
            used = *count = 0;
        } else {
            if (!phase || phase == 3) return 0;
            if (*line == ' ' || *line == '\t') {
                if (!previous) return 0;
                value = line;
            } else {
                p = memchr(line, ':', n);
                if (!p || !token(line, (size_t)(p - line))) return 0;
                matching = eligible && (phase == (trailers ? 2 : 1)) &&
                    header_name_equal(line, (size_t)(p - line), field, field_length);
                previous = 1;
                value = p + 1;
                if (matching) values[(*count)++] = storage + used;
            }
            while (value < stop && (*value == ' ' || *value == '\t')) value++;
            while (stop > value && (stop[-1] == ' ' || stop[-1] == '\t')) stop--;
            if (matching) {
                n = (size_t)(stop - value);
                if (*line == ' ' || *line == '\t') {
                    if (!n) { line = next + 1; continue; }
                    if (storage + used - 1 == values[*count - 1]) used--;
                    else storage[used - 1] = ' ';
                }
                memcpy(storage + used, value, n);
                used += n;
                storage[used++] = '\0';
            }
        }
        line = next + 1;
    }
    return 1;
}

static int
headers_command(char **args)
{
    char *field, *raw = NULL, *target = NULL, *storage = NULL, **values = NULL, **published;
    size_t length = 0, count = 0, i;
    unsigned seen = 0;
    const char *message = "use zcurl headers FIELD --from RAW --result ARRAY [--trailers]";
    int result = 2;
    if (!*args || !(field = text_argument(*args++)) || !token(field, strlen(field))) goto done;
    while (*args) {
        char *option = text_argument(*args++);
        unsigned bit;
        if (!option) goto done;
        if (!strcmp(option, "--from")) bit = 1;
        else if (!strcmp(option, "--result") || !strcmp(option, "-r")) bit = 2;
        else if (!strcmp(option, "--trailers")) bit = 4;
        else goto done;
        if (seen & bit) goto done;
        seen |= bit;
        if (bit == 4) continue;
        if (!*args) goto done;
        if (bit == 1) {
            raw = decode(*args++, &length);
            if (length > HEADER_LIMIT || memchr(raw, '\0', length)) {
                message = "header input must be at most 256 KiB with no NUL bytes";
                goto done;
            }
        } else {
            target = text_argument(*args++);
            if (!target || !indexed_result_parameter(target)) {
                message = "--result requires a declared writable ordinary indexed array without converting or unique attributes";
                goto done;
            }
        }
    }
    if ((seen & 3) != 3) goto done;
    storage = malloc(length + 1);
    /* The shortest field line is "a:\n"; this also accommodates an empty result. */
    values = malloc((length / 3 + 1) * sizeof(*values));
    if (!storage || !values) {
        message = "could not allocate header lookup storage";
        result = 27;
        goto done;
    }
    if (!parse_headers(raw, length, field, !!(seen & 4), storage, values, &count)) {
        message = "malformed HTTP header input; expected complete status/field lines";
        goto done;
    }
    published = zalloc((count + 1) * sizeof(*published));
    for (i = 0; i < count; ++i)
        published[i] = metafy(values[i], (int)strlen(values[i]), META_DUP);
    published[count] = NULL;
    if (!setaparam(target, published)) {
        message = "could not publish header values";
        goto done;
    }
    result = 0;
done:
    free(storage);
    free(values);
    if (result) zwarnnam("zcurl headers", "%s", message);
    return result;
}
