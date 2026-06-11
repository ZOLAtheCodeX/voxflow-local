"""Tests for SmartActionEngine (Cockpit Layer 0, Task 1-3)."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from smart_actions import SmartActionEngine, SmartActionResult


def test_memo_action_returns_polished_text():
    mock_backend = MagicMock()
    mock_backend.polish.return_value = (
        "# Issue\nGDPR access rights\n# Analysis\n...\n# Recommendation\n...",
        False,
        None,
    )
    engine = SmartActionEngine(polish_backend=mock_backend)

    result = engine.apply(action_id="memo", transcript="data subject has right to access")

    assert isinstance(result, SmartActionResult)
    assert result.action_id == "memo"
    assert "# Issue" in result.output
    assert result.guardrail_triggered is False
    mock_backend.polish.assert_called_once()
    call_kwargs = mock_backend.polish.call_args.kwargs
    system_prompt = call_kwargs.get("system_prompt", "")
    assert "Issue" in system_prompt and "Analysis" in system_prompt and "Recommendation" in system_prompt


def test_mece_action_invokes_backend_with_mece_prompt():
    mock_backend = MagicMock()
    mock_backend.polish.return_value = (
        "- People\n  - alice\n- Process\n  - approval",
        False,
        None,
    )
    engine = SmartActionEngine(polish_backend=mock_backend)

    result = engine.apply(action_id="mece", transcript="people process policy")

    assert result.action_id == "mece"
    assert result.guardrail_triggered is False
    system_prompt = mock_backend.polish.call_args.kwargs["system_prompt"]
    assert "mutually exclusive" in system_prompt.lower()


def test_items_action_invokes_backend_with_action_items_prompt():
    mock_backend = MagicMock()
    mock_backend.polish.return_value = (
        "- [ ] Draft policy by Friday (Alice)\n- [ ] Review with legal (Bob)",
        False,
        None,
    )
    engine = SmartActionEngine(polish_backend=mock_backend)

    result = engine.apply(action_id="items", transcript="Alice will draft by Friday")

    assert result.action_id == "items"
    assert "- [ ]" in result.output
    system_prompt = mock_backend.polish.call_args.kwargs["system_prompt"]
    assert "action items" in system_prompt.lower() or "checkbox" in system_prompt.lower()


def test_unknown_action_returns_passthrough_with_error():
    mock_backend = MagicMock()
    engine = SmartActionEngine(polish_backend=mock_backend)

    result = engine.apply(action_id="nope", transcript="hello")

    assert result.output == "hello"
    assert result.error is not None
    assert "unknown action" in result.error
    mock_backend.polish.assert_not_called()


def test_guardrail_passthrough_when_triggered():
    """When the polish backend signals guardrail, the engine reports it."""
    mock_backend = MagicMock()
    mock_backend.polish.return_value = ("fallback regex output", True, "guardrail_length")
    engine = SmartActionEngine(polish_backend=mock_backend)

    result = engine.apply(action_id="memo", transcript="raw")

    assert result.output == "fallback regex output"
    assert result.guardrail_triggered is True
    assert result.error is None


def test_steel_action_uses_steelman_prompt():
    mock_backend = MagicMock()
    mock_backend.polish.return_value = ("counter-argument", False, None)
    engine = SmartActionEngine(polish_backend=mock_backend)

    engine.apply(action_id="steel", transcript="some position")

    system_prompt = mock_backend.polish.call_args.kwargs["system_prompt"]
    assert "steel" in system_prompt.lower() or "counter" in system_prompt.lower()


def test_pyramid_action_uses_pyramid_prompt():
    mock_backend = MagicMock()
    mock_backend.polish.return_value = ("conclusion. supporting points.", False, None)
    engine = SmartActionEngine(polish_backend=mock_backend)

    engine.apply(action_id="pyramid", transcript="some content")

    system_prompt = mock_backend.polish.call_args.kwargs["system_prompt"]
    assert "pyramid" in system_prompt.lower() or "conclusion" in system_prompt.lower()


def test_smart_action_endpoint_memo(monkeypatch):
    """HTTP integration: POST /v1/smart_action with a memo action."""
    from fastapi.testclient import TestClient

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
    import server

    class _StubBackend:
        def polish(self, text, tone, system_prompt=None):
            assert system_prompt and "Issue" in system_prompt
            return ("# Issue\n...\n# Recommendation\n...", False, None)

    # Swap the global polish backend on the live engine so the route uses
    # the stub instead of the FLAN-T5/Ollama path during the test.
    monkeypatch.setattr(server.smart_action_engine, "_polish_backend", _StubBackend())

    client = TestClient(server.app)
    resp = client.post("/v1/smart_action", json={
        "action_id": "memo",
        "transcript": "the data controller has rights under article 15",
    })
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["action_id"] == "memo"
    assert "# Issue" in body["output"]
    assert body["guardrail_triggered"] is False


def test_smart_action_endpoint_unknown_returns_passthrough(monkeypatch):
    """Unknown action_id returns the original text with an error tag, not 5xx."""
    from fastapi.testclient import TestClient

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
    import server

    client = TestClient(server.app)
    resp = client.post("/v1/smart_action", json={
        "action_id": "bogus-action",
        "transcript": "hello",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["output"] == "hello"
    assert body["error"] is not None and "unknown action" in body["error"]


def test_disclaimer_action_uses_disclaimer_prompt():
    mock_backend = MagicMock()
    mock_backend.polish.return_value = ("text with disclaimer", False, None)
    engine = SmartActionEngine(polish_backend=mock_backend)

    engine.apply(action_id="disclaimer", transcript="legal information")

    system_prompt = mock_backend.polish.call_args.kwargs["system_prompt"]
    assert "disclaimer" in system_prompt.lower() or "legal" in system_prompt.lower()


def test_apply_fails_closed_when_backend_unavailable():
    """Backend reports is_available()==False → return verbatim transcript with
    error tag ``ollama_unavailable`` instead of letting PolishEngine return
    its regex fallback. The Swift client surfaces this as a user-visible
    'Ollama required for smart actions' message rather than silently
    inserting structurally wrong output."""
    mock_backend = MagicMock()
    mock_backend.is_available.return_value = False
    engine = SmartActionEngine(polish_backend=mock_backend)

    result = engine.apply(action_id="memo", transcript="raw transcript text")

    assert result.action_id == "memo"
    assert result.output == "raw transcript text"
    assert result.guardrail_triggered is False
    assert result.error == "ollama_unavailable"
    mock_backend.polish.assert_not_called()


def test_apply_calls_polish_when_backend_does_not_expose_availability():
    """Legacy test stubs that don't expose ``is_available`` are treated as
    available — the gate fails open. Ensures existing tests aren't broken
    by the new fail-closed branch."""
    # spec=["polish"] means only the polish attribute exists; is_available
    # would raise AttributeError. SmartActionEngine handles this gracefully.
    mock_backend = MagicMock(spec=["polish"])
    mock_backend.polish.return_value = ("polished", False, None)
    engine = SmartActionEngine(polish_backend=mock_backend)

    result = engine.apply(action_id="memo", transcript="any text")

    assert result.output == "polished"
    assert result.error is None
    mock_backend.polish.assert_called_once()


def test_smart_action_endpoint_rejects_whitespace_only_transcript():
    """Whitespace-only transcript fails Pydantic validation with 422, not
    a misleading 200 with empty output."""
    from fastapi.testclient import TestClient

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
    import server

    client = TestClient(server.app)
    resp = client.post("/v1/smart_action", json={
        "action_id": "memo",
        "transcript": "   \n   ",
    })
    assert resp.status_code == 422
    body = resp.json()
    assert "transcript" in str(body).lower()


def test_smart_action_endpoint_returns_unavailable_when_polish_engine_offline(monkeypatch):
    """HTTP integration: polish_engine.is_available()==False → 200 with
    error='ollama_unavailable' and output=transcript verbatim."""
    from fastapi.testclient import TestClient

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
    import server

    monkeypatch.setattr(server.polish_engine, "is_available", lambda: False)

    client = TestClient(server.app)
    resp = client.post("/v1/smart_action", json={
        "action_id": "memo",
        "transcript": "draft memo content",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["output"] == "draft memo content"
    assert body["error"] == "ollama_unavailable"
    assert body["guardrail_triggered"] is False
