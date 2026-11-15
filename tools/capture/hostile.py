"""Answers a hostile or broken server could give, for the fakes (fake_bridge,
fake_sxm, fake_radio), so the harness can check that none of them reaches
the shell: POST /v1/fake/hostile {mode, paths} (fake_radio: GET
/fake/hostile?mode=…&paths=…), mode null to stop. For the paths starting
with one of paths (every one but the fake's own, without), the answer is:

    dense    1.2 MB of [0,0,…]: one array of 600,000 members, past the
             ~540,000 on which Qt 6.12's JSON.parse crashes the whole shell
    endless  [0,0,… without end, and no length said
    trickle  a byte every half second, for two minutes
"""
import json
import time

DENSE = b"[" + b"0," * 599999 + b"0]"


class Hostile:
    def __init__(self):
        self.mode, self.paths = None, []

    def set(self, settings):
        self.mode = settings.get("mode") or None
        paths = settings.get("paths") or []
        self.paths = paths.split(",") if isinstance(paths, str) else list(paths)
        return {"ok": True, "mode": self.mode, "paths": self.paths}

    def applies(self, path):
        return bool(self.mode) and "/fake/" not in path and (not self.paths or any(path.startswith(p) for p in self.paths))

    def answer(self, handler):
        """Sends the answer; True when there was one to send."""
        mode = self.mode
        handler.close_connection = True
        try:
            handler.send_response(200)
            handler.send_header("Content-Type", "application/json")
            if mode == "dense":
                handler.send_header("Content-Length", str(len(DENSE)))
                handler.end_headers()
                handler.wfile.write(DENSE)
            elif mode == "endless":
                handler.end_headers()
                handler.wfile.write(b"[")
                while True:
                    handler.wfile.write(b"0," * 65536)
            else:
                handler.end_headers()
                for _ in range(240):
                    handler.wfile.write(b" ")
                    handler.wfile.flush()
                    time.sleep(0.5)
        except (BrokenPipeError, ConnectionResetError):
            pass
        return True


def settings_from(body):
    return body if isinstance(body, dict) else json.loads(body or b"{}")
