"""Tests for the backend trust boundary (``trust.TrustBoundaryMiddleware``).

The middleware is exercised against a tiny in-test app so these tests pin its
contract independent of the real VoxFlow routes. Cases a TestClient cannot
express (missing or duplicate Host, non-ASCII bytes, body-read checks) call the
middleware directly with a hand-built ASGI scope.
"""

import re

import pytest
from fastapi import FastAPI, WebSocket
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect
from trust import TrustBoundaryMiddleware, resolve_active_token

TOKEN = "ab" * 32
AUTH = {"X-VoxFlow-Token": TOKEN}


def _build_tiny_app() -> FastAPI:
    app = FastAPI()

    @app.get("/v1/health")
    async def health():
        return {"ok": True}

    @app.get("/v1/ready")
    async def ready():
        return {"ok": True}

    @app.post("/v1/echo")
    async def echo(payload: dict):
        return payload

    @app.websocket("/v1/events")
    async def events(ws: WebSocket):
        await ws.accept()
        await ws.send_json({"event": "connected"})

    return app


def _wrap(app) -> TrustBoundaryMiddleware:
    return TrustBoundaryMiddleware(app, token_provider=lambda: TOKEN)


@pytest.fixture
def client():
    return TestClient(_wrap(_build_tiny_app()), base_url="http://127.0.0.1:8765")


# ── Hand-built ASGI helpers ───────────────────────────────────────────


def http_scope(
    path: str = "/v1/health",
    method: str = "GET",
    headers: list[tuple[bytes, bytes]] | None = None,
) -> dict:
    return {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": method,
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "root_path": "",
        "headers": list(headers) if headers is not None else [],
        "client": ("127.0.0.1", 50000),
        "server": ("127.0.0.1", 8765),
    }


async def empty_receive():
    return {"type": "http.request", "body": b"", "more_body": False}


async def receive_that_fails():
    pytest.fail("the middleware read the request body while rejecting")


async def raw_status(scope: dict, receive=empty_receive) -> int:
    sent: list[dict] = []

    async def send(message):
        sent.append(message)

    await _wrap(_build_tiny_app())(scope, receive, send)
    start = next(m for m in sent if m["type"] == "http.response.start")
    return start["status"]


# ── Host check ────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "host", ["evil.example:8765", "localhost.", "127.0.0.2", "::1:8765", "evil.example"]
)
def test_bad_host_is_400_even_on_health(client, host):
    for path in ("/v1/health", "/v1/ready"):
        r = client.get(path, headers={**AUTH, "Host": host})
        assert r.status_code == 400
        assert r.json() == {"detail": "Invalid host"}


@pytest.mark.parametrize(
    "host", ["LOCALHOST:8765", "localhost:9000", "[::1]", "[::1]:8765", "127.0.0.1"]
)
def test_loopback_hosts_pass(client, host):
    assert client.get("/v1/ready", headers={**AUTH, "Host": host}).status_code == 200


@pytest.mark.anyio
async def test_missing_or_duplicate_host_is_400():
    assert await raw_status(http_scope(headers=[(b"x-voxflow-token", TOKEN.encode())])) == 400
    dup = [
        (b"host", b"127.0.0.1:8765"),
        (b"host", b"evil.example"),
        (b"x-voxflow-token", TOKEN.encode()),
    ]
    assert await raw_status(http_scope(headers=dup)) == 400


# ── Browser markers ───────────────────────────────────────────────────


@pytest.mark.parametrize(
    "header",
    [
        ("Origin", "http://127.0.0.1"),
        ("Origin", "null"),
        ("Sec-Fetch-Site", "cross-site"),
        ("Sec-Fetch-Mode", "no-cors"),
    ],
)
def test_browser_markers_are_403_even_with_token(client, header):
    assert client.get("/v1/health", headers=dict([header])).status_code == 403
    r = client.post("/v1/echo", json={"x": 1}, headers={**AUTH, header[0]: header[1]})
    assert r.status_code == 403
    assert r.json() == {"detail": "Browser requests are not accepted"}


# ── Token ─────────────────────────────────────────────────────────────


def test_token_rules(client):
    assert client.get("/v1/ready").status_code == 401
    assert client.get("/v1/ready", headers={"X-VoxFlow-Token": "cd" * 32}).status_code == 401
    assert client.get("/v1/ready", headers=AUTH).status_code == 200
    assert client.get("/v1/health").status_code == 200
    assert client.get("/v1/health/x").status_code == 401  # exact-path exemption only


def test_token_rejection_body(client):
    r = client.get("/v1/ready")
    assert r.json() == {"detail": "Missing or invalid token"}


@pytest.mark.anyio
async def test_non_ascii_or_duplicate_token_is_401_not_500():
    base = [(b"host", b"127.0.0.1:8765")]
    bad_bytes = base + [(b"x-voxflow-token", b"\xff" * 64)]
    assert await raw_status(http_scope("/v1/ready", headers=bad_bytes)) == 401
    two = base + [(b"x-voxflow-token", TOKEN.encode()), (b"x-voxflow-token", TOKEN.encode())]
    assert await raw_status(http_scope("/v1/ready", headers=two)) == 401


