"""Backend bind host/port resolution (VOXFLOW_BACKEND_URL parity).

The Swift launcher passes VOXFLOW_BACKEND_HOST/PORT to the spawned uvicorn so
the client URL, the stale-listener checks, and the bound socket all agree. This
pins server.resolve_bind_host_port's resolution order: explicit host/port env
first, then derive from VOXFLOW_BACKEND_URL, then default to 127.0.0.1:8765.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

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
            {"VOXFLOW_BACKEND_URL": "https://127.0.0.1"}
        ) == ("127.0.0.1", 443)

    def test_non_numeric_port_env_falls_through_to_default(self):
        assert server.resolve_bind_host_port(
            {"VOXFLOW_BACKEND_HOST": "127.0.0.1", "VOXFLOW_BACKEND_PORT": "abc"}
        ) == ("127.0.0.1", 8765)


class TestLoopbackGuard:
    """CLAUDE.md promises: "Managed spawn binds loopback only; a non-loopback
    host is refused (run the backend yourself)." resolve_bind_host_port's only
    runtime caller is the managed spawn's __main__ (run_backend.sh passes
    --host to uvicorn directly and never enters it), so enforcing here makes
    the doc's guarantee true at the bind point without touching the documented
    run-it-yourself path."""

    def test_non_loopback_host_env_refused(self):
        with pytest.raises(SystemExit):
            server.resolve_bind_host_port(
                {"VOXFLOW_BACKEND_HOST": "0.0.0.0", "VOXFLOW_BACKEND_PORT": "8765"}
            )

    def test_non_loopback_url_refused(self):
        with pytest.raises(SystemExit):
            server.resolve_bind_host_port(
                {"VOXFLOW_BACKEND_URL": "http://192.168.1.5:8765"}
            )

    def test_non_loopback_hostname_refused(self):
        with pytest.raises(SystemExit):
            server.resolve_bind_host_port(
                {"VOXFLOW_BACKEND_URL": "https://example.test"}
            )

    def test_loopback_variants_allowed(self):
        assert server.resolve_bind_host_port(
            {"VOXFLOW_BACKEND_HOST": "localhost", "VOXFLOW_BACKEND_PORT": "9000"}
        ) == ("localhost", 9000)
        assert server.resolve_bind_host_port(
            {"VOXFLOW_BACKEND_HOST": "::1", "VOXFLOW_BACKEND_PORT": "9000"}
        ) == ("::1", 9000)
        # Whole 127.0.0.0/8 block is loopback, not just .1.
        assert server.resolve_bind_host_port(
            {"VOXFLOW_BACKEND_HOST": "127.0.0.2", "VOXFLOW_BACKEND_PORT": "9000"}
        ) == ("127.0.0.2", 9000)
        # Foundation URL.host can hand the Swift launcher the BRACKETED IPv6
        # form, which BackendEndpoint.isLoopback whitelists — the backend must
        # accept it too, or a whitelisted config dies at the bind point.
        assert server.resolve_bind_host_port(
            {"VOXFLOW_BACKEND_HOST": "[::1]", "VOXFLOW_BACKEND_PORT": "9000"}
        ) == ("[::1]", 9000)
