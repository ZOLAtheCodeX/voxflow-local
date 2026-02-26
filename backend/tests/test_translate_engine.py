"""Unit tests for TranslateEngine logic in server.py."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

# Insert the app package so we can import server functions directly.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

# Setup mocks for missing dependencies
mock_numpy = MagicMock()
mock_fastapi = MagicMock()
mock_cors = MagicMock()
mock_responses = MagicMock()

# Pydantic needs a real class for inheritance
class MockBaseModel:
    pass

mock_pydantic = MagicMock()
mock_pydantic.BaseModel = MockBaseModel
mock_pydantic.Field = MagicMock()

# Use patch.dict to avoid polluting global sys.modules for other tests
with patch.dict(sys.modules, {
    "numpy": mock_numpy,
    "fastapi": mock_fastapi,
    "fastapi.middleware.cors": mock_cors,
    "fastapi.responses": mock_responses,
    "pydantic": mock_pydantic,
}):
    # Import server inside the patched context
    from server import TranslateEngine


class TestResolveBackend:
    def test_explicit_translategemma_config(self):
        """Explicitly configured 'translategemma' backend should be respected regardless of model ID."""
        assert TranslateEngine._resolve_backend("translategemma", "some/other-model") == "translategemma"
        assert TranslateEngine._resolve_backend("translategemma", "google/translategemma-4b") == "translategemma"

    def test_explicit_marian_config(self):
        """Explicitly configured 'marian' backend should be respected regardless of model ID."""
        assert TranslateEngine._resolve_backend("marian", "google/translategemma-4b") == "marian"
        assert TranslateEngine._resolve_backend("marian", "Helsinki-NLP/opus-mt-en-de") == "marian"

    def test_auto_detects_translategemma_in_model_id(self):
        """If backend is 'auto' (or other unknown), 'translategemma' in model_id triggers that backend."""
        # Standard case
        assert TranslateEngine._resolve_backend("auto", "google/translategemma-4b") == "translategemma"
        # Case insensitive
        assert TranslateEngine._resolve_backend("auto", "TranslateGemma-4b") == "translategemma"
        # Partial match
        assert TranslateEngine._resolve_backend("auto", "my-translategemma-finetune") == "translategemma"

    def test_auto_defaults_to_marian(self):
        """If backend is 'auto' and 'translategemma' is NOT in model_id, default to 'marian'."""
        assert TranslateEngine._resolve_backend("auto", "Helsinki-NLP/opus-mt-en-de") == "marian"
        assert TranslateEngine._resolve_backend("auto", "t5-base") == "marian"
        assert TranslateEngine._resolve_backend("auto", "") == "marian"

    def test_unknown_backend_treats_as_auto(self):
        """Unknown configured backends fall through to model ID detection logic."""
        # Unknown backend -> check model ID
        assert TranslateEngine._resolve_backend("invalid_backend", "google/translategemma-4b") == "translategemma"
        assert TranslateEngine._resolve_backend("invalid_backend", "Helsinki-NLP/opus-mt-en-de") == "marian"
