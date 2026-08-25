# Latency + AI-features hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Gemma polish and cockpit smart actions actually work (and fast) on a 16 GB machine, persist per-capture latency, and serve rules-only cleanup in-app.

**Architecture:** Backend changes are confined to `engines/llm_backend.py` (request shape), `engines/polish.py` (guard thresholds), `engines/provider_registry.py` (locality), `smart_actions.py` (reason propagation). Swift changes thread an `InsertTimingContext` from the capture trace into the insert receipt, short-circuit rules-only cleanup in `DictationWorkflowCoordinator`, and add single-flight state for cockpit smart actions in `AppState`/`CockpitCoordinator`/cockpit views.

**Tech Stack:** Python 3.11 + FastAPI + pytest; Swift 6.2 strict concurrency + XCTest.

**Spec:** `docs/superpowers/specs/2026-08-24-latency-ai-hardening-spec.md`

## Global Constraints

- Run Python tests with `/Users/zola/Documents/CODING/voxflow-local/.venv/bin/python -m pytest backend/tests/<file> -q` from the worktree root.
- Run Swift tests with `swift test --filter <TestClass>` from the worktree root.
- Logging via `logging.getLogger("voxflow")`; never bare `print()`.
- No real AX / process services in tests: use `TextInserting`, `SmartActionBackend`, `TextInsertionCoordinating` seams.
- Commit after each task with an imperative subject and the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `SmartActionResult` gains fields with defaults only (19 memberwise call sites must keep compiling).

---

### Task 1: Disable Ollama thinking on chat requests

**Files:**
- Modify: `backend/app/engines/llm_backend.py` (module helper near `_tone_instruction`; `OllamaBackend.polish` payload)
- Test: `backend/tests/test_llm_backend.py`

**Interfaces:**
- Produces: `ollama_think_enabled() -> bool` (module-level in `engines.llm_backend`), payload key `"think"`.

- [ ] **Step 1: Write the failing tests** (append after `TestOllamaBackendSuccess`)

```python
class TestOllamaThinking:
    """Gemma 4 reasons before answering unless told not to (measured 2026-08-24:
    a warm 30-word polish took ~6.0 s with ~370 hidden thinking tokens vs
    ~0.26 s with think=false). Thinking tokens also count against num_predict,
    so long smart actions could have their answer truncated."""

    def _sent_body(self) -> dict:
        backend = OllamaBackend(model="gemma4:e2b-mlx")
        with patch(
            "engines.llm_backend.urlrequest.urlopen",
            return_value=_FakeHTTPResponse(_ollama_response("ok")),
        ) as urlopen_mock:
            backend.polish("some dictated text to polish", "neutral")
        return json.loads(urlopen_mock.call_args.args[0].data.decode("utf-8"))

    def test_thinking_disabled_by_default(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("VOXFLOW_OLLAMA_THINK", raising=False)
        assert self._sent_body()["think"] is False

    def test_thinking_env_opt_in(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("VOXFLOW_OLLAMA_THINK", "1")
        assert self._sent_body()["think"] is True

    def test_env_garbage_means_off(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("VOXFLOW_OLLAMA_THINK", "maybe")
        assert self._sent_body()["think"] is False
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/python -m pytest backend/tests/test_llm_backend.py -q -k Thinking`
Expected: 3 FAIL with `KeyError: 'think'`.

- [ ] **Step 3: Implement**

In `llm_backend.py`, after `_tone_instruction`:

```python
def ollama_think_enabled() -> bool:
    """Whether Ollama chat requests may spend tokens on hidden reasoning.

    Gemma 4 (and other thinking-capable models) reason before answering
    unless told not to. Measured live 2026-08-24 on gemma4:e2b-mlx: a warm
    30-word polish took ~6.0 s with ~370 hidden thinking tokens vs ~0.26 s
    with think=false, and thinking tokens count against ``num_predict`` so
    long smart actions could have their answer truncated. Off by default;
    ``VOXFLOW_OLLAMA_THINK=1`` re-enables it for machines that prefer
    reasoning on smart actions and can afford the latency.
    """
    return os.environ.get("VOXFLOW_OLLAMA_THINK", "0").strip().lower() in {"1", "true", "yes"}
```

In `OllamaBackend.polish`, add to `payload` right after `"stream": False,`:

```python
            # Hidden reasoning is pure latency for polish/smart actions
            # (see ollama_think_enabled). Native-endpoint field, like keep_alive.
            "think": ollama_think_enabled(),
```

- [ ] **Step 4: Run to verify they pass**

Run: `.venv/bin/python -m pytest backend/tests/test_llm_backend.py -q`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/engines/llm_backend.py backend/tests/test_llm_backend.py
git commit -m "fix: disable Ollama thinking on polish/smart-action requests"
```

---

### Task 2: Gate smart actions at critical pressure only; propagate the reason

**Files:**
- Modify: `backend/app/engines/polish.py` (class constants; the pressure check in `run`)
- Modify: `backend/app/smart_actions.py` (the `served_by == "regex"` refusal)
- Test: `backend/tests/test_llm_backend.py`, `backend/tests/test_smart_actions.py`

**Interfaces:**
- Produces: `PolishEngine._POLISH_PRESSURE_SKIP_LEVEL = 2`, `PolishEngine._SMART_ACTION_PRESSURE_SKIP_LEVEL = 4`; `SmartActionResult.degraded_reason` populated on refusal.

- [ ] **Step 1: Write the failing tests**

Append to `test_llm_backend.py`:

```python
class _SystemPromptFakeBackend:
    """Fake accepting the smart-action system_prompt kwarg (the module-level
    _FakeBackend deliberately lacks it to exercise the legacy TypeError path)."""

    name = "fake"

    def __init__(self, response: str) -> None:
        self.response = response
        self.calls: list[str] = []

    def polish(self, text, tone, system_prompt=None, model=None, timeout=None):
        self.calls.append(text)
        return self.response


