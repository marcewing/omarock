#!/usr/bin/env python3
"""The Spotify Web API for omarock, as your own developer app.

Spotify's Soloist plays, and omarock controls it locally (its WebSocket API).
Soloist can't search or read the library, so omarock uses the Web API for
those, as a developer app you create (Development mode, with your account
its only user). It signs in with PKCE, which needs only the app's client ID: no
client secret is kept anywhere.

    spotify_web.py login               sign in once in the browser
    spotify_web.py get /me/player/devices
    spotify_web.py put /me/player/play?device_id=… '{"context_uri": …}'
    spotify_web.py post|delete PATH [JSON]

omarock-spotify imports it (call, authorize_url, finish_login). While that
service runs, it owns the sign-in's redirect port: sign in through it
(its /v1/login) rather than with `login` here.

Settings: ~/.config/omarock/spotify.json ({"clientId", "redirectUri"}).
Tokens: ~/.config/omarock/spotify-token.json (mode 600; never print it).
Spotify ends a sign-in 6 months after it was given; then log in again.
"""
import base64
import hashlib
import html
import http.client
import http.server
import json
import math
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CONFIG = Path.home() / ".config/omarock/spotify.json"
TOKENS = Path.home() / ".config/omarock/spotify-token.json"
API = "https://api.spotify.com/v1"
ACCOUNTS = "https://accounts.spotify.com"
# Search and details, the library and playlists (read and edit), and the
# player (starting an album at a song on Soloist).
SCOPES = " ".join([
    "user-read-private", "user-library-read", "user-library-modify", "user-follow-read",
    "playlist-read-private", "playlist-read-collaborative", "playlist-modify-private", "playlist-modify-public",
    "user-read-playback-state", "user-modify-playback-state", "user-read-currently-playing", "user-read-recently-played",
])


class NotSignedIn(Exception):
    """No sign-in, or Spotify refused to renew it (6 months on): sign in again."""


class ApiError(Exception):
    pass


def config():
    data = json.loads(CONFIG.read_text())
    if not data.get("clientId"):
        raise ApiError(f"No clientId in {CONFIG}")
    return data["clientId"], data.get("redirectUri", "http://127.0.0.1:8730/callback")


def save_tokens(data):
    # A name of its own: a sign-in (omarock-sp login) can save while the
    # service renews.
    tmp = TOKENS.with_name(f"{TOKENS.name}.{os.getpid()}-{threading.get_ident()}.new")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, TOKENS)


