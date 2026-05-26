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

from server import STTExecutionResult, WhisperEngine

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

    # Assert — pipeline stays None, _load_failed flag is set
    assert engine._pipeline is None
    assert engine._load_failed is True
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
    result = engine.transcribe(bytes(32), 16000, "en")

    # Assert
    assert isinstance(result, STTExecutionResult)
    assert "[transcription unavailable" in result.text
    assert result.confidence == 0.0

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
    result = engine.transcribe(bytes(32), 16000, "en")

    # Assert
    assert isinstance(result, STTExecutionResult)
    assert result.text == "Hello world"
    # Mock has no chunks and near-zero audio duration → word-rate heuristic saturates to cap
    assert result.confidence == 0.95

    # Verify pipeline was called (engine calls pipeline(...) internally)
    mock_pipeline_instance.assert_called_once()


def test_short_audio_disables_chunking():
    """Phase 5.1: audio < 20s should be inferred without chunking."""
    engine = WhisperEngine()

    mock_pipeline_instance = MagicMock()
    mock_pipeline_instance.return_value = {"text": "short clip"}
    sys.modules["transformers"].pipeline.return_value = mock_pipeline_instance

    # 5 seconds @ 16 kHz mono int16 = 160_000 bytes < 20s threshold.
    five_sec_pcm = bytes(5 * 16000 * 2)
    engine.transcribe(five_sec_pcm, 16000, "en")

    mock_pipeline_instance.assert_called_once()
    call_kwargs = mock_pipeline_instance.call_args.kwargs
    assert call_kwargs.get("chunk_length_s") == 0, (
        f"short audio should pass chunk_length_s=0 to disable chunking, "
        f"got {call_kwargs.get('chunk_length_s')!r}"
    )


def test_long_audio_keeps_default_chunking():
    """Phase 5.1: audio >= 20s should keep the pipeline's default chunking."""
    engine = WhisperEngine()

    mock_pipeline_instance = MagicMock()
    mock_pipeline_instance.return_value = {"text": "long clip"}
    sys.modules["transformers"].pipeline.return_value = mock_pipeline_instance

    # 25 seconds @ 16 kHz mono int16 = 800_000 bytes >= 20s threshold.
    twenty_five_sec_pcm = bytes(25 * 16000 * 2)
    engine.transcribe(twenty_five_sec_pcm, 16000, "en")

    mock_pipeline_instance.assert_called_once()
    call_kwargs = mock_pipeline_instance.call_args.kwargs
    # The constructor-time chunking stays in effect; no per-call override.
    assert "chunk_length_s" not in call_kwargs, (
        f"long audio should not override chunk_length_s, "
        f"got {call_kwargs.get('chunk_length_s')!r}"
    )