class TestSmartActionMemoryPressure:
    """Smart actions run in the cockpit's review state with no capture live,
    so they yield only at CRITICAL pressure (4). Polish stays gated at WARN
    (2): it sits on the dictation hot path. A 16 GB machine rests at warn
    (measured 2026-08-24), which made the shared threshold a permanent off
    switch for smart actions."""

    _PROMPT = "Restructure as a memo."

    def test_smart_action_runs_at_warn_pressure(self, monkeypatch: pytest.MonkeyPatch) -> None:
        from engines import llm_backend

        monkeypatch.setattr(llm_backend, "detect_memory_pressure_level", lambda: 2)
        local = _SystemPromptFakeBackend("# Issue\nmemo body")
        engine = PolishEngine(chain=[(ProviderSpec(id="ollama", kind="ollama"), local)])

        out = engine.run("some transcript text", "neutral", system_prompt=self._PROMPT)

        assert local.calls == ["some transcript text"]
        assert out.served_by == "ollama"
        assert out.degraded_reason is None

    def test_smart_action_skips_at_critical_pressure(self, monkeypatch: pytest.MonkeyPatch) -> None:
        from engines import llm_backend

        monkeypatch.setattr(llm_backend, "detect_memory_pressure_level", lambda: 4)
        local = _SystemPromptFakeBackend("# Issue\nmemo body")
        engine = PolishEngine(chain=[(ProviderSpec(id="ollama", kind="ollama"), local)])

        out = engine.run("some transcript text", "neutral", system_prompt=self._PROMPT)

        assert local.calls == []
        assert out.served_by == "regex"
        assert out.degraded_reason == "memory_pressure"

    def test_polish_still_skips_at_warn_pressure(self, monkeypatch: pytest.MonkeyPatch) -> None:
        from engines import llm_backend

        monkeypatch.setattr(llm_backend, "detect_memory_pressure_level", lambda: 2)
        local = _SystemPromptFakeBackend("Polished.")
        engine = PolishEngine(chain=[(ProviderSpec(id="ollama", kind="ollama"), local)])

        out = engine.run("send the weekly report before friday", "neutral")

        assert local.calls == []
        assert out.degraded_reason == "memory_pressure"
```

Append to `test_smart_actions.py`:

```python
def test_refusal_carries_memory_pressure_reason(monkeypatch):
    """The cockpit used to tell the user to 'configure a provider' when the
    provider was fine and the memory guard had refused — the reason was
    dropped here. Critical pressure refuses; the reason travels with it."""
    from engines import llm_backend
    from engines.polish import PolishEngine

    monkeypatch.setattr(llm_backend, "detect_memory_pressure_level", lambda: 4)
    local = _ChainBackend("ollama", "# Issue\nmemo")
    engine = SmartActionEngine(polish_backend=PolishEngine(chain=[(_spec("ollama"), local)]))

    result = engine.apply(action_id="memo", transcript="the transcript to restructure")

    assert result.error == "provider_unavailable"
    assert result.degraded_reason == "memory_pressure"
    assert result.output == "the transcript to restructure"
    assert local.received == []


def test_smart_action_serves_at_warn_pressure(monkeypatch):
    from engines import llm_backend
    from engines.polish import PolishEngine

    monkeypatch.setattr(llm_backend, "detect_memory_pressure_level", lambda: 2)
    local = _ChainBackend("ollama", "# Issue\nmemo")
    engine = SmartActionEngine(polish_backend=PolishEngine(chain=[(_spec("ollama"), local)]))

    result = engine.apply(action_id="memo", transcript="the transcript to restructure")

    assert result.error is None
    assert result.served_by == "ollama"
    assert result.output == "# Issue\nmemo"
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/python -m pytest backend/tests/test_llm_backend.py backend/tests/test_smart_actions.py -q -k "pressure or Pressure"`
Expected: `test_smart_action_runs_at_warn_pressure`, `test_smart_action_serves_at_warn_pressure`, `test_refusal_carries_memory_pressure_reason` FAIL; the others PASS.

- [ ] **Step 3: Implement**

`polish.py`, class constants next to `_WEDGE_*`:

```python
    # Memory-pressure skip thresholds (kern.memorystatus_vm_pressure_level:
    # 1 normal, 2 warn, 4 critical). Polish sits on the dictation hot path
    # and yields at WARN so the resident LLM never competes with live
    # capture. Smart actions run in the cockpit's review state with no
    # capture live, so they yield only at CRITICAL: a 16 GB machine rests at
    # warn (measured 2026-08-24), and the shared threshold had turned every
    # smart action into `provider_unavailable`.
    _POLISH_PRESSURE_SKIP_LEVEL = 2
    _SMART_ACTION_PRESSURE_SKIP_LEVEL = 4
```

In `run`, after the `pressure = ...` line add:

```python
        skip_level = (
            self._SMART_ACTION_PRESSURE_SKIP_LEVEL if system_prompt is not None
            else self._POLISH_PRESSURE_SKIP_LEVEL
        )
```

and change the loop condition `if not is_cloud and pressure >= 2:` to `if not is_cloud and pressure >= skip_level:`.

`smart_actions.py`, in the `if outcome.served_by == "regex":` branch, add `degraded_reason=outcome.degraded_reason,` to the returned `SmartActionResult`.

- [ ] **Step 4: Run to verify they pass**

Run: `.venv/bin/python -m pytest backend/tests/test_llm_backend.py backend/tests/test_smart_actions.py backend/tests/test_polish_engine.py -q`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/engines/polish.py backend/app/smart_actions.py backend/tests/test_llm_backend.py backend/tests/test_smart_actions.py
git commit -m "fix: gate smart actions at critical memory pressure, carry the reason"
```

---

### Task 3: Honest smart-action error messages in the cockpit

