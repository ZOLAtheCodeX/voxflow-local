import os
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

# Prevent ML model downloads — engines will set _pipeline=False on load failure.
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("VOXFLOW_OFFLINE", "1")
os.environ.setdefault("VOXFLOW_MODELS_DIR", "/nonexistent")

import pytest
import logging

# test_whisper_engine.py imports server with mocked FastAPI dependencies. Clear
# that cached server module and any mocked framework modules here so this test
# always exercises the real ASGI app regardless of import order.
sys.modules.pop("server", None)
for module_name in (
    "fastapi",
    "fastapi.middleware",
    "fastapi.middleware.cors",
    "fastapi.responses",
    "numpy",
    "pydantic",
):
    module = sys.modules.get(module_name)
    if isinstance(module, MagicMock):
        del sys.modules[module_name]

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import httpx
from server import STTExecutionResult, app, provider_router

@pytest.fixture()
async def client():
    """Create a fresh async httpx client against the FastAPI app."""
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as c:
        yield c

class TestSecurityLogging:
    @pytest.mark.anyio
    async def test_sensitive_hallucination_logged(self, client: httpx.AsyncClient, caplog):
        # We want to mock provider_router.transcribe to return a known hallucination phrase
        # that triggers the filter.
        hallucination_text = "Thank you for watching."

        mock_result = STTExecutionResult(
            text=hallucination_text,
            confidence=0.9,
            stage_timings_ms={"mock_transcribe": 0},
            model_loaded_before_request=True,
            model_loaded_after_request=True,
            cold_start=False,
        )
        with patch.object(
            provider_router,
            "transcribe",
            new=lambda _pcm, _sample_rate, _language_hint: mock_result,
        ):
            with caplog.at_level(logging.INFO):
                # Send a dummy audio payload
                # 1 second of silence at 16kHz (16-bit PCM)
                import base64
                import struct
                silence = struct.pack("<" + "h" * 16000, *([0] * 16000))
                b64 = base64.b64encode(silence).decode()

                resp = await client.post("/v1/transcribe", json={
                    "session_id": "test-security",
                    "audio_pcm16le": b64,
                    "sample_rate": 16000,
                })

                assert resp.status_code == 200
                data = resp.json()
                # The text should be empty because it was filtered
                assert data["text"] == ""

                # Check if the hallucination text is in the logs
                # This confirms the vulnerability exists
                assert "Filtered Whisper hallucination" in caplog.text

                # The vulnerability is fixed, so the text should NOT be logged.
                assert hallucination_text not in caplog.text
