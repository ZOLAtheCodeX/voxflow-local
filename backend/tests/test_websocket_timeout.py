"""WebSocket idle-timeout behaviour (Phase 5.4).

Verifies that ``/v1/events`` closes cleanly when a client connects and
then stays silent past the idle window. Uses FastAPI's TestClient with a
small monkey-patched timeout so the test runs in ~0.5s instead of 60.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import server


def test_websocket_idle_closes_cleanly(monkeypatch) -> None:
    """A client that connects and stays silent should be closed by the server."""
    # Shrink the idle window to keep the test fast.
    monkeypatch.setattr(server, "_WEBSOCKET_IDLE_TIMEOUT_S", 0.3)

    client = TestClient(server.app)
    with client.websocket_connect("/v1/events") as ws:
        # First message is the connect handshake the server sends.
        msg = ws.receive_json()
        assert msg.get("event") == "connected"

        # Now stay silent past the idle window. The server should close.
        # WebSocketTestSession raises WebSocketDisconnect on close.
        try:
            ws.receive_json()
        except WebSocketDisconnect as exc:
            assert exc.code == 1000, f"expected clean close 1000, got {exc.code}"
            return
        # If we got here we received another message — the close didn't happen.
        raise AssertionError("expected WebSocketDisconnect after idle timeout")


def test_websocket_acks_messages(monkeypatch) -> None:
    """Sanity: when the client sends messages, the server acks each one."""
    monkeypatch.setattr(server, "_WEBSOCKET_IDLE_TIMEOUT_S", 5.0)

    client = TestClient(server.app)
    with client.websocket_connect("/v1/events") as ws:
        connect_msg = ws.receive_json()
        assert connect_msg.get("event") == "connected"

        ws.send_text("ping")
        ack = ws.receive_json()
        assert ack.get("event") == "ack"

        ws.send_text("ping-2")
        ack2 = ws.receive_json()
        assert ack2.get("event") == "ack"


def test_websocket_close_after_peer_disconnect_does_not_raise() -> None:
    """The generic except path calls ``websocket.close()``, which itself
    raises if the peer already completed the close handshake (abrupt client
    disconnect). The handler must swallow that secondary failure — an
    unhandled exception here surfaces as a spurious 500-class ASGI error for
    a connection that is already gone."""
    import asyncio

    from api import endpoints as ep

    class _GoneWebSocket:
        async def accept(self) -> None:
            return None

        async def send_json(self, payload) -> None:
            return None

        async def receive_text(self) -> str:
            raise RuntimeError("client disconnected abruptly")

        async def close(self, code: int = 1000, reason: str | None = None) -> None:
            raise RuntimeError("Cannot call close once a close message has been sent")

    # Must complete without propagating the close() failure.
    asyncio.run(ep.events(_GoneWebSocket()))