**Files:**
- Modify: `Sources/VoxFlowApp/Models/AppModels.swift:790-795` (`SmartActionResult`)
- Modify: `Sources/VoxFlowApp/Services/BackendAPIClient.swift:314-360` (`performSmartAction` Response)
- Modify: `Sources/VoxFlowApp/Services/CockpitCoordinator.swift:88-108`
- Modify: `Sources/VoxFlowApp/Views/CockpitWindowView.swift:173-185` (`triggerAction`)
- Test: `Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift`

**Interfaces:**
- Produces: `SmartActionResult.degradedReason: String?` (default nil); `CockpitCoordinator.smartActionErrorMessage(_:error:degradedReason:)`.

- [ ] **Step 1: Write the failing tests** (inside `CockpitCoordinatorTests`, plus a stub at file bottom)

```swift
    func test_smartActionErrorMessage_names_memory_pressure() {
        let msg = CockpitCoordinator.smartActionErrorMessage(
            .memo, error: "provider_unavailable", degradedReason: "memory_pressure")
        XCTAssertTrue(msg.lowercased().contains("memory pressure"), msg)
        XCTAssertFalse(msg.lowercased().contains("configure"), "the provider is fine — do not send the user to Settings")
    }

    func test_smartActionErrorMessage_names_wedged_runner() {
        let msg = CockpitCoordinator.smartActionErrorMessage(
            .memo, error: "provider_unavailable", degradedReason: "provider_wedged")
        XCTAssertTrue(msg.contains("ollama stop"), msg)
    }

    func test_applyAction_surfaces_memory_pressure_reason() async throws {
        let (state, coord, _, _) = makeCoordinator(backend: MemoryPressureSmartActionBackend())

        let result = try await coord.applyAction(.memo, to: "raw transcript")

        XCTAssertEqual(result.degradedReason, "memory_pressure")
        XCTAssertTrue(state.statusLine.lowercased().contains("memory pressure"), state.statusLine)
        XCTAssertEqual(state.chipInvocationCounts[.memo, default: 0], 0)
    }
```

```swift
private final class MemoryPressureSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        SmartActionResult(
            actionId: action, output: transcript, guardrailTriggered: false,
            error: "provider_unavailable", degradedReason: "memory_pressure")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head`
Expected: compile errors (`degradedReason` unknown).

- [ ] **Step 3: Implement**

`AppModels.swift`:

```swift
struct SmartActionResult: Sendable, Equatable {
    let actionId: SmartActionId
    let output: String
    let guardrailTriggered: Bool
    let error: String?
    /// Why the chain fell to the floor when `error == "provider_unavailable"`
    /// (`memory_pressure` / `provider_wedged` / `backend_unavailable`), so the
    /// cockpit can say what actually happened instead of "configure a provider".
    var degradedReason: String? = nil
}
```

`BackendAPIClient.performSmartAction`: add `let degradedReason: String?` to `Response`, `case degradedReason = "degraded_reason"` to its `CodingKeys`, and `degradedReason: parsed.degradedReason` to the returned `SmartActionResult`.

`CockpitCoordinator`:

```swift
    /// User-facing message for a smart-action soft error. Provider-neutral so it
    /// stays accurate whatever the configured chain (Ollama, LM Studio, cloud).
    /// `degradedReason` is the backend's floor reason: the provider may be fine
    /// and the memory guard refused, which must NOT read as "configure a provider".
    static func smartActionErrorMessage(
        _ action: SmartActionId, error: String, degradedReason: String? = nil
    ) -> String {
        switch error {
        case "provider_unavailable":
            switch degradedReason {
            case "memory_pressure":
                return "\(action.label) paused: memory pressure is critical — close some apps and retry"
            case "provider_wedged":
                return "\(action.label) paused: the LLM runner is not responding — run `ollama stop` and retry"
            default:
                return "\(action.label): no LLM provider is ready — check Ollama or configure one in Settings"
            }
        default:
            return "\(action.label) failed: \(error)"
        }
    }
```

In `applyAction`: `state.statusLine = Self.smartActionErrorMessage(action, error: error, degradedReason: result.degradedReason)`.

`CockpitWindowView.triggerAction`: `lastError = result.error.map { CockpitCoordinator.smartActionErrorMessage(action, error: $0, degradedReason: result.degradedReason) }`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter CockpitCoordinatorTests`
Expected: all PASS (including the pre-existing `test_applyAction_surfaces_provider_unavailable_error`, whose default message still contains "provider").

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Models/AppModels.swift Sources/VoxFlowApp/Services/BackendAPIClient.swift Sources/VoxFlowApp/Services/CockpitCoordinator.swift Sources/VoxFlowApp/Views/CockpitWindowView.swift Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift
git commit -m "fix: cockpit says why a smart action was refused"
```

---

### Task 4: Classify Ollama `:cloud` models as cloud

**Files:**
- Modify: `backend/app/engines/provider_registry.py:55-104`
- Test: `backend/tests/test_provider_registry.py`, `backend/tests/test_llm_backend.py`

**Interfaces:**
- Produces: `is_ollama_cloud_model(model: str | None) -> bool`, `OLLAMA_CLOUD_TAG = ":cloud"` in `engines.provider_registry`.

- [ ] **Step 1: Write the failing tests**

`test_provider_registry.py` (add `is_ollama_cloud_model` to the import list, then append):

