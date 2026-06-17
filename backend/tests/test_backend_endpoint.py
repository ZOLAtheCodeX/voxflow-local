"""Backend bind host/port resolution (VOXFLOW_BACKEND_URL parity).

The Swift launcher passes VOXFLOW_BACKEND_HOST/PORT to the spawned uvicorn so
the client URL, the stale-listener checks, and the bound socket all agree. This
pins server.resolve_bind_host_port's resolution order: explicit host/port env
first, then derive from VOXFLOW_BACKEND_URL, then default to 127.0.0.1:8765.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import server


class TestResolveBindHostPort:
    def test_defaults_to_loopback_8765(self):
        assert server.resolve_bind_host_port({}) == ("127.0.0.1", 8765)

    def test_explicit_host_port_env_wins(self):
        assert server.resolve_bind_host_port(
            {"VOXFLOW_BACKEND_HOST": "127.0.0.1", "VOXFLOW_BACKEND_PORT": "9000"}
        ) == ("127.0.0.1", 9000)

    def test_derives_from_backend_url_when_no_explicit(self):
        assert server.resolve_bind_host_port(
            {"VOXFLOW_BACKEND_URL": "http://127.0.0.1:9100"}
        ) == ("127.0.0.1", 9100)

    def test_explicit_host_port_overrides_url(self):
        assert server.resolve_bind_host_port({
            "VOXFLOW_BACKEND_HOST": "127.0.0.1",
            "VOXFLOW_BACKEND_PORT": "9000",
            "VOXFLOW_BACKEND_URL": "http://127.0.0.1:1234",
        }) == ("127.0.0.1", 9000)

    def test_https_url_without_port_defaults_443(self):
        assert server.resolve_bind_host_port(
            {"VOXFLOW_BACKEND_URL": "https://example.test"}
        ) == ("example.test", 443)

    def test_non_numeric_port_env_falls_through_to_default(self):
        assert server.resolve_bind_host_port(
            {"VOXFLOW_BACKEND_HOST": "127.0.0.1", "VOXFLOW_BACKEND_PORT": "abc"}
        ) == ("127.0.0.1", 8765)
