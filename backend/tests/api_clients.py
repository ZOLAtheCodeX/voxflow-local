"""HTTP clients for the real backend app that pass the trust boundary.

Every client defaults to the loopback base URL and the per-test API token, so
tests exercise the same checks (Host, token) that the VoxFlow app does.
``conftest`` sets ``VOXFLOW_API_TOKEN`` before any server import; the token is
read back from the environment here rather than duplicated.
"""

from __future__ import annotations

import os

import httpx
from fastapi import FastAPI
from starlette.testclient import TestClient

TEST_API_TOKEN: str = os.environ["VOXFLOW_API_TOKEN"]
TEST_BASE_URL = "http://127.0.0.1:8765"
_TEST_HOST = "127.0.0.1:8765"


def _default_headers() -> dict[str, str]:
    return {"X-VoxFlow-Token": TEST_API_TOKEN}


def api_client(app: FastAPI) -> TestClient:
    """A TestClient that passes the trust boundary.

    ``TestClient.websocket_connect`` ignores ``base_url`` and would send
    ``Host: testserver``, which the middleware rejects. An explicit Host
    default header is honored by the websocket path, so websocket tests
    reach the app with the real loopback authority.
    """
    return TestClient(
        app,
        base_url=TEST_BASE_URL,
        headers={**_default_headers(), "Host": _TEST_HOST},
    )


def async_api_client(app: FastAPI) -> httpx.AsyncClient:
    """An AsyncClient over ASGI that passes the trust boundary."""
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),  # type: ignore[arg-type]
        base_url=TEST_BASE_URL,
        headers=_default_headers(),
    )
