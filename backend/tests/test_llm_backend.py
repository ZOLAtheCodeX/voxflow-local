"""Unit tests for TextLLMBackend implementations and Ollama admin helpers.

Mocks live network I/O — these tests never touch a real Ollama server.
"""

from __future__ import annotations

import io
import json
import sys
from pathlib import Path
from unittest.mock import patch
from urllib import error as urlerror

# Insert the app package so engines/* is importable.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import pytest

from engines.llm_backend import (
    OllamaBackend,
    TextLLMBackend,
    probe_ollama_available,
    reset_ollama_probe_cache,
    select_backend,
)
from engines.polish import PolishEngine


class _FakeBackend:
    """In-test backend used to assert PolishEngine routing without ML deps."""

    name = "fake"

    def __init__(self, response: str) -> None:
        self.response = response
        self.calls: list[tuple[str, str]] = []

    def polish(self, text: str, tone: str) -> str:
        self.calls.append((text, tone))
        return self.response


def _ollama_response(content: str) -> bytes:
    # Native /api/chat response shape (the OpenAI-compat endpoint silently
    # drops keep_alive — verified live 2026-06-11 — so the backend uses the
    # native endpoint).
    return json.dumps(
        {"message": {"role": "assistant", "content": content}, "done": True}
    ).encode("utf-8")


class _FakeHTTPResponse:
    """Context-manager mimicking urllib.request.urlopen()'s return value."""

    def __init__(self, body: bytes, status: int = 200) -> None:
        self._body = body
        self.status = status

    def __enter__(self) -> "_FakeHTTPResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self) -> bytes:
        return self._body


class TestOllamaBackendSuccess:
    def test_returns_cleaned_content(self) -> None:
        backend = OllamaBackend(model="gemma4:e4b-mlx")
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(_ollama_response("Please send the report by Friday.")),
        ) as urlopen_mock:
            result = backend.polish("uh send the report by friday", "neutral")

        assert result == "Please send the report by Friday."
        urlopen_mock.assert_called_once()
        # System-role tone constraint, not user-role
        sent_request = urlopen_mock.call_args.args[0]
        body = json.loads(sent_request.data.decode("utf-8"))
        assert body["model"] == "gemma4:e4b-mlx"
        assert body["stream"] is False
        roles = [m["role"] for m in body["messages"]]
        assert roles == ["system", "user"]
        assert "cleaned text" in body["messages"][0]["content"].lower()
        assert body["messages"][1]["content"] == "uh send the report by friday"

    def test_payload_pins_model_residency_and_token_budget(self) -> None:
        """R2.1: keep_alive pins the model in memory across idle gaps (the
        5-minute Ollama default caused multi-second cold-load p95 spikes);
        max_tokens raises the ~128-token compat default that truncated
        long-paragraph polish (truncation then tripped the guardrail)."""
        backend = OllamaBackend(model="gemma4:e4b-mlx")
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(_ollama_response("ok")),
        ) as urlopen_mock:
            backend.polish("some dictated text to polish", "neutral")

        sent_request = urlopen_mock.call_args.args[0]
        assert sent_request.full_url.endswith("/api/chat"), (
            "must use the native endpoint — the OpenAI-compat endpoint drops keep_alive"
        )
        body = json.loads(sent_request.data.decode("utf-8"))
        assert body["keep_alive"] == "24h"
        assert body["options"]["num_predict"] == 512
        assert body["options"]["temperature"] == 0.2

    def test_strips_whitespace_from_response(self) -> None:
        backend = OllamaBackend()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(_ollama_response("\n  trimmed  \n")),
        ):
            assert backend.polish("hi", "neutral") == "trimmed"

    def test_empty_input_returns_empty(self) -> None:
        backend = OllamaBackend()
        # Should never hit the network for empty input.
        with patch("engines.llm_backend.urlrequest.urlopen") as urlopen_mock:
            assert backend.polish("", "neutral") == ""
            assert backend.polish("   ", "neutral") == ""
            urlopen_mock.assert_not_called()


class TestOllamaBackendFailure:
    """Connection / parse failures must return "" — never raise to callers."""

    def test_connection_refused_returns_empty(self) -> None:
        backend = OllamaBackend()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            side_effect=urlerror.URLError("Connection refused"),
        ):
            assert backend.polish("hello world", "neutral") == ""

    def test_timeout_returns_empty(self) -> None:
        backend = OllamaBackend()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            side_effect=TimeoutError("timed out"),
        ):
            assert backend.polish("hello world", "neutral") == ""

    def test_malformed_json_returns_empty(self) -> None:
        backend = OllamaBackend()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(b"not json"),
        ):
            assert backend.polish("hello world", "neutral") == ""

    def test_missing_choices_returns_empty(self) -> None:
        backend = OllamaBackend()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(b'{"unexpected": "shape"}'),
        ):
            assert backend.polish("hello world", "neutral") == ""

    def test_unexpected_exception_returns_empty(self) -> None:
        backend = OllamaBackend()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            side_effect=RuntimeError("boom"),
        ):
            assert backend.polish("hello world", "neutral") == ""