```python
class TestOllamaCloudModels:
    """Ollama serves hosted models under a ':cloud' tag (kimi-k3:cloud,
    deepseek-v4-pro:cloud); /api/tags reports remote_host=https://ollama.com.
    The request still goes to localhost:11434 but the text leaves the machine,
    so they are CLOUD: redaction on, memory guard off (zero local RAM)."""

    def test_cloud_tag_is_cloud(self) -> None:
        assert ProviderSpec(id="k", kind="ollama", model="kimi-k3:cloud").is_cloud is True

    def test_local_model_stays_local(self) -> None:
        assert ProviderSpec(id="g", kind="ollama", model="gemma4:e2b-mlx").is_cloud is False

    def test_no_model_stays_local(self) -> None:
        assert ProviderSpec(id="g", kind="ollama").is_cloud is False

    def test_helper_is_case_insensitive_and_nil_safe(self) -> None:
        assert is_ollama_cloud_model("Kimi-K3:CLOUD") is True
        assert is_ollama_cloud_model("gemma4:e2b-mlx") is False
        assert is_ollama_cloud_model(None) is False
        assert is_ollama_cloud_model("") is False
```

`test_llm_backend.py`, append to `TestMemoryPressureDegrade`:

```python
    def test_ollama_cloud_model_runs_under_pressure_and_is_redacted(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """An Ollama ':cloud' model costs no local RAM (not memory-guarded) and
        sends text off-machine (redacted first)."""
        from engines import llm_backend

        monkeypatch.setattr(llm_backend, "detect_memory_pressure_level", lambda: 2)
        cloud = _FakeBackend("Please email ops the weekly report before Friday.")
        spec = ProviderSpec(id="ollama-cloud", kind="ollama", model="kimi-k3:cloud")
        engine = PolishEngine(chain=[(spec, cloud)])

        out = engine.run("email ops@example.com the weekly report before friday", "neutral")

        assert out.served_by == "ollama-cloud"
        assert cloud.calls, "cloud entry must run under pressure"
        sent_text = cloud.calls[0][0]
        assert "[EMAIL]" in sent_text
        assert "ops@example.com" not in sent_text
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/python -m pytest backend/tests/test_provider_registry.py backend/tests/test_llm_backend.py -q -k "Cloud or cloud"`
Expected: ImportError for `is_ollama_cloud_model` (registry file) / `served_by == "regex"` failure (backend file).

- [ ] **Step 3: Implement** (`provider_registry.py`, after `is_local_url`)

```python
# Ollama serves hosted models under a ":cloud" tag (e.g. "kimi-k3:cloud");
# /api/tags reports them with remote_host=https://ollama.com. The request
# still goes to localhost:11434, but the text leaves the machine — so for
# redaction they are CLOUD, and for the memory guard they cost no local RAM.
OLLAMA_CLOUD_TAG = ":cloud"


def is_ollama_cloud_model(model: str | None) -> bool:
    """True when an Ollama model id names a hosted (ollama.com) model."""
    return bool(model) and model.strip().lower().endswith(OLLAMA_CLOUD_TAG)
```

In `ProviderSpec.is_cloud`, the `ollama` branch becomes:

```python
        if self.kind == "ollama":
            # A ':cloud' model is served by ollama.com regardless of base_url;
            # otherwise the default endpoint is localhost and base_url decides.
            if is_ollama_cloud_model(self.model):
                return True
            return not is_local_url(self.base_url or "http://localhost:11434")
```

- [ ] **Step 4: Run to verify they pass**

Run: `.venv/bin/python -m pytest backend/tests/test_provider_registry.py backend/tests/test_llm_backend.py backend/tests/test_smart_actions.py -q`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/engines/provider_registry.py backend/tests/test_provider_registry.py backend/tests/test_llm_backend.py
git commit -m "fix: treat Ollama ':cloud' models as cloud providers"
```

---

### Task 5: Persist stage timings in insert receipts

**Files:**
- Modify: `Sources/VoxFlowApp/Models/AppModels.swift` (new `InsertTimingContext` next to `InsertResult`)
- Modify: `Sources/VoxFlowApp/Services/InsertionAuditLog.swift:33-63`
- Modify: `Sources/VoxFlowApp/Services/TextInsertionCoordinator.swift:5-13, 111-157`
- Modify: `Sources/VoxFlowApp/Services/DictationWorkflowCoordinator.swift` (request fields; `processDictation`; `processBackendCleanup`; `autoInsertOrReview`)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:14-70` (trace builder accessors) and `:1696-1730` (`processDictation` request)
- Test: `Tests/VoxFlowAppTests/InsertionAuditLogTests.swift`, `Tests/VoxFlowAppTests/TextInsertionCoordinatorTests.swift`, `Tests/VoxFlowAppTests/DictationWorkflowCoordinatorTests.swift`

**Interfaces:**
- Produces: `struct InsertTimingContext: Sendable { let pipelineStartedAt: ContinuousClock.Instant; let sttMs: Int?; let cleanupMs: Int? }`; protocol method `insertText(_:statusSuffix:targetApp:timing:) async -> Bool` with a forwarding default; `InsertionAuditLog.recordInsertion(..., sttMs:cleanupMs:insertMs:totalMs:insertMethod:)`; receipt keys `stt_ms`, `cleanup_ms`, `insert_ms`, `total_ms`, `insert_method`; `DictationWorkflowRequest.pipelineStartedAt: ContinuousClock.Instant?`, `.sttMs: Int?`; `CapturePipelineTraceBuilder.startedAt`, `.durationMs(of:)`.

- [ ] **Step 1: Write the failing tests**

`InsertionAuditLogTests.swift`:

```swift
    /// Latency forensics (session 32): stage timings were computed per capture
    /// and never persisted, so field latency was unobservable. Inserts now
    /// carry stt/cleanup/insert/total ms and the insert method.
    func testInsertReceiptCarriesStageTimings() throws {
        let log = InsertionAuditLog(fileURL: tempURL)
        log.recordInsertion(
            text: "hello world", targetApp: "Notes", source: "quick_dictation", confidence: 0.91,
            sttMs: 640, cleanupMs: 3, insertMs: 45, totalMs: 702, insertMethod: "simulatedPaste")
        let line = try String(contentsOf: tempURL, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(with: Data(line.split(separator: "\n")[0].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["stt_ms"] as? Int, 640)
        XCTAssertEqual(obj?["cleanup_ms"] as? Int, 3)
        XCTAssertEqual(obj?["insert_ms"] as? Int, 45)
        XCTAssertEqual(obj?["total_ms"] as? Int, 702)
        XCTAssertEqual(obj?["insert_method"] as? String, "simulatedPaste")
    }

    func testInsertReceiptOmitsTimingKeysWhenAbsent() throws {
        let log = InsertionAuditLog(fileURL: tempURL)
        log.recordInsertion(text: "hello", targetApp: "Notes", source: "review", confidence: nil)
        let line = try String(contentsOf: tempURL, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(with: Data(line.split(separator: "\n")[0].utf8)) as? [String: Any]
        XCTAssertNil(obj?["stt_ms"])
        XCTAssertNil(obj?["total_ms"])
        XCTAssertNil(obj?["insert_method"])
    }
```

`TextInsertionCoordinatorTests.swift`:

```swift
    /// The insert receipt is the only persisted latency record: insert_ms is
    /// measured here, total_ms runs from the pipeline origin (hotkey release),
    /// and the method tells AX-direct from paste for later per-app tuning.
    @MainActor
    func testInsertTextStampsTimingAndMethod() async throws {
        let state = AppState()
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-test-audit-\(UUID().uuidString).jsonl")
        let service = ScriptedInsertService()
        service.result = InsertResult(method: .simulatedPaste, success: true, fallbackUsed: true, errorCode: nil)
        let sut = TextInsertionCoordinator(state: state, insertService: service, audit: InsertionAuditLog(fileURL: auditURL))
        let timing = InsertTimingContext(pipelineStartedAt: .now, sttMs: 640, cleanupMs: 3)

        let ok = await sut.insertText("hello", statusSuffix: "Inserted (light)", targetApp: nil, timing: timing)

        XCTAssertTrue(ok)
        let line = try String(contentsOf: auditURL, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(with: Data(line.split(separator: "\n")[0].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["stt_ms"] as? Int, 640)
        XCTAssertEqual(obj?["cleanup_ms"] as? Int, 3)
        let insertMs = try XCTUnwrap(obj?["insert_ms"] as? Int)
        let totalMs = try XCTUnwrap(obj?["total_ms"] as? Int)
        XCTAssertGreaterThanOrEqual(insertMs, 0)
        XCTAssertGreaterThanOrEqual(totalMs, insertMs)
        XCTAssertEqual(obj?["insert_method"] as? String, "simulatedPaste")
    }
```

`DictationWorkflowCoordinatorTests.swift` — extend `FakeTextInsertionCoordinator` with:

```swift
        var lastTiming: InsertTimingContext?

        func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?, timing: InsertTimingContext?) -> Bool {
            lastTiming = timing
            return insertText(text, statusSuffix: statusSuffix, targetApp: targetApp)
        }
```

and add the test:

```swift
    /// The workflow threads the pipeline origin + STT ms into the insert so the
    /// receipt can carry total latency; cleanup ms is measured here.
    @MainActor func testAutoInsertThreadsTimingContext() async throws {
        let (sut, state, textInsertion, _) = makeSUT()
        state.backendReadiness.readyForDictation = false
        state.focusTarget = FocusTargetSnapshot(
            hasFocusedTextInput: true, hasInsertionCursor: true, appName: "Notes",
            bundleID: "com.apple.Notes", role: "AXTextField", processIdentifier: nil)

        var request = DictationWorkflowRequest(
            sessionID: "dictation-timing", rawText: "hello world", providerMode: .localOnly,
            consentToken: nil, allowRaw: false, toneStyle: .neutral,
            insertBehavior: .autoInsertLight, sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.95, targetApp: nil)
        request.pipelineStartedAt = .now
        request.sttMs = 500

        try await sut.processDictation(request) { _, _, _ in }

        let timing = try XCTUnwrap(textInsertion.lastTiming)
        XCTAssertEqual(timing.sttMs, 500)
        XCTAssertNotNil(timing.cleanupMs)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head`
Expected: compile errors (`InsertTimingContext`, `timing:`, `sttMs:` unknown).

- [ ] **Step 3: Implement**

`AppModels.swift`, directly above `struct InsertResult`:

```swift
/// Per-capture latency context threaded from the pipeline trace into the
/// insert receipt (session 32). The trace already measured these stages, but
/// nothing persisted them, so field latency was unobservable.
struct InsertTimingContext: Sendable {
    /// Pipeline origin: the moment the user released the hotkey.
    let pipelineStartedAt: ContinuousClock.Instant
    let sttMs: Int?
    let cleanupMs: Int?
}
```

`InsertionAuditLog.recordInsertion`: add parameters after `tailGapSeconds: Double? = nil`:

```swift
        sttMs: Int? = nil,
        cleanupMs: Int? = nil,
        insertMs: Int? = nil,
        totalMs: Int? = nil,
        insertMethod: String? = nil
```

and before `append(entry)`:

```swift
        // Latency forensics (session 32): per-stage ms + total from hotkey
        // release, and the insert method (AX-direct vs paste) for per-app tuning.
        if let sttMs { entry["stt_ms"] = sttMs }
        if let cleanupMs { entry["cleanup_ms"] = cleanupMs }
        if let insertMs { entry["insert_ms"] = insertMs }
        if let totalMs { entry["total_ms"] = totalMs }
        if let insertMethod { entry["insert_method"] = insertMethod }
```

`TextInsertionCoordinator.swift` protocol + default:

```swift
@MainActor protocol TextInsertionCoordinating {
    func insertCurrentText() async
    func insertCurrentText(targetApp: NSRunningApplication?) async
    func insertText(_ text: String, statusSuffix: String) async -> Bool
    func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?) async -> Bool
    /// Timing-aware variant: stamps stage/total latency + insert method into
    /// the receipt. Conformers that don't measure fall back to the 3-arg form.
    func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?, timing: InsertTimingContext?) async -> Bool
    func copyCurrentText()
    func copyMeetingMarkdownTemplate()
    func copyMeetingNotionTemplate()
}

extension TextInsertionCoordinating {
    func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?, timing: InsertTimingContext?) async -> Bool {
        await insertText(text, statusSuffix: statusSuffix, targetApp: targetApp)
    }
}
```

In the class, the existing 3-arg `insertText` becomes a forwarder `await insertText(text, statusSuffix: statusSuffix, targetApp: targetApp, timing: nil)`, and the body moves to the 4-arg method, whose success branch records:

```swift
            audit.recordInsertion(
                text: text,
                targetApp: targetApp?.localizedName ?? appName,
                source: statusSuffix,
                confidence: state.transcriptCandidate?.confidence,
                audioSeconds: state.transcriptCandidate?.audioSeconds,
                rmsEnergy: state.transcriptCandidate?.rmsEnergy,
                peakAmplitude: state.transcriptCandidate?.peakAmplitude,
                tailGapSeconds: state.transcriptCandidate?.tailGapSeconds,
                sttMs: timing?.sttMs,
                cleanupMs: timing?.cleanupMs,
                insertMs: elapsedMs,
                totalMs: timing?.pipelineStartedAt.elapsedMilliseconds(),
                insertMethod: result.method.rawValue
            )
```

`DictationWorkflowRequest`: add

```swift
    /// Latency forensics (session 32): pipeline origin (hotkey release) and the
    /// STT stage ms, so the insert receipt can carry total latency.
    var pipelineStartedAt: ContinuousClock.Instant? = nil
    var sttMs: Int? = nil
```

`DictationWorkflowCoordinator`: give `autoInsertOrReview` a new parameter `cleanupMs: Int?` and build the context before the insert:

```swift
            let timing = request.pipelineStartedAt.map {
                InsertTimingContext(pipelineStartedAt: $0, sttMs: request.sttMs, cleanupMs: cleanupMs)
            }
            let insertStarted = ContinuousClock.now
            if await textInsertion.insertText(text, statusSuffix: "...", targetApp: request.targetApp, timing: timing) {
```

Measure `cleanupMs`: in the local branch `let cleanupStarted = ContinuousClock.now` before the light cleanup and `cleanupMs: cleanupStarted.elapsedMilliseconds()` after polish; in `processBackendCleanup` wrap the `if let autoMode { ... } else { ... }` block with `let cleanupStarted = ContinuousClock.now` / `let cleanupMs = cleanupStarted.elapsedMilliseconds()`. The raw path passes the same `timing` construction with `cleanupMs: 0`.

`AppCoordinator.CapturePipelineTraceBuilder`: add

```swift
    /// Pipeline origin for total-latency receipts (session 32).
    var startedAt: ContinuousClock.Instant { started }

    func durationMs(of stageName: String) -> Int? {
        stageTimings.first { $0.name == stageName }?.durationMs
    }
```