def token_request(fields):
    request = urllib.request.Request(ACCOUNTS + "/api/token", data=urllib.parse.urlencode(fields).encode(),
                                     headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(request, timeout=20) as reply:
            return json.load(reply)
    except urllib.error.HTTPError as e:
        text = e.read().decode(errors="replace")[:300]
        if e.code in (400, 401):
            raise NotSignedIn(f"Spotify refused the sign-in ({e.code}): {text}")
        raise ApiError(f"Spotify's token service said {e.code}: {text}")
    except (OSError, http.client.HTTPException) as e:
        # Not tried again: a renewal Spotify carried out may have replaced
        # the refresh token sent.
        raise unanswered(e)[1] from e


def unanswered(e):
    """(worth another try, the ApiError) for a request Spotify didn't answer.

    Spotify's servers now and then close a connection without answering
    (RemoteDisconnected), or don't answer in time."""
    cause = e.reason if isinstance(e, urllib.error.URLError) else e
    if isinstance(cause, TimeoutError):
        return False, ApiError("Spotify didn't answer in time; try again")
    if isinstance(cause, (ConnectionError, http.client.HTTPException)):
        return True, ApiError("Spotify closed the connection without answering; try again")
    return False, ApiError(f"Couldn't reach Spotify ({cause}); try again")


# Too many requests (429): Spotify says how long to wait (Retry-After, in
# seconds), and until then every request fails at once here. More of them
# would only keep the limit on.
paused_until = 0.0


def pause_for(retry_after, method, url):
    """The seconds a 429 asks for, now kept in paused_until."""
    global paused_until
    try:
        wait = max(1.0, float(retry_after))
    except (TypeError, ValueError):
        wait = 5.0
    now = time.monotonic()
    if paused_until <= now:
        print(f"omarock-spotify: Spotify said 429 (too many requests) to {method} "
              f"{urllib.parse.urlparse(url).path}: waiting {wait:.0f} s", file=sys.stderr, flush=True)
    paused_until = max(paused_until, now + wait)
    return wait


# Never as many as Spotify allows. Spotify doesn't say what its limit is,
# only that it counts an app's requests over 30 s (one developer's apps
# together), and less for apps in development mode; and it has shut apps out
# for hours after a burst. So at most 20 at once, then one a second: no more
# than 50 in any 30 s. Background work (filling in the queue's songs, the
# Top 100's searches) leaves 15 of the 20 for what you're looking at.
RATE, BURST, RESERVE = 1.0, 20, 15
pacing = threading.Lock()
due = 0.0  # when the next request is due at RATE (GCRA's arrival time)
turns = threading.local()  # .background: this thread's requests can wait


def take_turn():
    """Wait until a request may go."""
    global due
    background = getattr(turns, "background", False)
    ahead = (BURST - 1 - (RESERVE if background else 0)) / RATE
    while True:
        with pacing:
            now = time.monotonic()
            due = max(due, now)
            start = due - ahead
            if start <= now or not background:
                due += 1 / RATE
                break
        # Background work books no turn ahead, so it never queues in front
        # of what you're looking at.
        time.sleep(start - now)
    if start > now:
        time.sleep(start - now)


def not_paused():
    wait = paused_until - time.monotonic()
    if wait > 0:
        raise too_many(wait)


def too_many(wait):
    when = (f"{math.ceil(wait)} s" if wait < 120 else f"{round(wait / 60)} min" if wait < 7200
            else f"{round(wait / 3600)} h")
    return ApiError(f"Spotify says too many requests: try again in {when}")


def stored(data, previous=None):
    """Tokens as kept: Spotify may not send a new refresh token on refresh."""
    out = dict(previous or {})
    out.update({k: data[k] for k in ("access_token", "token_type", "scope") if k in data})
    if data.get("refresh_token"):
        out["refresh_token"] = data["refresh_token"]
        out["signed_in_at"] = int(time.time())
    out["expires_at"] = int(time.time()) + int(data.get("expires_in", 3600)) - 60
    return out


def authorize_url():
    """Spotify's sign-in page, and what finish_login needs to check its answer."""
    client_id, redirect = config()
    verifier = secrets.token_urlsafe(64)[:96]
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    url = ACCOUNTS + "/authorize?" + urllib.parse.urlencode({
        "client_id": client_id, "response_type": "code", "redirect_uri": redirect, "scope": SCOPES,
        "code_challenge_method": "S256", "code_challenge": challenge, "state": state})
    return url, {"verifier": verifier, "state": state}


def finish_login(code, pending):
    """The sign-in page's answer (its code): get and keep the tokens."""
    client_id, redirect = config()
    data = token_request({"grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                          "client_id": client_id, "code_verifier": pending["verifier"]})
    save_tokens(stored(data))
    return data.get("scope", "")


def login():
    _, redirect = config()
    target = urllib.parse.urlparse(redirect)
    url, pending = authorize_url()
    state = pending["state"]
    result = {}

    class Callback(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass

        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if urllib.parse.urlparse(self.path).path != target.path:
                self.send_response(404); self.end_headers(); return
            ok = query.get("state", [""])[0] == state and "code" in query
            result.update(code=query.get("code", [""])[0] if ok else "", error=query.get("error", ["state mismatch"])[0])
            body = ("<h2>omarock is signed in to Spotify.</h2><p>You can close this tab.</p>" if ok
                    else f"<h2>Spotify sign-in failed: {html.escape(result['error'])}</h2>").encode()
            self.send_response(200 if ok else 400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body)

    server = http.server.HTTPServer((target.hostname, target.port), Callback)
    print("Opening Spotify's sign-in page. If no browser opens, visit:\n" + url, flush=True)
    subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server.timeout = 300
    while not result:
        server.handle_request()
        if not result:
            sys.exit("No sign-in within 5 minutes")
    if not result.get("code"):
        sys.exit("Sign-in failed: " + result.get("error", ""))
    print("Signed in. Scopes: " + finish_login(result["code"], pending))


def signed_in_at():
    """When the sign-in was given (Spotify ends it 6 months on), or None."""
    try: return json.loads(TOKENS.read_text()).get("signed_in_at")
    except (OSError, ValueError): return None


# One renewal at a time. Requests that arrive together (the panel opening)
# would each renew, spending the refresh token, and race on the file.
renewing = threading.Lock()


def access_token():
    with renewing:
        if not TOKENS.exists():
            raise NotSignedIn("Not signed in to Spotify")
        tokens = json.loads(TOKENS.read_text())
        if time.time() < tokens.get("expires_at", 0):
            return tokens["access_token"]
        client_id, _ = config()
        data = token_request({"grant_type": "refresh_token", "refresh_token": tokens["refresh_token"], "client_id": client_id})
        tokens = stored(data, tokens)
        save_tokens(tokens)
        return tokens["access_token"]


def sign_out():
    """Forget the sign-in: the next request is NotSignedIn until a new one."""
    with renewing:
        TOKENS.unlink(missing_ok=True)


def call(method, path, body=None):
    """(status, JSON or text) for one Web API request; raises NotSignedIn, or
    ApiError when Spotify doesn't answer or says too many requests (a GET
    dropped unanswered, or asked to wait 2 s or less, is tried once more
    first: it changes nothing)."""
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else (b"" if method in ("PUT", "POST") else None)
    for attempt in (1, 2):
        not_paused()
        take_turn()
        not_paused()  # a 429 may have come while this waited its turn
        request = urllib.request.Request(url, data=data, method=method,
                                         headers={"Authorization": "Bearer " + access_token(), "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=20) as reply:
                text = reply.read().decode()
                return reply.status, json.loads(text) if text.strip() else None
        except urllib.error.HTTPError as e:
            text = e.read().decode(errors="replace")
            if e.code == 429:
                wait = pause_for(e.headers.get("Retry-After"), method, url)
                if method == "GET" and attempt == 1 and wait <= 2:
                    time.sleep(wait + 0.05)
                    continue
                raise too_many(wait) from None
            try:
                return e.code, json.loads(text)
            except ValueError:
                return e.code, text
        except (OSError, http.client.HTTPException) as e:
            again, error = unanswered(e)
            if not (again and method == "GET" and attempt == 1):
                raise error from e
            time.sleep(0.3)


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip()); return
    if sys.argv[1] == "login":
        login(); return
    method, path = sys.argv[1].upper(), sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    try:
        status, data = call(method, path, body)
    except (NotSignedIn, ApiError) as e:
        sys.exit(str(e))
    print(status)
    if data is not None: print(json.dumps(data, indent=2, ensure_ascii=False))
    sys.exit(0 if status < 400 else 1)


if __name__ == "__main__":
    main()
