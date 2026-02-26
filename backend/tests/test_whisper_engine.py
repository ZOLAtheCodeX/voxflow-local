"""Tests for the WhisperEngine class."""

import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

# Mock dependencies before importing server to avoid ImportError
# This is necessary because the environment lacks these packages.
# We keep these mocks globally for this test file.
MOCKED_MODULES = [
    "numpy",
    "fastapi",
    "fastapi.middleware",
    "fastapi.middleware.cors",
    "fastapi.responses",
    "pydantic",
    "transformers",
    "torch",
]

for module in MOCKED_MODULES:
    sys.modules[module] = MagicMock()

# Add app to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from server import WhisperEngine

@pytest.fixture(autouse=True)
def reset_mocks():
    """Reset mocks before each test to ensure isolation."""
    # Reset transformers.pipeline mock
    sys.modules["transformers"].reset_mock()
    # Reset specific side effects/return values we might have set
    sys.modules["transformers"].pipeline.side_effect = None
    sys.modules["transformers"].pipeline.return_value = MagicMock()
    yield

def test_load_pipeline_failure():
    """Test that WhisperEngine handles pipeline loading failures gracefully."""
    engine = WhisperEngine()

    # Configure the mocked transformers.pipeline to raise an exception
    sys.modules["transformers"].pipeline.side_effect = Exception("Simulated download failure")

    # Action
    engine._load_pipeline()

    # Assert
    assert engine._pipeline is False
    sys.modules["transformers"].pipeline.assert_called_once()

def test_load_pipeline_success():
    """Test that WhisperEngine loads pipeline successfully."""
    engine = WhisperEngine()

    # Configure mock to return a pipeline object
    mock_pipeline_instance = MagicMock()
    sys.modules["transformers"].pipeline.return_value = mock_pipeline_instance

    # Action
    engine._load_pipeline()

    # Assert
    assert engine._pipeline is mock_pipeline_instance
    sys.modules["transformers"].pipeline.assert_called_once()
    assert engine._active_model_id == engine.model_id

def test_transcribe_no_pipeline():
    """Test transcribe returns error when pipeline fails to load."""
    engine = WhisperEngine()

    # Ensure pipeline load fails
    sys.modules["transformers"].pipeline.side_effect = Exception("Fail")

    # Action — must be even-length bytes (int16 = 2 bytes per sample)
    text, conf = engine.transcribe(bytes(32), 16000, "en")

    # Assert
    assert "[transcription unavailable" in text
    assert conf == 0.0

def test_transcribe_success():
    """Test transcribe returns text when pipeline works."""
    engine = WhisperEngine()

    # Configure mock to return a pipeline object
    mock_pipeline_instance = MagicMock()
    # Mock return value of pipeline call (transcription result)
    mock_pipeline_instance.return_value = {"text": "Hello world"}

    # When _load_pipeline calls pipeline(), it should return our instance
    sys.modules["transformers"].pipeline.return_value = mock_pipeline_instance

    # Action — must be even-length bytes (int16 = 2 bytes per sample)
    text, conf = engine.transcribe(bytes(32), 16000, "en")

    # Assert
    assert text == "Hello world"
    assert conf == 0.9

    # Verify pipeline was called (engine calls pipeline(...) internally)
    mock_pipeline_instance.assert_called_once()
