"""Independent gzip/deflate wire fixtures and decoded file assertions."""
import gzip
from pathlib import Path
import zlib


BINARY = bytes(range(256)) + b'\n\n'


def serve(handler, request_body):
    kind = handler.path.removeprefix('/compressed/')
    data = b'x' * (8 * 1024 * 1024 + 1) if kind == 'large' else BINARY
    if kind == 'echo':
        data = request_body
    if kind == 'identity':
        wire, encoding = data, None
    elif kind == 'deflate':
        wire, encoding = zlib.compress(data), 'deflate'
    elif kind == 'unknown':
        wire, encoding = data, 'zcurl-unknown'
    elif kind == 'corrupt':
        wire, encoding = b'not a gzip stream', 'gzip'
    else:
        wire, encoding = gzip.compress(data, mtime=0), 'gzip'
    handler.send_response(404 if kind == 'missing' else 200)
    handler.send_header('Content-Length', str(len(wire)))
    if encoding:
        handler.send_header('Content-Encoding', encoding)
    handler.send_header('X-Observed-Encoding', handler.headers.get('Accept-Encoding', '<absent>'))
    handler.end_headers()
    if handler.command != 'HEAD':
        handler.wfile.write(wire)


def test(env, plain, temp, run):
    (temp / 'compression-input.bin').write_bytes(BINARY)
    before = plain.request_count
    print(run(env, (Path(__file__).with_suffix('.zsh')).read_text()))
    assert plain.request_count == before + 19, 'unexpected compression HTTP request count'
    for name in ('sync', 'async', 'echo', 'deflate', 'identity', 'missing'):
        assert (temp / f'compression-{name}.bin').read_bytes() == BINARY, name
    raw = (temp / 'compression-raw.bin').read_bytes()
    assert raw == gzip.compress(BINARY, mtime=0), 'unsolicited gzip was decoded without opt-in'
    limited = (temp / 'compression-limit.bin').read_bytes()
    assert len(limited) <= 32768 and limited == b'x' * len(limited)
    assert not (temp / 'compression-corrupt.bin').read_bytes()
    print('PASS: decoded gzip/deflate binary files, raw default, upload round trip and expansion bounds')
