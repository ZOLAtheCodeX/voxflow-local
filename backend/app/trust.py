"""Trust boundary for the local backend.

The backend listens on loopback, but loopback alone does not keep a web page
or another local process out: DNS rebinding and ``no-cors`` browser requests
both reach 127.0.0.1. ``TrustBoundaryMiddleware`` is a pure-ASGI gate, applied
to every ``http`` and ``websocket`` scope before routing, that accepts only
requests that look like the VoxFlow app itself:

1. ``Host`` is exactly one loopback name (defeats DNS rebinding).
2. No browser marker headers (``Origin``, ``Sec-Fetch-Site``, ``Sec-Fetch-Mode``).
3. A per-launch ``X-VoxFlow-Token`` on every path except ``/v1/health``.
4. ``POST``/``PUT``/``PATCH`` carry a JSON ``Content-Type`` (a browser cannot
   send one cross-origin without a preflight).

Headers are read from the raw ``scope["headers"]`` list so duplicate headers
and arbitrary bytes are handled explicitly rather than collapsed or decoded.
The token is never logged.
"""

from __future__ import annotations

import functools
import hmac
import json
import logging
import os
import re
import secrets
from collections.abc import Callable, Mapping

from starlette.types import ASGIApp, Receive, Scope, Send

logger = logging.getLogger("voxflow")

TOKEN_HEADER: bytes = b"x-voxflow-token"
HEALTH_PATH: str = "/v1/health"
TOKEN_ENV_VAR = "VOXFLOW_API_TOKEN"

_TOKEN_PATTERN = re.compile(r"[0-9a-f]{64}")
_HOST_PATTERN = re.compile(rb"(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?", re.IGNORECASE)
_JSON_SUBTYPE_PATTERN = re.compile(rb"application/[^/\s]+\+json")
_BROWSER_MARKER_HEADERS = (b"origin", b"sec-fetch-site", b"sec-fetch-mode")
_BODY_METHODS = frozenset({"POST", "PUT", "PATCH"})

_INVALID_HOST = (400, "Invalid host")
_BROWSER_REQUEST = (403, "Browser requests are not accepted")
_INVALID_TOKEN = (401, "Missing or invalid token")
_BAD_CONTENT_TYPE = (415, "Content-Type must be application/json")


def resolve_active_token(env: Mapping[str, str] | None = None) -> str:
    """Return the token this backend process accepts.

    ``VOXFLOW_API_TOKEN``, when present, must be exactly 64 lowercase hex
    characters; anything else is a startup error. When absent, a fresh random
    token is generated. Not cached: see :func:`active_token`.
    """
    environ = os.environ if env is None else env
    configured = environ.get(TOKEN_ENV_VAR)
    if configured is None:
        return secrets.token_hex(32)
    if not _TOKEN_PATTERN.fullmatch(configured):
        # The value is deliberately not logged: it may be a near-miss of a real token.
        logger.error("%s must be exactly 64 lowercase hex characters", TOKEN_ENV_VAR)
        raise SystemExit(1)
    return configured


@functools.cache
def active_token() -> str:
    """The process-wide token, resolved once on first use."""
    return resolve_active_token()


def _header_values(headers: list[tuple[bytes, bytes]], name: bytes) -> list[bytes]:
    return [value for key, value in headers if key.lower() == name]


def _is_json_media_type(content_type: bytes) -> bool:
    media_type = content_type.split(b";", 1)[0].strip().lower()
    return media_type == b"application/json" or bool(_JSON_SUBTYPE_PATTERN.fullmatch(media_type))


class TrustBoundaryMiddleware:
    def __init__(self, app: ASGIApp, token_provider: Callable[[], str] = active_token) -> None:
        self.app = app
        self._token_provider = token_provider

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return

        rejection = self._check(scope)
        if rejection is None:
            await self.app(scope, receive, send)
            return

        (status, detail), check = rejection
        logger.debug(
            "trust boundary rejected %s %r: %s",
            scope.get("method", "WS"),
            scope.get("path", ""),
            check,
        )
        if scope["type"] == "websocket":
            await receive()  # the websocket.connect message
            await send({"type": "websocket.close", "code": 1008})
            return
        await self._send_json_error(send, status, detail)

    def _check(self, scope: Scope) -> tuple[tuple[int, str], str] | None:
        headers = scope["headers"]

        hosts = _header_values(headers, b"host")
        if len(hosts) != 1 or not _HOST_PATTERN.fullmatch(hosts[0]):
            return _INVALID_HOST, "host"

        if any(_header_values(headers, marker) for marker in _BROWSER_MARKER_HEADERS):
            return _BROWSER_REQUEST, "browser-marker"

        if scope["path"] != HEALTH_PATH:
            presented = _header_values(headers, TOKEN_HEADER)
            expected = self._token_provider().encode("ascii")
            if len(presented) != 1 or not hmac.compare_digest(presented[0], expected):
                return _INVALID_TOKEN, "token"

        if scope["type"] == "http" and scope["method"] in _BODY_METHODS:
            content_types = _header_values(headers, b"content-type")
            if len(content_types) != 1 or not _is_json_media_type(content_types[0]):
                return _BAD_CONTENT_TYPE, "content-type"

        return None

    @staticmethod
    async def _send_json_error(send: Send, status: int, detail: str) -> None:
        body = json.dumps({"detail": detail}).encode()
        await send(
            {
                "type": "http.response.start",
                "status": status,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode()),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})