`AppCoordinator.processDictation`: after building `request` (make it `var`), set `request.pipelineStartedAt = trace.startedAt` and `request.sttMs = trace.durationMs(of: "stt")`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter "InsertionAuditLogTests|TextInsertionCoordinatorTests|DictationWorkflowCoordinatorTests|ChainExecutorTests|PromptWorkflowCoordinatorTests"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Models/AppModels.swift Sources/VoxFlowApp/Services/InsertionAuditLog.swift Sources/VoxFlowApp/Services/TextInsertionCoordinator.swift Sources/VoxFlowApp/Services/DictationWorkflowCoordinator.swift Sources/VoxFlowApp/AppCoordinator.swift Tests/VoxFlowAppTests/InsertionAuditLogTests.swift Tests/VoxFlowAppTests/TextInsertionCoordinatorTests.swift Tests/VoxFlowAppTests/DictationWorkflowCoordinatorTests.swift
git commit -m "feat: persist stage timings and insert method in insert receipts"
```

---

### Task 6: Serve rules-only polish in-app

**Files:**
- Modify: `Sources/VoxFlowApp/Services/PolishProvenance.swift:12-16`
- Modify: `Sources/VoxFlowApp/Services/DictationWorkflowCoordinator.swift` (`processDictation` whisperKit branch)
- Test: `Tests/VoxFlowAppTests/DictationWorkflowCoordinatorTests.swift`

**Interfaces:**
- Produces: `PolishProvenance.rulesInApp = "rules · in-app"`.

- [ ] **Step 1: Write the failing test**

```swift
    /// Rules-only polish (Settings → "Local rules only"): the backend would
    /// serve the same regex floor over HTTP minus the POS-aware filler pass
    /// only the Swift pipeline has. Serve it in-app with its own provenance.
    @MainActor func testRulesOnlyPolishServesInAppWithoutBackendRoundTrip() async throws {
        let (sut, state, textInsertion, _) = makeSUT()
        state.backendReadiness.readyForDictation = true
        state.backendReadiness.activePolishProvider = ProviderConfigStore.rulesSentinel
        state.focusTarget = FocusTargetSnapshot(
            hasFocusedTextInput: true, hasInsertionCursor: true, appName: "Notes",
            bundleID: "com.apple.Notes", role: "AXTextField", processIdentifier: nil)
        DictationMockURLProtocol.requestHandler = { request in
            XCTFail("rules-only cleanup must not round-trip the backend, hit \(request.url?.path ?? "?")")
            throw URLError(.badServerResponse)
        }

        var recordedStages: [String] = []
        let request = DictationWorkflowRequest(
            sessionID: "dictation-rules", rawText: "um hello world", providerMode: .localOnly,
            consentToken: nil, allowRaw: false, toneStyle: .neutral,
            insertBehavior: .autoInsertLight, sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.95, targetApp: nil)

        try await sut.processDictation(request) { name, _, _ in recordedStages.append(name) }

        XCTAssertEqual(textInsertion.insertedText, "Hello world.")
        XCTAssertTrue(recordedStages.contains("cleanup_light_local"))
        XCTAssertFalse(recordedStages.contains("cleanup_light_api"))
        XCTAssertEqual(textInsertion.statusSuffix?.contains(PolishProvenance.rulesInApp), true,
                       "status was \(textInsertion.statusSuffix ?? "nil")")
        XCTAssertEqual(state.transcriptCandidate?.lightProvenance, PolishProvenance.rulesInApp)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DictationWorkflowCoordinatorTests/testRulesOnlyPolishServesInAppWithoutBackendRoundTrip`
Expected: compile error (`rulesInApp`), then after adding only the constant: FAIL at `XCTFail("rules-only cleanup must not round-trip...")`.

- [ ] **Step 3: Implement**

`PolishProvenance.swift`:

```swift
    /// Marker for the in-app rules pipeline chosen deliberately (polish chain
    /// == ["rules"]). Distinct from `inApp` (backend cold) so receipts can
    /// tell "user chose rules" from "backend was down".
    static let rulesInApp = "rules · in-app"
```

`DictationWorkflowCoordinator.processDictation`, whisperKit branch:

```swift
        if request.providerMode == .localOnly && request.sttBackend == .whisperKit {
            // Rules-only polish (Settings → "Local rules only"): the backend
            // would serve the identical regex floor over HTTP — minus the
            // POS-aware ambiguous-filler pass only the Swift pipeline has. Serve
            // it in-app: no round trip, no backend dependency on the hottest
            // path, and the stronger ruleset.
            let rulesOnly = state.backendReadiness.activePolishProvider == ProviderConfigStore.rulesSentinel
            if state.backendReadiness.readyForDictation && !rulesOnly {
                ... (unchanged backend attempt) ...
            }
            let localProvenance = rulesOnly ? PolishProvenance.rulesInApp : PolishProvenance.inApp
            ... (unchanged local cleanup) ...
            let candidate = TranscriptCandidate(
                ...,
                lightProvenance: localProvenance,
                polishProvenance: localProvenance,
                ...
            )
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter DictationWorkflowCoordinatorTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/PolishProvenance.swift Sources/VoxFlowApp/Services/DictationWorkflowCoordinator.swift Tests/VoxFlowAppTests/DictationWorkflowCoordinatorTests.swift
git commit -m "feat: serve rules-only polish in-app"
```

---

### Task 7: Single-flight smart actions with visible in-flight state

**Files:**
- Modify: `Sources/VoxFlowApp/State/AppState.swift:67-76`
- Modify: `Sources/VoxFlowApp/Services/CockpitCoordinator.swift:88-140`
- Modify: `Sources/VoxFlowApp/Views/Cockpit/CockpitChipRowView.swift`
- Modify: `Sources/VoxFlowApp/Views/Cockpit/CockpitTopBarView.swift:8-45`
- Test: `Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift`

**Interfaces:**
- Produces: `AppState.smartActionInFlight: SmartActionId?`, `AppState.smartActionStartedAt: Date?`; soft error string `"action_in_flight"`.

- [ ] **Step 1: Write the failing tests**

```swift
    /// Single-flight: chips had no in-flight state, so a second tap during a
    /// 6 s transform dispatched a duplicate. The second call is refused with a
    /// soft error and the state clears when the first completes.
    func test_applyAction_refuses_second_dispatch_while_in_flight() async throws {
        let backend = GatedSmartActionBackend()
        let (state, coord, _, _) = makeCoordinator(backend: backend)

        let first = Task { try await coord.applyAction(.memo, to: "raw transcript") }
        await backend.waitUntilCalled()
        XCTAssertEqual(state.smartActionInFlight, .memo)
        XCTAssertNotNil(state.smartActionStartedAt)

        let second = try await coord.applyAction(.mece, to: "raw transcript")
        XCTAssertEqual(second.error, "action_in_flight")
        XCTAssertEqual(state.chipInvocationCounts[.mece, default: 0], 0)

        backend.release()
        let result = try await first.value
        XCTAssertNil(result.error)
        XCTAssertNil(state.smartActionInFlight)
        XCTAssertNil(state.smartActionStartedAt)
        XCTAssertEqual(state.chipInvocationCounts[.memo, default: 0], 1)
    }

    func test_applyAction_clears_in_flight_state_on_throw() async {
        let (state, coord, _, _) = makeCoordinator(backend: ThrowingSmartActionBackend())
        do {
            _ = try await coord.applyAction(.memo, to: "raw transcript")
            XCTFail("expected throw")
        } catch {}
        XCTAssertNil(state.smartActionInFlight)
    }

    func test_smartActionErrorMessage_in_flight() {
        let msg = CockpitCoordinator.smartActionErrorMessage(.mece, error: "action_in_flight")
        XCTAssertTrue(msg.lowercased().contains("still running"), msg)
    }
```

Stubs at file bottom:

```swift
/// Blocks inside performSmartAction until released, so tests can observe the
/// in-flight window deterministically.
private final class GatedSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var released = false
    private var calledWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilCalled() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock(); defer { lock.unlock() }
            if called { cont.resume() } else { calledWaiter = cont }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        lock.lock()
        called = true
        let waiter = calledWaiter
        calledWaiter = nil
        lock.unlock()
        waiter?.resume()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock(); defer { lock.unlock() }
            if released { cont.resume() } else { releaseWaiter = cont }
        }
        return SmartActionResult(actionId: action, output: "# transformed\n\n\(transcript)", guardrailTriggered: false, error: nil)
    }
}

