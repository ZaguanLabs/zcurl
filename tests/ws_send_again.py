"""Force EAGAIN before a frame's first payload byte through real libcurl."""
from pathlib import Path
import subprocess


def test(env, plain, tls):
    root = Path(__file__).resolve().parents[1]
    shim = root / 'build/tests/ws-send-again.so'
    if not shim.is_file():
        raise FileNotFoundError(f'{shim}: run make build/tests/ws-send-again.so')
    # ASan must remain first in the preload list. This probe runs separately
    # from Valgrind; the ordinary backpressure tests remain memory-checked.
    for key, server in [('ZCURL_TEST_HTTP', plain), ('ZCURL_TEST_HTTPS', tls)]:
        child = dict(env, ZCURL_TEST_WS_AGAIN=env[key].replace('http', 'ws', 1) + '/ws')
        child['LD_PRELOAD'] = ':'.join(filter(None, [env.get('LD_PRELOAD'), str(shim)]))
        before = len(server.ws_frames)
        result = subprocess.run(['zsh', '-df', str(root / 'tests/ws-send-again.zsh')],
                                env=child, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        assert 'AGAIN-PROBE first size=200000 code=81 sent=0 injected=1' in result.stderr, result.stderr
        assert 'AGAIN-PROBE retry size=0 code=0 sent=65536 injected=1' in result.stderr, result.stderr
        assert server.ws_frames[before:] == [('/ws', 2, True, b'x' * 200000),
                                             ('/ws', 1, True, b'recovered')]
    print('PASS: WS/WSS forced first-frame AGAIN with zero bytes sent, OFFSET retry and following frame')
