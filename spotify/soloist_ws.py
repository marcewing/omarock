"""A small WebSocket client (RFC 6455) for Spotify Soloist's local API.

Soloist's API (ws://127.0.0.1:8731, its --ws) speaks JSON text frames: commands
go as {"type": "command", "command": NAME, ...}, and events come back. The
standard library has no WebSocket client, and this needs only text frames,
pings and close, unmasked from the server.
"""
import base64
import json
import os
import socket
import struct


class Closed(Exception):
    pass


class WebSocket:
    def __init__(self, host="127.0.0.1", port=8731, timeout=10, check=None):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        # Whatever holds the port gets what's sent: check, before anything is,
        # who's at the far end (check(sock): why not, or None).
        why = check(self.sock) if check else None
        if why:
            self.sock.close()
            raise Closed(why)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise Closed("no handshake")
            head += chunk
        status, self.buffer = head.split(b"\r\n\r\n", 1)
        if b" 101 " not in status.split(b"\r\n", 1)[0]:
            raise Closed("handshake refused: " + status.split(b"\r\n", 1)[0].decode(errors="replace"))
        self.sock.settimeout(None)

    def _read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise Closed("connection closed")
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def _send_frame(self, opcode, payload):
        header = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def send(self, message):
        self._send_frame(0x1, json.dumps(message).encode())

    def command(self, name, **args):
        self.send(dict({"type": "command", "command": name}, **args))

    def recv(self):
        """The next JSON message; answers pings; raises Closed at the end."""
        parts = []
        while True:
            b0, b1 = self._read(2)
            opcode, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            payload = self._read(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise Closed("closed by Soloist")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            parts.append(payload)
            if b0 & 0x80:
                return json.loads(b"".join(parts).decode())

    def close(self):
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        self.sock.close()