class TestOllamaBackendAvailability:
    def test_is_available_true_on_200(self) -> None:
        backend = OllamaBackend()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(b'{"models": []}', status=200),
        ):
            assert backend.is_available() is True

    def test_is_available_false_on_connection_refused(self) -> None:
        backend = OllamaBackend()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            side_effect=urlerror.URLError("refused"),
        ):
            assert backend.is_available() is False


class TestPolishEngineWithFakeBackend:
    """PolishEngine guardrail + fallback behaviour, independent of any model."""

    def test_passes_clean_candidate_through(self) -> None:
        # Input has a real defect (typo) so the candidate is a substantive
        # polish, not a case/punctuation-only echo.
        backend = _FakeBackend(response="This is a clean polished sentence.")
        engine = PolishEngine(backend=backend)
        output, triggered, reason = engine.polish("this is a clean polishd sentence", "neutral")
        assert output == "This is a clean polished sentence."
        assert triggered is False
        assert reason is None
        assert backend.calls == [("this is a clean polishd sentence", "neutral")]

    def test_empty_backend_response_falls_back_silently(self) -> None:
        backend = _FakeBackend(response="")
        engine = PolishEngine(backend=backend)
        original = "send the report to the team"
        output, triggered, reason = engine.polish(original, "neutral")
        # Fell back to apply_tone(light_cleanup()) — non-empty, similar.
        assert output
        assert original.split()[0].lower() in output.lower()
        # Empty backend response is treated as "declined", not a guardrail trip —
        # but the degraded_reason now distinguishes it (R2.2).
        assert triggered is False
        assert reason == "backend_unavailable"

    def test_guardrail_triggers_on_runaway_length(self) -> None:
        # 11-word original; runaway candidate (>1.8x).
        runaway = " ".join(["filler"] * 30)
        backend = _FakeBackend(response=runaway)
        engine = PolishEngine(backend=backend)
        original = "send the deck to the marketing team by end of day today"
        output, triggered, reason = engine.polish(original, "neutral")
        assert triggered is True
        assert reason in ("guardrail_length", "guardrail_similarity")
        # Output is the regex fallback, not the runaway candidate.
        assert runaway not in output

    def test_echo_falls_back_without_triggering_guardrail(self) -> None:
        # Backend echoes the input verbatim — should fall back, but NOT flag
        # the guardrail (echo is a "did nothing", not a "did something bad").
        backend = _FakeBackend(response="Hello world")
        engine = PolishEngine(backend=backend)
        output, triggered, reason = engine.polish("hello world", "neutral")
        assert triggered is False
        assert reason == "echo"
        # Fallback path runs light_cleanup which adds a period.
        assert output.strip().lower().startswith("hello world")

    def test_backend_exception_falls_back(self) -> None:
        class _ExplodingBackend:
            name = "exploding"

            def polish(self, text: str, tone: str) -> str:
                raise RuntimeError("network exploded")

        engine = PolishEngine(backend=_ExplodingBackend())
        output, triggered, reason = engine.polish("hello world", "neutral")
        # Fallback ran; output is non-empty.
        assert output
        assert triggered is False
        assert reason == "backend_unavailable"

    def test_empty_input_returns_empty_without_calling_backend(self) -> None:
        backend = _FakeBackend(response="should-not-be-used")
        engine = PolishEngine(backend=backend)
        assert engine.polish("", "neutral") == ("", False, None)
        assert engine.polish("   ", "neutral") == ("", False, None)
        assert backend.calls == []


