"""Small RFC 6455 wire fixture, independent of libcurl and third-party packages."""
import base64
import hashlib
import socket
import struct
import time


def frame(opcode, payload=b"", fin=True):
    first = (0x80 if fin else 0) | opcode
    n = len(payload)
    if n < 126:
        header = bytes([first, n])
    elif n < 65536:
        header = bytes([first, 126]) + struct.pack("!H", n)
    else:
        header = bytes([first, 127]) + struct.pack("!Q", n)
    return header + payload


def serve(h):
    if h.path == "/ws-deny":
        h.send_error(403)
        return
    if h.path == "/ws-hang":
        h.server.slow_started.set()
        time.sleep(5)
        return
    key = h.headers["Sec-WebSocket-Key"]
    if h.path == '/ws-auth':
        assert h.headers.get('Authorization') == 'Bearer fixture-token', 'handshake authentication missing'
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    h.send_response(101)
    h.send_header("Upgrade", "websocket")
    h.send_header("Connection", "Upgrade")
    h.send_header("Sec-WebSocket-Accept", accept)
    h.end_headers()
    h.close_connection = True
    h.connection.settimeout(60)
    if h.path == "/ws-abort":
        return
    if h.path == "/ws-invalid-text":
        h.wfile.write(frame(1, b"\xed\xa0\x80"))
    if h.path == "/ws-invalid-close":
        h.wfile.write(frame(8, b"\x03\xed"))  # reserved 1005 on the wire
    if h.path == "/ws-big":
        h.wfile.write(frame(2, b"x" * 1000))
    if h.path == "/ws-close":
        h.wfile.write(frame(8, struct.pack("!H", 1001) + b"bye"))
    if h.path == "/ws-empty-close":
        h.wfile.write(frame(8))
    if h.path == "/ws-split":
        wire = frame(2, b"abcdef")
        h.wfile.write(wire[:4])
        time.sleep(0.3)
        h.wfile.write(wire[4:])
    if h.path == "/ws-push":
        h.wfile.write(frame(1, b"a\xe2", False) + frame(9, b"heartbeat\0") + frame(0, b"\x82\xac\n\n"))
    if h.path == "/ws-backpressure":
        time.sleep(0.3)
    if h.path == "/ws-stalled":
        # Bound the receive window and do not consume frames until the client
        # releases us over HTTP. No sleep can accidentally hide backpressure.
        h.connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
        h.server.ws_release.clear()
        h.wfile.write(frame(1, b"ready"))
        assert h.server.ws_release.wait(20), "stalled peer was never released"
    fragmented = None
    message = bytearray()
    while True:
        head = h.rfile.read(2)
        if not head:
            return
        assert len(head) == 2 and head[1] & 128, "client frame must be masked"
        opcode, fin, n = head[0] & 15, bool(head[0] & 128), head[1] & 127
        assert not head[0] & 112, "unexpected RSV bits"
        if n == 126:
            n = struct.unpack("!H", h.rfile.read(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", h.rfile.read(8))[0]
        assert n <= 9 * 1024 * 1024, "unbounded client frame"
        mask = h.rfile.read(4)
        payload = h.rfile.read(n)
        if len(mask) != 4 or len(payload) != n:
            return  # expected for drop/reset/unload mid-frame
        payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        with h.server.request_lock:
            h.server.ws_frames.append((h.path, opcode, fin, payload))
        if opcode in (8, 9, 10):
            assert fin and n <= 125, "invalid control frame"
            if opcode == 8:
                if h.path not in ("/ws-close", "/ws-empty-close"):
                    h.wfile.write(frame(8, payload))
                return
            if opcode == 9:
                h.wfile.write(frame(10, payload))
            continue
        if opcode == 0:
            assert fragmented is not None, "unexpected continuation"
        else:
            assert opcode in (1, 2) and fragmented is None, "interleaved data message"
            fragmented = opcode
        message.extend(payload)
        if fin:
            if fragmented == 1:
                message.decode("utf-8")
            message.clear()
            fragmented = None
        h.wfile.write(frame(opcode, payload, fin))
