"""OpenHost auth-proxy sidecar for FitTrackee.

FitTrackee is a localStorage-JWT single-page app served by gunicorn/Flask:
the backend issues HS256 JWTs (``sub`` = user id, signed with APP_SECRET_KEY)
which the Vue SPA stores in ``localStorage.authToken`` and sends as
``Authorization: Bearer``. There is no session cookie and no REMOTE_USER /
header auth, so cookie/header injection doesn't apply.

This proxy bridges OpenHost SSO into FitTrackee's own JWT scheme:

  * It fronts gunicorn (127.0.0.1:5000) on the OpenHost-routed port and proxies
    everything through (API + SPA + assets).
  * On an owner HTML navigation (router-stamped ``X-OpenHost-Is-Owner: true``),
    it injects a bootstrap ``<script>`` into the returned ``index.html``. That
    script, only when no ``authToken`` is present, fetches ``/_openhost/sso``,
    writes the returned token into ``localStorage.authToken`` and reloads — so
    the owner lands already logged-in (FitTrackee's CHECK_AUTH_USER picks the
    token up on load and fetches the profile automatically).
  * ``/_openhost/sso`` (served here, never proxied) verifies the owner header
    and mints an HS256 JWT with ``sub`` = the owner's user id (provisioned by
    start.sh via ``ftcli users create``), signed with the same APP_SECRET_KEY
    gunicorn validates against.

Security model:
  * ``X-OpenHost-Is-Owner`` is trusted because the OpenHost router strips any
    client-supplied ``X-OpenHost-*`` and only re-adds it after verifying the
    zone_auth session. We only mint a token on the owner branch.
  * No user password is ever written to disk (the ftcli-created account uses a
    throwaway random password, discarded immediately). Owner auth is JWT-only.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import http.client
import json
import logging
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("AUTH_PROXY_LISTEN_PORT", "8080"))
BACKEND_HOST = os.environ.get("BACKEND_HOST", "127.0.0.1")
BACKEND_PORT = int(os.environ.get("BACKEND_PORT", "5000"))

JWT_SECRET = os.environ.get("JWT_SECRET", "")
OWNER_ID = int(os.environ.get("OWNER_ID", "1"))
# FitTrackee's TOKEN_EXPIRATION_DAYS default is 30d; match roughly.
ACCESS_TTL = int(os.environ.get("SSO_TOKEN_TTL", str(30 * 24 * 3600)))

OWNER_HEADER = "X-OpenHost-Is-Owner"

HOP_BY_HOP = frozenset(
    h.lower()
    for h in (
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "host",
    )
)

logging.basicConfig(
    level=os.environ.get("AUTH_PROXY_LOG_LEVEL", "INFO"),
    format="[auth-proxy] %(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("auth_proxy")

_BOOTSTRAP = b"""
<script>
(function () {
  try {
    if (window.localStorage.getItem('authToken')) return;
    if (window.sessionStorage.getItem('__oh_sso_tried')) return;
    window.sessionStorage.setItem('__oh_sso_tried', '1');
    fetch('/_openhost/sso', { headers: { 'Accept': 'application/json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) {
        if (!d || !d.auth_token) return;
        window.localStorage.setItem('authToken', d.auth_token);
        window.location.replace('/');
      })
      .catch(function () {});
  } catch (e) {}
})();
</script>
"""


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def mint_jwt(user_id: int, ttl: int) -> str:
    """Mint an HS256 JWT matching FitTrackee's token shape (sub=user id)."""
    now = int(time.time())
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {"exp": now + ttl, "iat": now, "sub": str(user_id)}
    signing_input = (
        _b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + _b64url(json.dumps(payload, separators=(",", ":")).encode())
    ).encode("ascii")
    sig = hmac.new(JWT_SECRET.encode(), signing_input, hashlib.sha256).digest()
    return signing_input.decode("ascii") + "." + _b64url(sig)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "openhost-fittrackee-authproxy"

    def log_message(self, fmt: str, *args: object) -> None:
        log.debug("%s - %s", self.address_string(), fmt % args)

    def _send_bytes(self, status: int, body: bytes, ctype: str,
                    extra: dict | None = None) -> None:
        self.close_connection = True
        self.send_response_only(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _is_owner(self) -> bool:
        return self.headers.get(OWNER_HEADER, "").strip().lower() == "true"

    def _handle_sso(self) -> None:
        if not self._is_owner():
            self._send_bytes(403, b'{"error":"not owner"}', "application/json")
            return
        if not JWT_SECRET:
            self._send_bytes(500, b'{"error":"no secret"}', "application/json")
            return
        token = mint_jwt(OWNER_ID, ACCESS_TTL)
        body = json.dumps({"auth_token": token}).encode()
        self._send_bytes(200, body, "application/json",
                         {"Cache-Control": "no-store"})

    def _proxy(self) -> None:
        forwarded_host = self.headers.get("X-Forwarded-Host")
        forwarded_proto = self.headers.get("X-Forwarded-Proto", "https")

        out_headers: list[tuple[str, str]] = []
        for key, value in self.headers.items():
            kl = key.lower()
            if kl in HOP_BY_HOP or kl == "content-length":
                continue
            out_headers.append((key, value))
        host_val = forwarded_host or self.headers.get("Host") \
            or f"{BACKEND_HOST}:{BACKEND_PORT}"
        out_headers.append(("Host", host_val))
        out_headers.append(("X-Forwarded-Proto", forwarded_proto))

        body = None
        length = self.headers.get("Content-Length")
        if length:
            try:
                body = self.rfile.read(int(length))
            except (ValueError, OSError):
                self._send_bytes(400, b"bad body", "text/plain")
                return
        try:
            conn = http.client.HTTPConnection(BACKEND_HOST, BACKEND_PORT,
                                              timeout=120)
            conn.putrequest(self.command, self.path, skip_host=True,
                            skip_accept_encoding=True)
            for k, v in out_headers:
                conn.putheader(k, v)
            if body is not None:
                conn.putheader("Content-Length", str(len(body)))
            conn.endheaders()
            if body:
                conn.send(body)
            resp = conn.getresponse()
            data = resp.read()
        except (OSError, http.client.HTTPException) as exc:
            log.warning("backend error: %s", exc)
            self._send_bytes(502, b"upstream error", "text/plain")
            return

        ctype = resp.getheader("Content-Type", "")
        inject = (
            self.command == "GET"
            and self._is_owner()
            and "text/html" in ctype.lower()
            and b"</head>" in data
        )
        if inject:
            data = data.replace(b"</head>", _BOOTSTRAP + b"</head>", 1)

        self.close_connection = True
        self.send_response_only(resp.status, resp.reason)
        for k, v in resp.getheaders():
            kl = k.lower()
            if kl in HOP_BY_HOP or kl == "content-length" or kl == "content-encoding":
                # We buffered + possibly rewrote the body; drop framing/encoding
                # headers and set our own Content-Length below.
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        if inject:
            self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        conn.close()

    def _handle(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/_healthz":
            self._send_bytes(200, b"ok", "text/plain")
            return
        if path == "/_openhost/sso":
            self._handle_sso()
            return
        self._proxy()

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_PATCH = _handle
    do_HEAD = _handle
    do_OPTIONS = _handle


def main() -> None:
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    httpd.daemon_threads = True
    log.info("listening on %s:%d -> backend %s:%d (owner_id=%d)",
             LISTEN_HOST, LISTEN_PORT, BACKEND_HOST, BACKEND_PORT, OWNER_ID)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