class TestSelectBackend:
    def test_default_is_ollama(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("VOXFLOW_POLISH_BACKEND", raising=False)
        backend = select_backend()
        assert isinstance(backend, OllamaBackend)
        assert backend.name == "ollama"

    def test_explicit_ollama(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("VOXFLOW_POLISH_BACKEND", "ollama")
        backend = select_backend()
        assert isinstance(backend, OllamaBackend)
        assert backend.name == "ollama"

    def test_unknown_value_falls_back_to_ollama(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("VOXFLOW_POLISH_BACKEND", "made-up-backend")
        backend = select_backend()
        assert isinstance(backend, OllamaBackend)

    def test_case_insensitive(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("VOXFLOW_POLISH_BACKEND", "OLLAMA")
        backend = select_backend()
        assert isinstance(backend, OllamaBackend)

    def test_legacy_or_unknown_value_falls_back_to_ollama(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Existing user configs that still set a removed/legacy value or
        # any other unknown identifier should not crash; they get ollama
        # instead with a warning logged.
        monkeypatch.setenv("VOXFLOW_POLISH_BACKEND", "legacy-removed-backend")
        backend = select_backend()
        assert isinstance(backend, OllamaBackend)


class TestRecommendOllamaModel:
    """Recommended model tiers by host RAM."""

    def test_recommends_e4b_for_high_ram(self) -> None:
        from engines.llm_backend import recommend_ollama_model
        assert recommend_ollama_model(32 * 1024**3) == "gemma4:e4b-mlx"
        assert recommend_ollama_model(24 * 1024**3) == "gemma4:e4b-mlx"
        # R2 retune: a 16 GB machine running the 9 GB e4b plus the Whisper
        # backend thrashes — measured live 2026-06-11: prompt eval degraded
        # to ~5 tok/s, runner wedges, 28% of requests hit the 30 s timeout.
        assert recommend_ollama_model(16 * 1024**3) == "gemma4:e2b-mlx"

    def test_recommends_e2b_for_mid_ram(self) -> None:
        from engines.llm_backend import recommend_ollama_model
        assert recommend_ollama_model(15 * 1024**3) == "gemma4:e2b-mlx"
        assert recommend_ollama_model(8 * 1024**3) == "gemma4:e2b-mlx"

    def test_no_recommendation_for_low_ram(self) -> None:
        from engines.llm_backend import recommend_ollama_model
        assert recommend_ollama_model(4 * 1024**3) is None
        assert recommend_ollama_model(7 * 1024**3) is None

    def test_zero_memory_returns_none(self) -> None:
        from engines.llm_backend import recommend_ollama_model
        assert recommend_ollama_model(0) is None


class TestListOllamaModels:
    def test_returns_parsed_list_on_success(self) -> None:
        from engines.llm_backend import list_ollama_models
        body = json.dumps({"models": [{"name": "gemma4:e4b-mlx", "size": 9_600_000_000}]}).encode("utf-8")
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(body),
        ):
            models = list_ollama_models()
        assert models == [{"name": "gemma4:e4b-mlx", "size": 9_600_000_000}]

    def test_returns_empty_on_connection_error(self) -> None:
        from engines.llm_backend import list_ollama_models
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            side_effect=urlerror.URLError("refused"),
        ):
            assert list_ollama_models() == []

    def test_returns_empty_on_malformed_json(self) -> None:
        from engines.llm_backend import list_ollama_models
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(b"not json"),
        ):
            assert list_ollama_models() == []


class TestPullOllamaModelStream:
    def test_yields_ndjson_lines(self) -> None:
        from engines.llm_backend import pull_ollama_model_stream
        lines = [
            b'{"status": "pulling manifest"}\n',
            b'{"status": "downloading", "completed": 1000, "total": 5000}\n',
            b'{"status": "success"}\n',
        ]

        class _StreamingResponse:
            def __enter__(self) -> "_StreamingResponse":
                return self
            def __exit__(self, *args: object) -> None:
                return None
            def __iter__(self):
                return iter(lines)

        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_StreamingResponse(),
        ):
            out = list(pull_ollama_model_stream("gemma4:e4b-mlx"))

        assert len(out) == 3
        assert "pulling manifest" in out[0]
        assert "success" in out[2]

    def test_emits_error_line_on_connection_failure(self) -> None:
        from engines.llm_backend import pull_ollama_model_stream
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            side_effect=urlerror.URLError("connection refused"),
        ):
            out = list(pull_ollama_model_stream("gemma4:e4b-mlx"))
        assert len(out) == 1
        parsed = json.loads(out[0])
        assert parsed["status"] == "error"
        assert "unreachable" in parsed["error"]


class TestProbeOllamaAvailable:
    """probe_ollama_available() caches the result for the TTL window."""

    def test_returns_true_when_ollama_responds(self) -> None:
        reset_ollama_probe_cache()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(b'{"models": []}', status=200),
        ):
            assert probe_ollama_available(force=True) is True

    def test_returns_false_when_ollama_down(self) -> None:
        reset_ollama_probe_cache()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            side_effect=urlerror.URLError("connection refused"),
        ):
            assert probe_ollama_available(force=True) is False

    def test_caches_result_across_calls(self) -> None:
        reset_ollama_probe_cache()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(b'{"models": []}', status=200),
        ) as urlopen_mock:
            probe_ollama_available(force=True)
            probe_ollama_available()
            probe_ollama_available()
            # First call did one probe; second/third hit the cache.
            assert urlopen_mock.call_count == 1

    def test_force_bypasses_cache(self) -> None:
        reset_ollama_probe_cache()
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(b'{"models": []}', status=200),
        ) as urlopen_mock:
            probe_ollama_available(force=True)
            probe_ollama_available(force=True)
            assert urlopen_mock.call_count == 2


class TestProtocolConformance:
    """Sanity-check the concrete backend satisfies the duck-typed Protocol."""

    def test_ollama_backend_has_polish(self) -> None:
        backend: TextLLMBackend = OllamaBackend()
        assert hasattr(backend, "polish")
        assert callable(backend.polish)
        assert backend.name == "ollama"
