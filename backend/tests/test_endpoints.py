"""API endpoint tests using httpx AsyncClient + FastAPI ASGI transport.

These tests exercise the HTTP layer (routing, status codes, middleware) without
loading ML models. Environment variables force offline mode so engine
initialization fails gracefully (pipeline=False) rather than downloading models.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Prevent ML model downloads — engines will set _pipeline=False on load failure.
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("VOXFLOW_OFFLINE", "1")
os.environ.setdefault("VOXFLOW_MODELS_DIR", "/nonexistent")

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import httpx

from server import _rate_limit_timestamps, app


@pytest.fixture()
async def client():
    """Create a fresh async httpx client against the FastAPI app."""
    transport = httpx.ASGITransport(app=app)  # type: ignore[arg-type]
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as c:
        yield c


@pytest.fixture(autouse=True)
def _clear_rate_limits():
    """Reset rate limit state between tests."""
    _rate_limit_timestamps.clear()
    yield
    _rate_limit_timestamps.clear()


# ── Health ────────────────────────────────────────────────────────────

class TestHealth:
    @pytest.mark.anyio
    async def test_returns_200(self, client: httpx.AsyncClient):
        resp = await client.get("/v1/health")
        assert resp.status_code == 200

    @pytest.mark.anyio
    async def test_response_has_expected_keys(self, client: httpx.AsyncClient):
        resp = await client.get("/v1/health")
        data = resp.json()
        expected_keys = {"service_status", "model_loaded", "mps_available", "stt_backend"}
        assert expected_keys.issubset(data.keys())

    @pytest.mark.anyio
    async def test_service_status_is_ok(self, client: httpx.AsyncClient):
        data = (await client.get("/v1/health")).json()
        assert data["service_status"] == "ok"


# ── Readiness ─────────────────────────────────────────────────────────

class TestReadiness:
    @pytest.mark.anyio
    async def test_returns_200(self, client: httpx.AsyncClient):
        resp = await client.get("/v1/ready")
        assert resp.status_code == 200

    @pytest.mark.anyio
    async def test_response_has_expected_keys(self, client: httpx.AsyncClient):
        data = (await client.get("/v1/ready")).json()
        expected_keys = {
            "service_status",
            "ready_for_dictation",
            "stt_backend",
            "active_stt_model",
            "active_stt_model_loaded",
            "python_executable",
            "python_version",
            "models_dir",
            "models_dir_exists",
            "issues",
        }
        assert expected_keys.issubset(data.keys())

    @pytest.mark.anyio
    async def test_response_has_typed_boolean_flags(self, client: httpx.AsyncClient):
        data = (await client.get("/v1/ready")).json()
        assert isinstance(data["ready_for_dictation"], bool)
        assert isinstance(data["active_stt_model_loaded"], bool)
        assert isinstance(data["models_dir_exists"], bool)
        assert isinstance(data["issues"], list)


# ── Privacy Preview ──────────────────────────────────────────────────

class TestPrivacyPreview:
    @pytest.mark.anyio
    async def test_returns_503_without_private_api(self, client: httpx.AsyncClient):
        # Privacy preview requires a configured private API backend.
        # Without it, the server correctly returns 503.
        resp = await client.post("/v1/privacy/preview", json={
            "session_id": "test-sess",
            "operation": "cleanup",
            "input_text": "Email me at alice@example.com",
        })
        assert resp.status_code == 503

    @pytest.mark.anyio
    async def test_invalid_operation_returns_400(self, client: httpx.AsyncClient):
        resp = await client.post("/v1/privacy/preview", json={
            "session_id": "test-sess",
            "operation": "invalid_op",
            "input_text": "some text",
        })
        assert resp.status_code == 400


# ── Cleanup ──────────────────────────────────────────────────────────

class TestCleanup:
    @pytest.mark.anyio
    async def test_local_only_processes_text(self, client: httpx.AsyncClient):
        resp = await client.post("/v1/cleanup", json={
            "session_id": "test-sess",
            "mode": "light",
            "input_text": "um hello world",
            "tone_style": "neutral",
            "provider_mode": "localOnly",
        })
        assert resp.status_code == 200
        data = resp.json()
        assert "output_text" in data
        assert data["mode_applied"] == "light"

    @pytest.mark.anyio
    async def test_private_api_without_config_returns_503(self, client: httpx.AsyncClient):
        # Private API mode without configuration → 503
        resp = await client.post("/v1/cleanup", json={
            "session_id": "test-sess",
            "mode": "light",
            "input_text": "some text",
            "tone_style": "neutral",
            "provider_mode": "private_api",
            "consent_token": "invalid-token-xyz",
        })
        assert resp.status_code == 503


# ── Transcribe ───────────────────────────────────────────────────────

class TestTranscribe:
    @pytest.mark.anyio
    async def test_oversized_payload_returns_413(self, client: httpx.AsyncClient):
        # Generate a base64 string that exceeds the 10MB limit
        huge_payload = "A" * (15 * 1024 * 1024)
        resp = await client.post("/v1/transcribe", json={
            "session_id": "test-sess",
            "audio_pcm16le": huge_payload,
            "sample_rate": 16000,
        })
        assert resp.status_code == 413

    @pytest.mark.anyio
    async def test_malformed_base64_returns_400(self, client: httpx.AsyncClient):
        resp = await client.post("/v1/transcribe", json={
            "session_id": "test-sess",
            "audio_pcm16le": "!!!not-valid-base64!!!",
            "sample_rate": 16000,
        })
        assert resp.status_code == 400
        assert "Invalid audio payload" in resp.json()["detail"]

    @pytest.mark.anyio
    async def test_odd_length_pcm_returns_400(self, client: httpx.AsyncClient):
        import base64
        # 3 bytes is odd — invalid for int16 PCM
        odd_bytes = base64.b64encode(b"\x00\x01\x02").decode()
        resp = await client.post("/v1/transcribe", json={
            "session_id": "test-sess",
            "audio_pcm16le": odd_bytes,
            "sample_rate": 16000,
        })
        assert resp.status_code == 400
        assert "even byte length" in resp.json()["detail"]

    @pytest.mark.anyio
    async def test_empty_audio_returns_placeholder(self, client: httpx.AsyncClient):
        import base64
        empty_b64 = base64.b64encode(b"").decode()
        resp = await client.post("/v1/transcribe", json={
            "session_id": "test-sess",
            "audio_pcm16le": empty_b64,
            "sample_rate": 16000,
        })
        assert resp.status_code == 200
        data = resp.json()
        assert "no audio captured" in data["text"]
        assert data["confidence_estimate"] == 0.0


# ── Rate Limiting ────────────────────────────────────────────────────

class TestRateLimiting:
    @pytest.mark.anyio
    async def test_exceeding_limit_returns_429(self, client: httpx.AsyncClient):
        # Fill up 120 requests
        for _ in range(120):
            await client.get("/v1/health")

        # 121st should be rate limited
        resp = await client.get("/v1/health")
        assert resp.status_code == 429


# ── CORS ─────────────────────────────────────────────────────────────

class TestCORS:
    @pytest.mark.anyio
    async def test_cors_headers_for_localhost(self, client: httpx.AsyncClient):
        resp = await client.options(
            "/v1/health",
            headers={
                "Origin": "http://127.0.0.1",
                "Access-Control-Request-Method": "GET",
            },
        )
        # CORS preflight should include allow-origin
        assert "access-control-allow-origin" in resp.headers


# ── Transcribe Chunking ──────────────────────────────────────────────

class TestTranscribeChunking:
    @pytest.mark.anyio
    async def test_transcribe_returns_processing_time_ms(self, client: httpx.AsyncClient):
        """Verify the transcribe response includes processing_time_ms field."""
        import base64
        import struct

        # 1 second of silence at 16kHz (16-bit PCM)
        silence = struct.pack("<" + "h" * 16000, *([0] * 16000))
        b64 = base64.b64encode(silence).decode()

        resp = await client.post("/v1/transcribe", json={
            "session_id": "test-chunking",
            "audio_pcm16le": b64,
            "sample_rate": 16000,
            "language_hint": "en",
            "chunk_index": 0,
        })
        assert resp.status_code == 200
        data = resp.json()
        assert "processing_time_ms" in data
        assert isinstance(data["processing_time_ms"], int)
        assert data["processing_time_ms"] >= 0

    @pytest.mark.anyio
    async def test_transcribe_response_has_all_expected_fields(self, client: httpx.AsyncClient):
        """Verify transcribe response schema includes all fields."""
        import base64
        import struct

        silence = struct.pack("<" + "h" * 16000, *([0] * 16000))
        b64 = base64.b64encode(silence).decode()

        resp = await client.post("/v1/transcribe", json={
            "session_id": "test-schema",
            "audio_pcm16le": b64,
            "sample_rate": 16000,
            "language_hint": "en",
            "chunk_index": 0,
        })
        data = resp.json()
        expected_keys = {"text", "is_final", "latency_ms", "confidence_estimate", "processing_time_ms"}
        assert expected_keys.issubset(data.keys())