# ── Content type ──────────────────────────────────────────────────────


@pytest.mark.parametrize("ctype", [None, "text/plain", "+json", "text/plain;charset=UTF-8"])
def test_post_without_json_content_type_is_415(client, ctype):
    headers = {**AUTH, **({"Content-Type": ctype} if ctype else {})}
    r = client.post("/v1/echo", content=b'{"x": 1}', headers=headers)
    assert r.status_code == 415
    assert r.json() == {"detail": "Content-Type must be application/json"}


@pytest.mark.parametrize(
    "ctype", ["application/json; charset=utf-8", "application/vnd.voxflow+json"]
)
def test_json_content_types_pass(client, ctype):
    r = client.post("/v1/echo", content=b'{"x": 1}', headers={**AUTH, "Content-Type": ctype})
    assert r.status_code == 200


@pytest.mark.anyio
async def test_duplicate_content_type_is_415():
    scope = http_scope(
        "/v1/echo",
        method="POST",
        headers=[
            (b"host", b"127.0.0.1:8765"),
            (b"x-voxflow-token", TOKEN.encode()),
            (b"content-type", b"application/json"),
            (b"content-type", b"text/plain"),
        ],
    )
    assert await raw_status(scope) == 415


# ── WebSocket ─────────────────────────────────────────────────────────

# TestClient only applies base_url to HTTP calls: websocket_connect sends
# Host "testserver", so every WebSocket case sets the loopback Host itself.
WS_HOST = {"Host": "127.0.0.1:8765"}


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"X-VoxFlow-Token": "cd" * 32},
        {**AUTH, "Origin": "http://127.0.0.1"},
        {**AUTH, "Host": "evil.example"},
    ],
)
def test_websocket_rejections_close_1008(client, headers):
    with pytest.raises(WebSocketDisconnect) as exc:
        with client.websocket_connect("/v1/events", headers={**WS_HOST, **headers}) as ws:
            ws.receive_json()
    assert exc.value.code == 1008


def test_websocket_with_token_connects(client):
    with client.websocket_connect("/v1/events", headers={**WS_HOST, **AUTH}) as ws:
        assert ws.receive_json() == {"event": "connected"}


# ── Body handling ─────────────────────────────────────────────────────


@pytest.mark.anyio
async def test_rejected_request_never_reads_body():
    # receive() fails the test if awaited: rejection must come from headers alone
    status = await raw_status(
        http_scope("/v1/echo", method="POST", headers=[(b"host", b"127.0.0.1:8765")]),
        receive=receive_that_fails,
    )
    assert status == 401


@pytest.mark.anyio
async def test_accepted_request_body_reaches_app_unread():
    seen: list[dict] = []

    async def recording_app(scope, receive, send):
        while True:
            message = await receive()
            seen.append(message)
            if not message.get("more_body", False):
                break
        await send({"type": "http.response.start", "status": 204, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    body = b'{"x": 1}'
    delivered = [{"type": "http.request", "body": body, "more_body": False}]

    async def receive():
        return delivered.pop(0)

    sent: list[dict] = []

    async def send(message):
        sent.append(message)

    scope = http_scope(
        "/v1/echo",
        method="POST",
        headers=[
            (b"host", b"127.0.0.1:8765"),
            (b"x-voxflow-token", TOKEN.encode()),
            (b"content-type", b"application/json"),
        ],
    )
    await _wrap(recording_app)(scope, receive, send)

    assert b"".join(m.get("body", b"") for m in seen) == body
    assert sent[0]["status"] == 204


@pytest.mark.anyio
async def test_lifespan_scope_passes_through():
    reached: list[str] = []

    async def inner(scope, receive, send):
        reached.append(scope["type"])

    await _wrap(inner)({"type": "lifespan"}, empty_receive, None)
    assert reached == ["lifespan"]


# ── Token resolution ──────────────────────────────────────────────────


def test_resolve_active_token():
    assert resolve_active_token({"VOXFLOW_API_TOKEN": "ab" * 32}) == "ab" * 32
    assert re.fullmatch(r"[0-9a-f]{64}", resolve_active_token({}))
    for bad in ("short", "AB" * 32, "ab" * 31 + "z1", " " * 64):
        with pytest.raises(SystemExit):
            resolve_active_token({"VOXFLOW_API_TOKEN": bad})


def test_malformed_token_is_never_logged(caplog):
    secret = "Not-A-Valid-Token-But-Secret"
    with caplog.at_level("DEBUG", logger="voxflow"):
        with pytest.raises(SystemExit):
            resolve_active_token({"VOXFLOW_API_TOKEN": secret})
    assert secret not in caplog.text
    assert caplog.text  # an error was logged