private final class ThrowingSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    struct Boom: Error {}
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        throw Boom()
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | head`
Expected: compile errors (`smartActionInFlight` unknown).

- [ ] **Step 3: Implement**

`AppState.swift`, after `chipInvocationCounts`:

```swift
    /// Smart action currently executing (session 32): chips disable, the top
    /// bar shows elapsed time, and a second dispatch is refused (single-flight).
    @Published var smartActionInFlight: SmartActionId?
    @Published var smartActionStartedAt: Date?
```

`CockpitCoordinator.smartActionErrorMessage`: add a case before `default:`:

```swift
        case "action_in_flight":
            return "\(action.label) skipped: another smart action is still running"
```

`CockpitCoordinator.applyAction`, at the top:

```swift
        // Single-flight: the backend serialises smart actions behind one ML
        // semaphore anyway (a concurrent call would 503), and a duplicate tap
        // during a multi-second transform must not queue a second transform.
        if state.smartActionInFlight != nil {
            state.statusLine = Self.smartActionErrorMessage(action, error: "action_in_flight")
            return SmartActionResult(actionId: action, output: transcript, guardrailTriggered: false, error: "action_in_flight")
        }
        state.smartActionInFlight = action
        state.smartActionStartedAt = Date()
        defer {
            state.smartActionInFlight = nil
            state.smartActionStartedAt = nil
        }
        let result = try await actionService.apply(action, to: transcript)
```

`CockpitChipRowView.chipBody`: after `.buttonStyle(.plain)` add

```swift
        .disabled(state.smartActionInFlight != nil)
        .opacity(state.smartActionInFlight == nil || state.smartActionInFlight == action ? 1 : 0.5)
```

and render the running chip's label as `Text(state.smartActionInFlight == action ? "\(action.label)…" : action.label)`.

`CockpitTopBarView`: insert `inFlightPill` between `recordingPill` and `modelPill` in `body`, and add

```swift
    /// Session 32: smart actions had no visible in-progress state (a 6 s
    /// transform looked like a dead chip). Ticks once a second while running.
    @ViewBuilder private var inFlightPill: some View {
        if let action = state.smartActionInFlight, let startedAt = state.smartActionStartedAt {
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                pill("● \(action.label.lowercased()) · \(elapsedString(since: startedAt))", tint: VF.colorInfo)
            }
            .accessibilityLabel("\(action.label) smart action in progress")
        }
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter CockpitCoordinatorTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/State/AppState.swift Sources/VoxFlowApp/Services/CockpitCoordinator.swift Sources/VoxFlowApp/Views/Cockpit/CockpitChipRowView.swift Sources/VoxFlowApp/Views/Cockpit/CockpitTopBarView.swift Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift
git commit -m "feat: single-flight smart actions with visible in-flight state"
```

---

### Task 8: Documentation

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased]`)
- Modify: `CLAUDE.md` (env-var table; Python key patterns; Do Not)

- [ ] **Step 1: CHANGELOG.md** — under `## [Unreleased]` add:

```markdown
### Fixed
- Gemma polish and smart actions no longer spend seconds on hidden
  "thinking": Ollama chat requests now send `think: false` (measured warm
  polish 6.0 s → 0.26 s on gemma4:e2b-mlx). `VOXFLOW_OLLAMA_THINK=1`
  re-enables reasoning.
- Smart actions work on 16 GB machines again: the memory-pressure guard
  skips local providers for smart actions only at CRITICAL pressure (polish
  on the dictation hot path still yields at WARN, where such machines rest).
  A refused action now says why (memory pressure / wedged runner / no
  provider) instead of "configure a provider".
- Ollama `:cloud` models (e.g. `kimi-k3:cloud`) are classified as cloud:
  payloads are PII-redacted first and the memory guard no longer skips them
  (they use no local RAM).

### Added
- Insert receipts carry `stt_ms`, `cleanup_ms`, `insert_ms`, `total_ms`
  (from hotkey release) and `insert_method`, so field latency is finally
  observable.
- "Local rules only" polish is served in-app by the Swift pipeline
  (provenance `rules · in-app`): no backend round trip, and it includes the
  POS-aware filler pass the Python floor omits.
- Cockpit smart actions are single-flight with a visible in-flight pill and
  disabled chips while a transform runs.
```

- [ ] **Step 2: CLAUDE.md** — add env row `VOXFLOW_OLLAMA_THINK` (`1` re-enables Ollama hidden reasoning; off by default: ~20x polish latency on gemma4); in the Python "Polish engine executes the BYOM provider chain" bullet, change "LOCAL providers are skipped" to "LOCAL providers are skipped for polish at level ≥ 2 and for smart actions (system_prompt) only at level ≥ 4; Ollama `:cloud` models count as cloud"; add to Do Not: "Send an Ollama `/api/chat` request without `think` — Gemma 4 reasons by default and polish latency goes from ~0.3 s to ~6 s." and "Route rules-only (`activePolishProvider == "rules"`) dictation cleanup through the backend — `DictationWorkflowCoordinator` serves it in-app (`rules · in-app`)."; in the Swift patterns, note `InsertTimingContext` flows trace → request → insert receipt.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md CLAUDE.md
git commit -m "docs: changelog + conventions for think:false, guard tiers, receipt timing"
```

---

### Task 9: Verification

- [ ] `swift test` — expect 689 + new tests, 0 failures.
- [ ] `.venv/bin/python -m pytest backend/tests -q` — expect 551 + new tests passed.
- [ ] Live golden set with thinking off: `VOXFLOW_OLLAMA_GOLDEN=1 .venv/bin/python -m pytest backend/tests/test_polish_golden.py -q` (loads gemma4:e2b-mlx; run `ollama stop gemma4:e2b-mlx` afterwards). Report pass/fail counts and any wording drift.
- [ ] `.venv/bin/python scripts/measure_polish_latency.py` (optional) to record the new p50/p95 for the changelog.
- [ ] Report; reinstall (`scripts/reinstall_and_launch.sh`) only on explicit user go-ahead (it quits the running app).
