"""Tests for SmartActionEngine (Cockpit Layer 0, Task 1-3)."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from smart_actions import SmartActionEngine, SmartActionResult


class _ChainBackend:
    """Minimal TextLLMBackend stub for building real PolishEngine chains.

    Records every text it receives (to assert per-provider redaction) and
    returns a fixed response — an empty response stands in for an unavailable
    provider, so `run()` falls through to the next chain entry.
    """

    def __init__(self, name: str, response: str) -> None:
        self.name = name
        self.response = response
        self.received: list[str] = []

    def polish(self, text, tone, system_prompt=None, model=None, timeout=None):
        self.received.append(text)
        return self.response


def _spec(provider_id: str, *, cloud: bool = False, model: str | None = None):
    from engines.provider_registry import ProviderSpec

    return ProviderSpec(
        id=provider_id,
        kind="anthropic" if cloud else "ollama",
        base_url=None if cloud else "http://localhost:11434",
        model=model,
    )


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


def test_apply_fails_closed_when_chain_serves_only_regex_floor():
    """When the WHOLE provider chain is unavailable and run() falls to the
    regex floor (served_by='regex'), smart actions surface ``ollama_unavailable``
    and the verbatim transcript instead of the regex output — a grammar-cleaned
    transcript is structurally wrong for a MECE / steel-man / disclaimer request.
    The Swift client renders this as 'Ollama required' rather than inserting."""
    from engines.polish import PolishEngine

    chain_engine = PolishEngine(chain=[
        (_spec("ollama"), _ChainBackend("ollama", "")),  # all providers down
    ])
    engine = SmartActionEngine(polish_backend=chain_engine)

    result = engine.apply(action_id="memo", transcript="raw transcript text")

    assert result.action_id == "memo"
    assert result.output == "raw transcript text"  # verbatim, not regex-cleaned
    assert result.guardrail_triggered is False
    assert result.error == "ollama_unavailable"


def test_apply_uses_second_chain_provider_when_first_ollama_down(monkeypatch):
    """Availability is chain-aware: the old is_available() preflight only probed
    the chain HEAD, so a down first provider (ollama) returned
    ``ollama_unavailable`` even when a healthy fallback provider could serve.
    The whole chain is now attempted, so the second provider serves."""
    from engines.polish import PolishEngine

    # Force the head ollama probe to report DOWN — under the old preflight this
    # short-circuited to ollama_unavailable before run() could reach the cloud
    # fallback. After the fix the probe is irrelevant (never consulted).
    monkeypatch.setattr("engines.polish.probe_ollama_available", lambda: False)

    dead_ollama = _ChainBackend("ollama", "")  # head: down
    alive_cloud = _ChainBackend("anthropic", "# Issue\nGDPR\n# Recommendation\nProceed.")
    chain_engine = PolishEngine(chain=[
        (_spec("ollama"), dead_ollama),
        (_spec("claude", cloud=True), alive_cloud),
    ])
    engine = SmartActionEngine(polish_backend=chain_engine)

    result = engine.apply(action_id="memo", transcript="data subject has the right to access")

    assert result.error is None
    assert "# Issue" in result.output
    assert result.served_by == "claude"
    assert result.guardrail_triggered is False


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


def test_smart_action_endpoint_returns_unavailable_when_chain_floors(monkeypatch):
    """HTTP integration: when the chain serves only the regex floor
    (served_by='regex'), the route returns 200 with error='ollama_unavailable'
    and output=transcript verbatim — smart actions never insert regex output."""
    from fastapi.testclient import TestClient

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
    import server
    from engines.polish import PolishOutcome

    # Smart actions run on their own per-task chain engine (R3.3). Force its
    # run() to land on the regex floor as if every provider were unavailable.
    def _floor_run(text, tone, system_prompt=None):
        return PolishOutcome(
            text, False, "backend_unavailable",
            served_by="regex", model_id=None, fallback_depth=1,
        )

    monkeypatch.setattr(server.smart_action_polish_engine, "run", _floor_run)

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


def test_smart_action_route_passes_raw_text_to_engine(monkeypatch):
    """The route must NOT pre-redact: redaction is per-provider inside
    PolishEngine.run() (cloud yes, local no). Pre-redacting at the route fed
    local Ollama smart actions ``[EMAIL]``/``[PHONE]`` placeholders and degraded
    their output. The engine — and thus a local provider — must see raw text."""
    from fastapi.testclient import TestClient

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
    import server
    from engines.polish import PolishOutcome

    received: dict[str, str] = {}

    class _RecordingLocalChain:
        def run(self, text, tone, system_prompt=None):
            received["text"] = text
            return PolishOutcome(
                "# Issue\n...\n# Recommendation\n...", False, None,
                served_by="ollama", model_id="gemma4:e2b-mlx", fallback_depth=0,
            )

    monkeypatch.setattr(server.smart_action_engine, "_polish_backend", _RecordingLocalChain())

    client = TestClient(server.app)
    resp = client.post("/v1/smart_action", json={
        "action_id": "memo",
        "transcript": "call me at 555-867-5309 about the GDPR request",
    })
    assert resp.status_code == 200, resp.text
    # Local provider receives the RAW phone number; the route no longer redacts.
    assert "555-867-5309" in received["text"]


def test_smart_action_redacts_for_cloud_provider_via_chain():
    """Redaction survives where it belongs: a CLOUD provider in a smart-action
    chain still receives redacted text (handled inside PolishEngine.run(), not
    pre-applied at the route). Local raw, cloud redacted — per provider."""
    from engines.polish import PolishEngine

    cloud = _ChainBackend("anthropic", "# Issue\n...\n# Recommendation\n...")
    chain_engine = PolishEngine(chain=[(_spec("claude", cloud=True), cloud)])
    engine = SmartActionEngine(polish_backend=chain_engine)

    engine.apply(action_id="memo", transcript="email me at jane@example.com about the merger")

    assert len(cloud.received) == 1
    assert "jane@example.com" not in cloud.received[0]
    assert "[EMAIL]" in cloud.received[0]


def test_smart_action_result_carries_provenance_from_chain_engine():
    """R3.4: when the polish engine exposes run() (chain engine), smart
    actions surface which provider served the transformation."""
    import sys
    from pathlib import Path as _P

    sys.path.insert(0, str(_P(__file__).resolve().parent.parent / "app"))
    from engines.polish import PolishOutcome

    class _ChainEngine:
        def is_available(self):
            return True

        def run(self, text, tone, system_prompt=None):
            return PolishOutcome(
                "# Memo output", False, None,
                served_by="claude", model_id="claude-haiku-4-5-20251001", fallback_depth=0,
            )

    engine = SmartActionEngine(polish_backend=_ChainEngine())
    result = engine.apply(action_id="memo", transcript="raw transcript")
    assert result.output == "# Memo output"
    assert result.served_by == "claude"
    assert result.model_id == "claude-haiku-4-5-20251001"

