import os
import sys
from pathlib import Path
from unittest.mock import patch

# Prevent ML model downloads — engines will set _pipeline=False on load failure.
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("VOXFLOW_OFFLINE", "1")
os.environ.setdefault("VOXFLOW_MODELS_DIR", "/nonexistent")

import pytest
import logging
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import httpx
from server import app, provider_router

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

        with patch.object(provider_router, "transcribe", return_value=(hallucination_text, 0.9)):
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
