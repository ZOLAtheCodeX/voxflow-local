# VoxFlow Cockpit Layer 0 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the foundation layer of the VoxFlow Cockpit — a document-centric long-form writing workspace with three Gemma-powered smart actions (memo, MECE, action items) invokable via chips, ⌘-shortcuts, or voice keywords.

**Architecture:** New cockpit window (separate from the existing palette and dashboard) owned by a new `CockpitCoordinator`. Long-form sessions handled by a new `LongFormSessionService` that wraps the existing `AudioCaptureService`. Smart actions routed through a new backend endpoint `POST /v1/smart_action` that uses the Ollama+Gemma 4 backend installed in Phase 3 of the stabilization roadmap.

**Tech Stack:** Swift 6.2 (SwiftUI, AppKit, `@MainActor` actors), Python 3.11+ FastAPI backend, Ollama+Gemma 4 (`gemma4:e4b-mlx` default) for action inference.

**Prerequisites:** Phases 1–3 of `docs/plans/2026-05-25-stabilization-modernization-roadmap.md` must be merged. In particular: `OllamaBackend` exists, the Sendable warning in `BackendProcessManager` is gone, and the busy-spin in `stopOnWorkQueue` is fixed.

**Scope boundary:** Layer 1 (dictionary, Notion deep integration, snippets, chains) and Layer 2 (ambient capture, context awareness) are out of scope for this plan. Hooks are left where they'll attach, but no feature work.

---

## File Structure

### New Swift files

| Path | Responsibility |
| --- | --- |
| `Sources/VoxFlowApp/Services/CockpitCoordinator.swift` | `@MainActor` class. Owns cockpit window state, target picking, chip MRU, action invocation routing. |
| `Sources/VoxFlowApp/Services/LongFormSessionService.swift` | `@MainActor` class. Pause-tolerant capture loop, auto-save, session recovery. Wraps existing `AudioCaptureService`. |
| `Sources/VoxFlowApp/Services/SmartActionService.swift` | `actor`. Calls backend `/v1/smart_action`; manages action history for undo. |
| `Sources/VoxFlowApp/Services/VoiceCommandRouter.swift` | `nonisolated` keyword-match parser for review-state voice commands. |
| `Sources/VoxFlowApp/Views/CockpitWindowView.swift` | Top-level cockpit window SwiftUI view. |
| `Sources/VoxFlowApp/Views/Cockpit/CockpitTopBarView.swift` | Top bar with recording pill, model pill, target picker pill. |
| `Sources/VoxFlowApp/Views/Cockpit/CockpitTranscriptView.swift` | Editable transcript pane. |
| `Sources/VoxFlowApp/Views/Cockpit/CockpitChipRowView.swift` | Chip row + ⌘K all-actions overflow. |
| `Sources/VoxFlowApp/Views/Cockpit/CockpitSidePanelView.swift` | Right-side panel with Target + Recent cards. |
| `Sources/VoxFlowApp/Views/Cockpit/VoicePromptStripView.swift` | Teaching-mode voice hint strip. |

### Modified Swift files

| Path | Change |
| --- | --- |
| `Sources/VoxFlowApp/Models/AppModels.swift` | Add `LongFormSession`, `AppliedAction`, `SmartActionId` types. |
| `Sources/VoxFlowApp/State/AppState.swift` | Add `cockpitVisible`, `cockpitSession`, `chipMRU` published state. |
| `Sources/VoxFlowApp/AppCoordinator.swift` | Inject `CockpitCoordinator`; route `⌥⌘V` to `cockpitCoordinator.open()`. |
| `Sources/VoxFlowApp/Services/GlobalHotkeyService.swift` | Register `⌥⌘V` chord. |
| `Sources/VoxFlowApp/VoxFlowLocalApp.swift` | Add cockpit window scene. |

### New Python files

| Path | Responsibility |
| --- | --- |
| `backend/app/smart_actions.py` | `SmartActionEngine` class wrapping the polish backend (Ollama) with action-specific system prompts. |

### Modified Python files

| Path | Change |
| --- | --- |
| `backend/app/server.py` | Add `/v1/smart_action` route; mount `SmartActionEngine` on startup. |

### New tests

| Path | Coverage |
| --- | --- |
| `backend/tests/test_smart_actions.py` | Unit tests for each action's prompt assembly, guardrail behavior, fallback path. |
| `Tests/VoxFlowAppTests/SmartActionServiceTests.swift` | Mocked-backend tests for SmartActionService. |
| `Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift` | State machine, pause tolerance, auto-save round-trip. |
| `Tests/VoxFlowAppTests/VoiceCommandRouterTests.swift` | Keyword match, ambiguity, review-state-only rule. |
| `Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift` | MRU ordering, chip promotion threshold, undo stack. |

### Persistence directory

| Path | Content |
| --- | --- |
| `~/Library/Application Support/VoxFlow/sessions/<uuid>.json` | Long-form session drafts (auto-saved). |

---

## Phase A — Backend Smart Action Endpoint

### Task 1: SmartActionEngine with memo action (TDD)

**Files:**
- Create: `backend/app/smart_actions.py`
- Test: `backend/tests/test_smart_actions.py`

- [ ] **Step 1: Write the failing test**

```python
# backend/tests/test_smart_actions.py
import pytest
from unittest.mock import MagicMock
from backend.app.smart_actions import SmartActionEngine, SmartActionResult


def test_memo_action_returns_polished_text():
    mock_backend = MagicMock()
    mock_backend.polish.return_value = ("# Issue\nGDPR access rights...\n# Analysis\n...\n# Recommendation\n...", False)
    engine = SmartActionEngine(polish_backend=mock_backend)

    result = engine.apply(action_id="memo", transcript="data subject has right to access")

    assert isinstance(result, SmartActionResult)
    assert result.action_id == "memo"
    assert "# Issue" in result.output
    assert result.guardrail_triggered is False
    mock_backend.polish.assert_called_once()
    call_kwargs = mock_backend.polish.call_args.kwargs
    assert "memo" in call_kwargs.get("system_prompt", "").lower() or "issue" in call_kwargs.get("system_prompt", "").lower()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./.venv/bin/python -m pytest backend/tests/test_smart_actions.py -v`

Expected: `ModuleNotFoundError: No module named 'backend.app.smart_actions'`

- [ ] **Step 3: Write minimal implementation**

```python
# backend/app/smart_actions.py
from dataclasses import dataclass
from typing import Any, Optional


@dataclass(frozen=True)
class SmartActionResult:
    action_id: str
    output: str
    guardrail_triggered: bool
    error: Optional[str] = None


_ACTION_DESCRIPTIONS = {
    "memo": (
        "Restructure as a formal memo with H2 headings for "
        "Issue, Analysis, and Recommendation."
    ),
    "mece": (
        "Reorganize the content into mutually exclusive, "
        "collectively exhaustive bullet groups."
    ),
    "items": (
        "Extract a clean checkbox list of action items. "
        "Include any owners or dates mentioned."
    ),
}

_SYSTEM_PROMPT_TEMPLATE = """You are a writing assistant. Apply the requested transformation to the user's text. Return only the transformed text. No explanation, no preamble, no quotes around the output.

Transformation: {action_description}

Constraints:
- Preserve the user's meaning and intent.
- Do not add information not present in the input.
- Do not add caveats, hedging, or apologies."""


class SmartActionEngine:
    def __init__(self, polish_backend: Any):
        self._polish_backend = polish_backend

    def apply(self, action_id: str, transcript: str) -> SmartActionResult:
        description = _ACTION_DESCRIPTIONS.get(action_id)
        if description is None:
            return SmartActionResult(
                action_id=action_id,
                output=transcript,
                guardrail_triggered=False,
                error=f"unknown action: {action_id}",
            )
        system_prompt = _SYSTEM_PROMPT_TEMPLATE.format(action_description=description)
        output, guardrail = self._polish_backend.polish(
            text=transcript,
            system_prompt=system_prompt,
            tone="neutral",
        )
        return SmartActionResult(
            action_id=action_id,
            output=output,
            guardrail_triggered=guardrail,
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./.venv/bin/python -m pytest backend/tests/test_smart_actions.py -v`

Expected: 1 passed.

- [ ] **Step 5: Commit**

```bash
git add backend/app/smart_actions.py backend/tests/test_smart_actions.py
git commit -m "feat(backend): add SmartActionEngine with memo action"
```

---

### Task 2: Add MECE and action items actions

**Files:**
- Modify: `backend/app/smart_actions.py` (no new file)
- Test: `backend/tests/test_smart_actions.py`

- [ ] **Step 1: Write failing tests for MECE and items**

Append to `backend/tests/test_smart_actions.py`:

```python
def test_mece_action_invokes_backend_with_mece_prompt():
    mock_backend = MagicMock()
    mock_backend.polish.return_value = ("- People\n  - alice\n- Process\n  - approval\n- Policy\n  - GDPR §15", False)
    engine = SmartActionEngine(polish_backend=mock_backend)

    result = engine.apply(action_id="mece", transcript="people process policy")

    assert result.action_id == "mece"
    assert result.guardrail_triggered is False
    system_prompt = mock_backend.polish.call_args.kwargs["system_prompt"]
    assert "mutually exclusive" in system_prompt.lower()


def test_items_action_invokes_backend_with_action_items_prompt():
    mock_backend = MagicMock()
    mock_backend.polish.return_value = ("- [ ] Draft policy by Friday (Alice)\n- [ ] Review with legal (Bob)", False)
    engine = SmartActionEngine(polish_backend=mock_backend)

    result = engine.apply(action_id="items", transcript="Alice will draft by Friday and Bob reviews with legal")

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
```

- [ ] **Step 2: Run tests to confirm two new ones pass and the third (unknown) already passes**

Run: `./.venv/bin/python -m pytest backend/tests/test_smart_actions.py -v`

Expected: 4 passed.

(MECE/items prompts were already in `_ACTION_DESCRIPTIONS` from Task 1's minimal implementation. The passthrough behavior for unknown actions was also already there. These tests are validation, not new code.)

- [ ] **Step 3: Commit**

```bash
git add backend/tests/test_smart_actions.py
git commit -m "test(backend): cover MECE, action items, and unknown action paths"
```

---

### Task 3: Guardrail wiring and HTTP route

**Files:**
- Modify: `backend/app/server.py` (add route + Pydantic model)
- Test: `backend/tests/test_smart_actions.py` (add HTTP-level test)

- [ ] **Step 1: Write failing HTTP test**

Append to `backend/tests/test_smart_actions.py`:

```python
def test_smart_action_endpoint_memo(test_client):
    response = test_client.post(
        "/v1/smart_action",
        json={"action_id": "memo", "transcript": "the data controller has rights under article 15"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["action_id"] == "memo"
    assert "output" in body
    assert "guardrail_triggered" in body
```

This assumes a `test_client` fixture exists in `backend/tests/conftest.py` (it does — see `test_endpoints.py`).

- [ ] **Step 2: Run to verify it fails**

Run: `./.venv/bin/python -m pytest backend/tests/test_smart_actions.py::test_smart_action_endpoint_memo -v`

Expected: 404 (route doesn't exist).

- [ ] **Step 3: Add Pydantic models and route to server.py**

In `backend/app/server.py`, locate the Pydantic models section (~line 113) and add:

```python
class SmartActionRequest(BaseModel):
    action_id: str = Field(min_length=1, max_length=32)
    transcript: str = Field(min_length=1, max_length=50_000)


class SmartActionResponse(BaseModel):
    action_id: str
    output: str
    guardrail_triggered: bool
    error: str | None = None
```

In the route handlers section near the other workflow endpoints (~line 2240, near `/v1/prompt/frame`), add:

```python
@app.post("/v1/smart_action", response_model=SmartActionResponse)
def smart_action(payload: SmartActionRequest) -> SmartActionResponse:
    engine = _smart_action_engine
    if engine is None:
        raise HTTPException(status_code=503, detail="smart action engine not initialised")
    result = engine.apply(action_id=payload.action_id, transcript=payload.transcript)
    return SmartActionResponse(
        action_id=result.action_id,
        output=result.output,
        guardrail_triggered=result.guardrail_triggered,
        error=result.error,
    )
```

In the module-level singletons section (~line 1977), instantiate the engine after `PolishEngine` is created:

```python
from backend.app.smart_actions import SmartActionEngine

_smart_action_engine: SmartActionEngine | None = None
```

In `initialize_runtime_state()` (~line 1910), after `_polish_engine` is set, add:

```python
global _smart_action_engine
_smart_action_engine = SmartActionEngine(polish_backend=_polish_engine)
```

- [ ] **Step 4: Run HTTP test to verify it passes**

Run: `./.venv/bin/python -m pytest backend/tests/test_smart_actions.py -v`

Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add backend/app/server.py backend/tests/test_smart_actions.py
git commit -m "feat(backend): expose /v1/smart_action HTTP endpoint"
```

---

## Phase B — Swift Session Core

### Task 4: SmartActionService actor with mocked backend

**Files:**
- Create: `Sources/VoxFlowApp/Services/SmartActionService.swift`
- Test: `Tests/VoxFlowAppTests/SmartActionServiceTests.swift`

- [ ] **Step 1: Define SmartActionId in AppModels**

In `Sources/VoxFlowApp/Models/AppModels.swift`, add near other workflow enums:

```swift
enum SmartActionId: String, Codable, CaseIterable, Sendable {
    case memo
    case mece
    case items
    case steel
    case pyramid
    case disclaimer
}

struct SmartActionResult: Sendable, Equatable {
    let actionId: SmartActionId
    let output: String
    let guardrailTriggered: Bool
    let error: String?
}

struct AppliedAction: Codable, Sendable, Equatable {
    let actionId: SmartActionId
    let appliedAt: Date
    let beforeText: String
    let afterText: String
}
```

- [ ] **Step 2: Write failing test**

```swift
// Tests/VoxFlowAppTests/SmartActionServiceTests.swift
import XCTest
@testable import VoxFlowApp

final class SmartActionServiceTests: XCTestCase {
    func test_apply_returns_transformed_text() async throws {
        let stub = StubBackend(response: .success(.init(
            actionId: .memo,
            output: "# Issue\n...\n# Recommendation\n...",
            guardrailTriggered: false,
            error: nil
        )))
        let service = SmartActionService(backend: stub)

        let result = try await service.apply(.memo, to: "raw transcript")

        XCTAssertEqual(result.actionId, .memo)
        XCTAssertTrue(result.output.contains("# Issue"))
        XCTAssertFalse(result.guardrailTriggered)
    }
}

private final class StubBackend: SmartActionBackend, @unchecked Sendable {
    private let response: Result<SmartActionResult, Error>
    init(response: Result<SmartActionResult, Error>) { self.response = response }
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        try response.get()
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter SmartActionServiceTests`

Expected: Build error — `SmartActionService` and `SmartActionBackend` not defined.

- [ ] **Step 4: Write minimal implementation**

```swift
// Sources/VoxFlowApp/Services/SmartActionService.swift
import Foundation
import os

protocol SmartActionBackend: Sendable {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult
}

actor SmartActionService {
    private let backend: SmartActionBackend
    private let log = Logger(subsystem: "local.voxflow.app", category: "SmartActionService")
    private var history: [(SmartActionId, String, String)] = []

    init(backend: SmartActionBackend) {
        self.backend = backend
    }

    func apply(_ action: SmartActionId, to transcript: String) async throws -> SmartActionResult {
        log.info("applying \(action.rawValue) to \(transcript.count) chars")
        let result = try await backend.performSmartAction(action, transcript: transcript)
        if !result.guardrailTriggered {
            history.append((action, transcript, result.output))
            if history.count > 20 { history.removeFirst() }
        }
        return result
    }

    func lastBeforeText() -> String? {
        history.last?.1
    }

    func popLast() -> (SmartActionId, String)? {
        guard let last = history.popLast() else { return nil }
        return (last.0, last.1)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter SmartActionServiceTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/VoxFlowApp/Models/AppModels.swift Sources/VoxFlowApp/Services/SmartActionService.swift Tests/VoxFlowAppTests/SmartActionServiceTests.swift
git commit -m "feat: add SmartActionService actor with action history"
```

---

### Task 5: Wire SmartActionService to BackendAPIClient

**Files:**
- Modify: `Sources/VoxFlowApp/Services/BackendAPIClient.swift`
- Test: `Tests/VoxFlowAppTests/BackendAPIClientTests.swift`

- [ ] **Step 1: Write failing test using mocked URLProtocol**

Append to `Tests/VoxFlowAppTests/BackendAPIClientTests.swift`:

```swift
func test_performSmartAction_decodes_response() async throws {
    URLProtocolMock.responses["http://127.0.0.1:8765/v1/smart_action"] = (
        Data("""
        {"action_id":"memo","output":"# Issue\\n...\\n# Recommendation\\n...","guardrail_triggered":false,"error":null}
        """.utf8),
        200
    )
    let client = makeTestClient()  // existing helper; uses URLProtocolMock

    let result = try await client.performSmartAction(.memo, transcript: "raw")

    XCTAssertEqual(result.actionId, .memo)
    XCTAssertTrue(result.output.contains("# Issue"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BackendAPIClientTests.test_performSmartAction_decodes_response`

Expected: Build error — `performSmartAction` not defined.

- [ ] **Step 3: Add method to BackendAPIClient**

In `Sources/VoxFlowApp/Services/BackendAPIClient.swift`, add a method (matching existing patterns):

```swift
extension BackendAPIClient: SmartActionBackend {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        struct Request: Encodable { let action_id: String; let transcript: String }
        struct Response: Decodable {
            let action_id: String
            let output: String
            let guardrail_triggered: Bool
            let error: String?
        }
        let body = Request(action_id: action.rawValue, transcript: transcript)
        let response: Response = try await post("/v1/smart_action", body: body)
        let actionId = SmartActionId(rawValue: response.action_id) ?? action
        return SmartActionResult(
            actionId: actionId,
            output: response.output,
            guardrailTriggered: response.guardrail_triggered,
            error: response.error
        )
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter BackendAPIClientTests`

Expected: All BackendAPIClient tests pass, including the new one.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/BackendAPIClient.swift Tests/VoxFlowAppTests/BackendAPIClientTests.swift
git commit -m "feat: BackendAPIClient conforms to SmartActionBackend"
```

---

### Task 6: LongFormSessionService state machine

**Files:**
- Create: `Sources/VoxFlowApp/Services/LongFormSessionService.swift`
- Test: `Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift`

- [ ] **Step 1: Add LongFormSession type to AppModels**

In `Sources/VoxFlowApp/Models/AppModels.swift`:

```swift
struct LongFormSession: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    var transcript: String
    var targetApp: FocusTargetSnapshot?
    var appliedActions: [AppliedAction]
    var updatedAt: Date

    init(id: UUID = UUID(), createdAt: Date = Date(), transcript: String = "", targetApp: FocusTargetSnapshot? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.transcript = transcript
        self.targetApp = targetApp
        self.appliedActions = []
        self.updatedAt = createdAt
    }
}

enum LongFormState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date)
    case reviewing
}
```

- [ ] **Step 2: Write failing state machine tests**

```swift
// Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift
import XCTest
@testable import VoxFlowApp

@MainActor
final class LongFormSessionServiceTests: XCTestCase {
    func test_initial_state_is_idle() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.currentSession)
    }

    func test_start_transitions_to_recording_and_creates_session() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        if case .recording = service.state {} else { XCTFail("expected recording state") }
        XCTAssertNotNil(service.currentSession)
        XCTAssertEqual(service.currentSession?.transcript, "")
    }

    func test_stop_after_start_transitions_to_reviewing() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendChunk("hello world")
        service.stop()
        XCTAssertEqual(service.state, .reviewing)
        XCTAssertEqual(service.currentSession?.transcript, "hello world")
    }

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voxflow-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter LongFormSessionServiceTests`

Expected: Build error — `LongFormSessionService` not defined.

- [ ] **Step 4: Write minimal implementation**

```swift
// Sources/VoxFlowApp/Services/LongFormSessionService.swift
import Foundation
import os
import SwiftUI

@MainActor
final class LongFormSessionService: ObservableObject {
    @Published private(set) var state: LongFormState = .idle
    @Published private(set) var currentSession: LongFormSession?

    private let autoSaveDirectory: URL
    private let log = Logger(subsystem: "local.voxflow.app", category: "LongFormSessionService")

    init(autoSaveDirectory: URL) {
        self.autoSaveDirectory = autoSaveDirectory
        try? FileManager.default.createDirectory(at: autoSaveDirectory, withIntermediateDirectories: true)
    }

    func start(targetApp: FocusTargetSnapshot? = nil) {
        let session = LongFormSession(targetApp: targetApp)
        currentSession = session
        state = .recording(startedAt: Date())
        log.info("session \(session.id.uuidString) started")
    }

    func appendChunk(_ chunk: String) {
        guard case .recording = state else { return }
        currentSession?.transcript += chunk
        currentSession?.updatedAt = Date()
    }

    func stop() {
        guard case .recording = state else { return }
        state = .reviewing
        log.info("session stopped at \(self.currentSession?.transcript.count ?? 0) chars")
    }

    func reset() {
        currentSession = nil
        state = .idle
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LongFormSessionServiceTests`

Expected: 3 passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/VoxFlowApp/Models/AppModels.swift Sources/VoxFlowApp/Services/LongFormSessionService.swift Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift
git commit -m "feat: LongFormSessionService with idle/recording/reviewing state machine"
```

---

### Task 7: Pause tolerance and soft paragraph break

**Files:**
- Modify: `Sources/VoxFlowApp/Services/LongFormSessionService.swift`
- Test: `Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift`

- [ ] **Step 1: Write failing test for paragraph break after silence**

Append to `LongFormSessionServiceTests`:

```swift
func test_silence_longer_than_4s_inserts_paragraph_break() {
    let service = LongFormSessionService(autoSaveDirectory: tempDir(), clock: TestClock())
    let clock = service.clock as! TestClock
    service.start()
    service.appendChunk("first sentence.")
    clock.advance(by: 5.0)
    service.noteSilence()
    service.appendChunk("second sentence.")
    XCTAssertEqual(service.currentSession?.transcript, "first sentence.\n\nsecond sentence.")
}
```

This requires injecting a clock. Add `TestClock` helper:

```swift
final class TestClock: SessionClock {
    private(set) var now: Date = Date(timeIntervalSince1970: 1_000_000)
    func currentTime() -> Date { now }
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "LongFormSessionServiceTests/test_silence_longer_than_4s_inserts_paragraph_break"`

Expected: Build error — `noteSilence`, `SessionClock`, clock parameter not defined.

- [ ] **Step 3: Add SessionClock protocol and pause logic**

In `Sources/VoxFlowApp/Services/LongFormSessionService.swift`, add at top:

```swift
protocol SessionClock: AnyObject, Sendable {
    func currentTime() -> Date
}

final class SystemClock: SessionClock {
    func currentTime() -> Date { Date() }
}
```

Update `LongFormSessionService`:

```swift
let clock: SessionClock
private var lastChunkAt: Date?
private static let paragraphBreakSilence: TimeInterval = 4.0

init(autoSaveDirectory: URL, clock: SessionClock = SystemClock()) {
    self.autoSaveDirectory = autoSaveDirectory
    self.clock = clock
    try? FileManager.default.createDirectory(at: autoSaveDirectory, withIntermediateDirectories: true)
}

func appendChunk(_ chunk: String) {
    guard case .recording = state else { return }
    let now = clock.currentTime()
    if let last = lastChunkAt,
       now.timeIntervalSince(last) >= Self.paragraphBreakSilence,
       let session = currentSession,
       !session.transcript.isEmpty,
       !session.transcript.hasSuffix("\n\n") {
        currentSession?.transcript += "\n\n"
    }
    currentSession?.transcript += chunk
    currentSession?.updatedAt = now
    lastChunkAt = now
}

func noteSilence() {
    // Mark a silence event so the next chunk evaluates the gap. No-op in the
    // pure state model — clock-based logic in appendChunk handles it.
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "LongFormSessionServiceTests/test_silence_longer_than_4s_inserts_paragraph_break"`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/LongFormSessionService.swift Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift
git commit -m "feat: LongFormSessionService inserts paragraph break after 4s silence"
```

---

### Task 8: Auto-save to disk every 5 seconds

**Files:**
- Modify: `Sources/VoxFlowApp/Services/LongFormSessionService.swift`
- Test: `Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift`

- [ ] **Step 1: Write failing test for disk persistence**

```swift
func test_stop_saves_session_to_disk() throws {
    let dir = tempDir()
    let service = LongFormSessionService(autoSaveDirectory: dir)
    service.start()
    service.appendChunk("important content")
    service.stop()
    let id = try XCTUnwrap(service.currentSession?.id)

    let fileURL = dir.appendingPathComponent("\(id.uuidString).json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let data = try Data(contentsOf: fileURL)
    let decoded = try JSONDecoder().decode(LongFormSession.self, from: data)
    XCTAssertEqual(decoded.transcript, "important content")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "LongFormSessionServiceTests/test_stop_saves_session_to_disk"`

Expected: Assertion failure — file does not exist.

- [ ] **Step 3: Add save-on-stop**

In `LongFormSessionService.swift`, add private helper and call in `stop()`:

```swift
private func save() {
    guard let session = currentSession else { return }
    let url = autoSaveDirectory.appendingPathComponent("\(session.id.uuidString).json")
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url, options: .atomic)
    } catch {
        log.error("auto-save failed: \(error.localizedDescription)")
    }
}

func stop() {
    guard case .recording = state else { return }
    state = .reviewing
    save()
    log.info("session stopped at \(self.currentSession?.transcript.count ?? 0) chars")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "LongFormSessionServiceTests/test_stop_saves_session_to_disk"`

Expected: PASS.

- [ ] **Step 5: Add periodic auto-save during recording**

Add a Task-based timer in `start()`:

```swift
private var autoSaveTask: Task<Void, Never>?

func start(targetApp: FocusTargetSnapshot? = nil) {
    let session = LongFormSession(targetApp: targetApp)
    currentSession = session
    state = .recording(startedAt: Date())
    lastChunkAt = nil
    autoSaveTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            await MainActor.run {
                if case .recording = self.state {
                    self.save()
                }
            }
        }
    }
    log.info("session \(session.id.uuidString) started")
}

func stop() {
    guard case .recording = state else { return }
    autoSaveTask?.cancel()
    autoSaveTask = nil
    state = .reviewing
    save()
    log.info("session stopped at \(self.currentSession?.transcript.count ?? 0) chars")
}
```

- [ ] **Step 6: Run full suite to ensure no regressions**

Run: `swift test --filter LongFormSessionServiceTests`

Expected: 5 passed (initial 3 + paragraph + save-on-stop).

- [ ] **Step 7: Commit**

```bash
git add Sources/VoxFlowApp/Services/LongFormSessionService.swift Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift
git commit -m "feat: LongFormSessionService persists to disk on stop and every 5s while recording"
```

---

### Task 9: Session recovery on launch

**Files:**
- Modify: `Sources/VoxFlowApp/Services/LongFormSessionService.swift`
- Test: `Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift`

- [ ] **Step 1: Write failing recovery test**

```swift
func test_recover_loads_most_recent_unfinished_session() throws {
    let dir = tempDir()
    let oldSession = LongFormSession(transcript: "old content")
    let newSession = LongFormSession(transcript: "new content")
    try persist(oldSession, in: dir, withUpdatedAt: Date(timeIntervalSinceNow: -3600))
    try persist(newSession, in: dir, withUpdatedAt: Date())

    let service = LongFormSessionService(autoSaveDirectory: dir)
    let recovered = service.recoverLatestSession()

    XCTAssertNotNil(recovered)
    XCTAssertEqual(recovered?.transcript, "new content")
}

private func persist(_ session: LongFormSession, in dir: URL, withUpdatedAt: Date) throws {
    var s = session
    s.updatedAt = withUpdatedAt
    let url = dir.appendingPathComponent("\(s.id.uuidString).json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(s).write(to: url, options: .atomic)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "LongFormSessionServiceTests/test_recover_loads_most_recent_unfinished_session"`

Expected: Build error — `recoverLatestSession` not defined.

- [ ] **Step 3: Implement recovery**

```swift
func recoverLatestSession() -> LongFormSession? {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(at: autoSaveDirectory,
                                                  includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: [.skipsHiddenFiles]) else { return nil }
    let sessions = urls
        .filter { $0.pathExtension == "json" }
        .compactMap { (url: URL) -> LongFormSession? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(LongFormSession.self, from: data)
        }
    return sessions.max(by: { $0.updatedAt < $1.updatedAt })
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "LongFormSessionServiceTests/test_recover_loads_most_recent_unfinished_session"`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/LongFormSessionService.swift Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift
git commit -m "feat: LongFormSessionService can recover the most recent session"
```

---

## Phase C — Cockpit UI

### Task 10: CockpitCoordinator skeleton

**Files:**
- Create: `Sources/VoxFlowApp/Services/CockpitCoordinator.swift`
- Test: `Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift`
- Modify: `Sources/VoxFlowApp/State/AppState.swift` (add `cockpitVisible`)

- [ ] **Step 1: Add cockpit state to AppState**

In `Sources/VoxFlowApp/State/AppState.swift`, add:

```swift
@Published var cockpitVisible: Bool = false
@Published var cockpitSession: LongFormSession?
@Published var chipMRU: [SmartActionId] = [.memo, .mece, .items]
@Published var chipInvocationCounts: [SmartActionId: Int] = [:]
```

- [ ] **Step 2: Write failing test**

```swift
// Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift
import XCTest
@testable import VoxFlowApp

@MainActor
final class CockpitCoordinatorTests: XCTestCase {
    func test_open_sets_cockpitVisible_true() {
        let state = AppState()
        let coord = CockpitCoordinator(state: state, sessionService: makeSessionService(), actionService: makeActionService())
        coord.open()
        XCTAssertTrue(state.cockpitVisible)
    }

    func test_close_sets_cockpitVisible_false() {
        let state = AppState()
        let coord = CockpitCoordinator(state: state, sessionService: makeSessionService(), actionService: makeActionService())
        coord.open()
        coord.close()
        XCTAssertFalse(state.cockpitVisible)
    }

    private func makeSessionService() -> LongFormSessionService {
        LongFormSessionService(autoSaveDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cockpit-test-\(UUID())"))
    }

    private func makeActionService() -> SmartActionService {
        SmartActionService(backend: StubActionBackend())
    }
}

private final class StubActionBackend: SmartActionBackend, @unchecked Sendable {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        SmartActionResult(actionId: action, output: transcript + " transformed", guardrailTriggered: false, error: nil)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter CockpitCoordinatorTests`

Expected: Build error — `CockpitCoordinator` not defined.

- [ ] **Step 4: Write minimal implementation**

```swift
// Sources/VoxFlowApp/Services/CockpitCoordinator.swift
import Foundation
import os
import SwiftUI

@MainActor
final class CockpitCoordinator: ObservableObject {
    private let state: AppState
    let sessionService: LongFormSessionService
    let actionService: SmartActionService
    private let log = Logger(subsystem: "local.voxflow.app", category: "CockpitCoordinator")

    init(state: AppState, sessionService: LongFormSessionService, actionService: SmartActionService) {
        self.state = state
        self.sessionService = sessionService
        self.actionService = actionService
    }

    func open() {
        state.cockpitVisible = true
        log.info("cockpit opened")
    }

    func close() {
        state.cockpitVisible = false
        log.info("cockpit closed")
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter CockpitCoordinatorTests`

Expected: 2 passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/VoxFlowApp/Services/CockpitCoordinator.swift Sources/VoxFlowApp/State/AppState.swift Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift
git commit -m "feat: add CockpitCoordinator skeleton owning open/close state"
```

---

### Task 11: Wire ⌥⌘V hotkey to open cockpit

**Files:**
- Modify: `Sources/VoxFlowApp/Services/GlobalHotkeyService.swift`
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift`

- [ ] **Step 1: Add cockpit hotkey registration to GlobalHotkeyService**

In `Sources/VoxFlowApp/Services/GlobalHotkeyService.swift`, locate where hotkeys are registered (existing pattern). Add new method:

```swift
func registerCockpitHotkey(_ handler: @escaping () -> Void) {
    let modifiers: UInt32 = UInt32(optionKey | cmdKey)
    let keyCode: UInt32 = 9  // V
    register(modifiers: modifiers, keyCode: keyCode, id: 0xCAFE, handler: handler)
}
```

(If the existing service does not have a generic `register(modifiers:keyCode:id:handler:)` method, factor one out from the existing `registerDictationHotkey` implementation before adding the cockpit method.)

- [ ] **Step 2: Wire handler in AppCoordinator**

In `Sources/VoxFlowApp/AppCoordinator.swift`, in the initialization where global hotkeys are wired:

```swift
hotkeyService.registerCockpitHotkey { [weak self] in
    Task { @MainActor in
        self?.cockpitCoordinator.open()
    }
}
```

Add `cockpitCoordinator` as a property of `AppCoordinator`:

```swift
let cockpitCoordinator: CockpitCoordinator

init(...) {
    let smartActionService = SmartActionService(backend: backendClient)
    let sessionDir = URL.applicationSupportDirectory.appendingPathComponent("VoxFlow/sessions")
    let sessionService = LongFormSessionService(autoSaveDirectory: sessionDir)
    self.cockpitCoordinator = CockpitCoordinator(state: state, sessionService: sessionService, actionService: smartActionService)
    ...
}
```

- [ ] **Step 3: Build to verify**

Run: `swift build`

Expected: Build succeeds. No new warnings.

- [ ] **Step 4: Commit**

```bash
git add Sources/VoxFlowApp/Services/GlobalHotkeyService.swift Sources/VoxFlowApp/AppCoordinator.swift
git commit -m "feat: ⌥⌘V hotkey opens cockpit"
```

---

### Task 12: CockpitWindowView skeleton

**Files:**
- Create: `Sources/VoxFlowApp/Views/CockpitWindowView.swift`
- Modify: `Sources/VoxFlowApp/VoxFlowLocalApp.swift` (add Window scene)

- [ ] **Step 1: Add the window scene**

In `Sources/VoxFlowApp/VoxFlowLocalApp.swift`, add a Window scene gated on `state.cockpitVisible`:

```swift
WindowGroup("VoxFlow Cockpit", id: "cockpit") {
    CockpitWindowView()
        .environmentObject(appCoordinator)
        .environmentObject(appCoordinator.cockpitCoordinator)
        .frame(minWidth: 720, minHeight: 480)
}
.windowResizability(.contentSize)
.defaultPosition(.center)
.commands {
    CommandGroup(replacing: .newItem) { }
}
```

Wire `state.cockpitVisible` changes to open/close the window using `openWindow`/`dismissWindow` environment values inside `CockpitWindowView`'s `.onChange(of: state.cockpitVisible)`.

- [ ] **Step 2: Write minimal view**

```swift
// Sources/VoxFlowApp/Views/CockpitWindowView.swift
import SwiftUI

struct CockpitWindowView: View {
    @EnvironmentObject var coordinator: CockpitCoordinator
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            CockpitTopBarView()
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.thinMaterial)
            HStack(spacing: 0) {
                CockpitTranscriptView()
                CockpitSidePanelView()
                    .frame(width: 240)
            }
            CockpitChipRowView()
                .padding(12)
                .background(.thinMaterial)
        }
        .background(.regularMaterial)
        .frame(minWidth: 720, minHeight: 480)
    }
}
```

Views access the long-form session through `coordinator.sessionService` rather than holding their own `@ObservedObject` — the coordinator is the single owner.

Subviews observe the session service via `@ObservedObject` on a property the parent passes:

```swift
// Inside CockpitTopBarView, CockpitTranscriptView, etc.:
@EnvironmentObject var coordinator: CockpitCoordinator

// Then access via coordinator.sessionService.state, coordinator.sessionService.currentSession, etc.
```

Since `LongFormSessionService` is `@MainActor ObservableObject`, subviews can also use `@ObservedObject` if they prefer reactive updates, but reading through `coordinator.sessionService` works because `CockpitCoordinator` exposes it as a `let` property.

Note: this references `CockpitTopBarView`, `CockpitTranscriptView`, `CockpitSidePanelView`, `CockpitChipRowView` which are stubs added in subsequent tasks. For this task, add empty stubs so the build succeeds:

```swift
// Sources/VoxFlowApp/Views/Cockpit/CockpitTopBarView.swift
import SwiftUI
struct CockpitTopBarView: View {
    var body: some View { Text("Cockpit").font(.caption) }
}
// ... and likewise for CockpitTranscriptView, CockpitSidePanelView, CockpitChipRowView
```

- [ ] **Step 3: Build**

Run: `swift build`

Expected: Build succeeds. Cockpit window scene exists but content is placeholder.

- [ ] **Step 4: Commit**

```bash
git add Sources/VoxFlowApp/Views/ Sources/VoxFlowApp/VoxFlowLocalApp.swift
git commit -m "feat: CockpitWindowView skeleton with placeholder subviews"
```

---

### Task 13: Top bar with recording, model, target pills

**Files:**
- Replace stub: `Sources/VoxFlowApp/Views/Cockpit/CockpitTopBarView.swift`

- [ ] **Step 1: Replace stub with real top bar**

```swift
import SwiftUI

struct CockpitTopBarView: View {
    @EnvironmentObject var coordinator: CockpitCoordinator
    @ObservedObject var sessionService: LongFormSessionService

    var body: some View {
        HStack {
            recordingPill
            modelPill
            Spacer()
            targetPill
        }
        .font(.system(size: 11))
    }

    @ViewBuilder private var recordingPill: some View {
        switch sessionService.state {
        case .idle:
            pill("● ready", tint: .secondary)
        case .recording(let startedAt):
            pill("● recording · \(elapsed(since: startedAt))", tint: .red)
        case .reviewing:
            pill("● review", tint: .blue)
        }
    }

    private var modelPill: some View {
        pill("gemma4:e4b-mlx", tint: .secondary)
    }

    @ViewBuilder private var targetPill: some View {
        if let target = sessionService.currentSession?.targetApp {
            pill("→ \(target.localizedName)", tint: .blue)
        } else {
            pill("→ focused app", tint: .secondary)
        }
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(tint)
    }

    private func elapsed(since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/VoxFlowApp/Views/Cockpit/CockpitTopBarView.swift
git commit -m "feat: cockpit top bar with recording, model, target pills"
```

---

### Task 14: Chip row + click-to-apply + ⌘1-3 shortcuts

**Files:**
- Replace stub: `Sources/VoxFlowApp/Views/Cockpit/CockpitChipRowView.swift`
- Test: `Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift` (add invocation test)

- [ ] **Step 1: Write failing test for action invocation tracking**

Append to `CockpitCoordinatorTests`:

```swift
func test_applyAction_increments_invocation_count() async throws {
    let state = AppState()
    let coord = CockpitCoordinator(state: state, sessionService: makeSessionService(), actionService: makeActionService())

    try await coord.applyAction(.memo, to: "raw")

    XCTAssertEqual(state.chipInvocationCounts[.memo], 1)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "CockpitCoordinatorTests/test_applyAction_increments_invocation_count"`

Expected: Build error — `applyAction` not defined.

- [ ] **Step 3: Add applyAction to CockpitCoordinator**

In `CockpitCoordinator.swift`:

```swift
func applyAction(_ action: SmartActionId, to transcript: String) async throws -> SmartActionResult {
    let result = try await actionService.apply(action, to: transcript)
    state.chipInvocationCounts[action, default: 0] += 1
    if let session = sessionService.currentSession {
        sessionService.recordAppliedAction(AppliedAction(
            actionId: action,
            appliedAt: Date(),
            beforeText: transcript,
            afterText: result.output
        ))
    }
    return result
}
```

Add `recordAppliedAction` on `LongFormSessionService`:

```swift
func recordAppliedAction(_ applied: AppliedAction) {
    currentSession?.appliedActions.append(applied)
    currentSession?.transcript = applied.afterText
    save()
}
```

- [ ] **Step 4: Run test**

Run: `swift test --filter "CockpitCoordinatorTests/test_applyAction_increments_invocation_count"`

Expected: PASS.

- [ ] **Step 5: Build the chip row UI**

```swift
// Sources/VoxFlowApp/Views/Cockpit/CockpitChipRowView.swift
import SwiftUI

struct CockpitChipRowView: View {
    @EnvironmentObject var coordinator: CockpitCoordinator
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(state.chipMRU.prefix(6).enumerated()), id: \.element) { index, action in
                chip(for: action, shortcut: index + 1)
            }
            Spacer()
            Button("⌘K all actions") { /* opens palette — Task 16 */ }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func chip(for action: SmartActionId, shortcut: Int) -> some View {
        Button {
            Task { try? await applyChip(action) }
        } label: {
            HStack(spacing: 4) {
                Text(action.label)
                Text("⌘\(shortcut)")
                    .font(.system(size: 9, design: .monospaced))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(.tertiary, in: RoundedRectangle(cornerRadius: 3))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(KeyEquivalent(Character("\(shortcut)")), modifiers: .command)
    }

    private func applyChip(_ action: SmartActionId) async throws {
        guard let transcript = coordinator.sessionService.currentSession?.transcript else { return }
        _ = try await coordinator.applyAction(action, to: transcript)
    }
}

extension SmartActionId {
    var label: String {
        switch self {
        case .memo: return "memo"
        case .mece: return "MECE"
        case .items: return "action items"
        case .steel: return "steel-man"
        case .pyramid: return "Pyramid"
        case .disclaimer: return "disclaimer"
        }
    }
}
```

- [ ] **Step 6: Build**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/VoxFlowApp/Services/CockpitCoordinator.swift Sources/VoxFlowApp/Services/LongFormSessionService.swift Sources/VoxFlowApp/Views/Cockpit/CockpitChipRowView.swift Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift
git commit -m "feat: chip row with click-to-apply and ⌘1-3 shortcuts"
```

---

### Task 15: VoiceCommandRouter with keyword match

**Files:**
- Create: `Sources/VoxFlowApp/Services/VoiceCommandRouter.swift`
- Test: `Tests/VoxFlowAppTests/VoiceCommandRouterTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/VoxFlowAppTests/VoiceCommandRouterTests.swift
import XCTest
@testable import VoxFlowApp

final class VoiceCommandRouterTests: XCTestCase {
    func test_memo_keyword_resolves_to_memo_action() {
        XCTAssertEqual(VoiceCommandRouter.parse("memo"), .action(.memo))
        XCTAssertEqual(VoiceCommandRouter.parse("Memo."), .action(.memo))
        XCTAssertEqual(VoiceCommandRouter.parse("  MEMO  "), .action(.memo))
    }

    func test_each_action_keyword_maps_correctly() {
        XCTAssertEqual(VoiceCommandRouter.parse("MECE"), .action(.mece))
        XCTAssertEqual(VoiceCommandRouter.parse("items"), .action(.items))
        XCTAssertEqual(VoiceCommandRouter.parse("steel"), .action(.steel))
        XCTAssertEqual(VoiceCommandRouter.parse("Pyramid"), .action(.pyramid))
        XCTAssertEqual(VoiceCommandRouter.parse("disclaimer"), .action(.disclaimer))
    }

    func test_meta_keywords() {
        XCTAssertEqual(VoiceCommandRouter.parse("undo"), .undo)
        XCTAssertEqual(VoiceCommandRouter.parse("cancel"), .cancel)
        XCTAssertEqual(VoiceCommandRouter.parse("insert"), .insert)
        XCTAssertEqual(VoiceCommandRouter.parse("copy"), .copy)
    }

    func test_unknown_returns_none() {
        XCTAssertEqual(VoiceCommandRouter.parse("hello"), VoiceCommand.none)
        XCTAssertEqual(VoiceCommandRouter.parse(""), VoiceCommand.none)
        XCTAssertEqual(VoiceCommandRouter.parse("memo and then mece"), VoiceCommand.none)  // multi-word = not command
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter VoiceCommandRouterTests`

Expected: Build error.

- [ ] **Step 3: Implement**

```swift
// Sources/VoxFlowApp/Services/VoiceCommandRouter.swift
import Foundation

enum VoiceCommand: Equatable {
    case none
    case action(SmartActionId)
    case undo
    case cancel
    case insert
    case copy
}

enum VoiceCommandRouter {
    private static let actionKeywords: [String: SmartActionId] = [
        "memo": .memo,
        "mece": .mece,
        "items": .items,
        "steel": .steel,
        "pyramid": .pyramid,
        "disclaimer": .disclaimer,
    ]

    private static let metaKeywords: [String: VoiceCommand] = [
        "undo": .undo,
        "cancel": .cancel,
        "insert": .insert,
        "copy": .copy,
    ]

    static func parse(_ raw: String) -> VoiceCommand {
        let stripped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            .lowercased()
        guard !stripped.isEmpty else { return .none }
        // single-word rule: anything with whitespace is not a command
        guard !stripped.contains(where: { $0.isWhitespace }) else { return .none }
        if let action = actionKeywords[stripped] { return .action(action) }
        if let meta = metaKeywords[stripped] { return meta }
        return .none
    }
}
```

- [ ] **Step 4: Run test**

Run: `swift test --filter VoiceCommandRouterTests`

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/VoiceCommandRouter.swift Tests/VoxFlowAppTests/VoiceCommandRouterTests.swift
git commit -m "feat: VoiceCommandRouter with single-keyword parsing"
```

---

### Task 16: Wire voice router into review state

**Files:**
- Modify: `Sources/VoxFlowApp/Services/CockpitCoordinator.swift`
- Test: `Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift`

- [ ] **Step 1: Write failing test**

```swift
func test_handleVoiceUtterance_in_review_state_triggers_action() async throws {
    let state = AppState()
    let sessionService = makeSessionService()
    let coord = CockpitCoordinator(state: state, sessionService: sessionService, actionService: makeActionService())
    sessionService.start()
    sessionService.appendChunk("source text")
    sessionService.stop()  // moves to reviewing

    try await coord.handleVoiceUtterance("memo")

    XCTAssertEqual(state.chipInvocationCounts[.memo], 1)
}

func test_handleVoiceUtterance_during_recording_is_ignored() async throws {
    let state = AppState()
    let sessionService = makeSessionService()
    let coord = CockpitCoordinator(state: state, sessionService: sessionService, actionService: makeActionService())
    sessionService.start()  // recording, not reviewing

    try await coord.handleVoiceUtterance("memo")

    XCTAssertNil(state.chipInvocationCounts[.memo])
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "CockpitCoordinatorTests/test_handleVoiceUtterance"`

Expected: Build error.

- [ ] **Step 3: Add handler**

In `CockpitCoordinator.swift`:

```swift
func handleVoiceUtterance(_ raw: String) async throws {
    guard sessionService.state == .reviewing else { return }
    switch VoiceCommandRouter.parse(raw) {
    case .none: return
    case .action(let id):
        guard let transcript = sessionService.currentSession?.transcript else { return }
        _ = try await applyAction(id, to: transcript)
    case .undo: undoLastAction()
    case .cancel: sessionService.reset()
    case .insert: break  // Task 21
    case .copy: break  // Task 21
    }
}

func undoLastAction() {
    Task {
        if let (_, beforeText) = await actionService.popLast() {
            await MainActor.run {
                sessionService.currentSession?.transcript = beforeText
            }
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter "CockpitCoordinatorTests/test_handleVoiceUtterance"`

Expected: Both pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/CockpitCoordinator.swift Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift
git commit -m "feat: voice commands route to actions only during review state"
```

---

### Task 17: ⌘K full action palette

**Files:**
- Create: `Sources/VoxFlowApp/Views/Cockpit/ActionPaletteView.swift`
- Modify: `CockpitWindowView.swift` (present ⌘K sheet)

- [ ] **Step 1: Add the palette view**

```swift
// Sources/VoxFlowApp/Views/Cockpit/ActionPaletteView.swift
import SwiftUI

struct ActionPaletteView: View {
    @EnvironmentObject var coordinator: CockpitCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Type an action...", text: $query)
                .textFieldStyle(.plain)
                .padding(12)
                .background(.thinMaterial)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(SmartActionId.allCases.filter { matches(query, $0) }, id: \.self) { id in
                        Button {
                            apply(id)
                        } label: {
                            HStack {
                                Text(id.label).font(.system(size: 13))
                                Spacer()
                                Text(id.shortDescription)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 440, height: 320)
    }

    private func matches(_ q: String, _ id: SmartActionId) -> Bool {
        guard !q.isEmpty else { return true }
        return id.label.localizedCaseInsensitiveContains(q)
    }

    private func apply(_ id: SmartActionId) {
        dismiss()
        Task {
            guard let transcript = coordinator.sessionService.currentSession?.transcript else { return }
            _ = try? await coordinator.applyAction(id, to: transcript)
        }
    }
}

extension SmartActionId {
    var shortDescription: String {
        switch self {
        case .memo: return "Issue / Analysis / Recommendation"
        case .mece: return "Mutually exclusive bullet groups"
        case .items: return "Extract action items"
        case .steel: return "Steel-man the position"
        case .pyramid: return "Pyramid Principle structure"
        case .disclaimer: return "Append your disclaimer"
        }
    }
}
```

- [ ] **Step 2: Present from CockpitWindowView**

In `CockpitWindowView.swift`, add `@State private var showPalette = false` and a `.sheet`:

```swift
.sheet(isPresented: $showPalette) { ActionPaletteView() }
.background(KeyEventBridge { event in
    if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "k" {
        showPalette = true
        return nil
    }
    return event
})
```

`KeyEventBridge` is a small `NSViewRepresentable` that captures local key events. Add it as a stand-alone helper:

```swift
// Sources/VoxFlowApp/Views/Cockpit/KeyEventBridge.swift
import SwiftUI
import AppKit

struct KeyEventBridge: NSViewRepresentable {
    let handler: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> NSView {
        let view = KeyMonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyMonitorView)?.handler = handler
    }

    private final class KeyMonitorView: NSView {
        var handler: ((NSEvent) -> NSEvent?)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handler?(event) ?? event
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/VoxFlowApp/Views/Cockpit/ActionPaletteView.swift Sources/VoxFlowApp/Views/CockpitWindowView.swift
git commit -m "feat: ⌘K opens action palette with all smart actions"
```

---

### Task 18: Side panel — Target and Recent cards

**Files:**
- Replace stub: `Sources/VoxFlowApp/Views/Cockpit/CockpitSidePanelView.swift`

- [ ] **Step 1: Implement side panel**

```swift
import SwiftUI

struct CockpitSidePanelView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            targetSection
            recentSection
            Spacer()
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thinMaterial)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Target")
            HStack {
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.blue)
                if let target = state.cockpitSession?.targetApp {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.localizedName).font(.system(size: 12, weight: .medium))
                        Text("append at cursor").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("focused app").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Recent")
            ForEach(state.recentDictations.prefix(3), id: \.id) { recent in
                VStack(alignment: .leading, spacing: 2) {
                    Text(recent.snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(2)
                    Text(recent.relativeTimestamp)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}
```

This assumes `AppState.recentDictations` exposes items with `snippet` and `relativeTimestamp`. If those don't exist on the current `SessionMemoryStore.Entry`, add small computed helpers there.

- [ ] **Step 2: Build**

Run: `swift build`

Expected: Build succeeds (after adding the helpers if needed).

- [ ] **Step 3: Commit**

```bash
git add Sources/VoxFlowApp/Views/Cockpit/CockpitSidePanelView.swift Sources/VoxFlowApp/Services/SessionMemoryStore.swift
git commit -m "feat: cockpit side panel with target and recent cards"
```

---

## Phase D — Polish

### Task 19: MRU chip ordering + promotion at 3-invoke threshold

**Files:**
- Modify: `Sources/VoxFlowApp/Services/CockpitCoordinator.swift`
- Test: `Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift`

- [ ] **Step 1: Write failing test**

```swift
func test_chip_promoted_to_visible_set_after_three_invocations() async throws {
    let state = AppState()
    let coord = CockpitCoordinator(state: state, sessionService: makeSessionService(), actionService: makeActionService())

    XCTAssertFalse(state.chipMRU.contains(.steel))

    for _ in 0..<3 { try await coord.applyAction(.steel, to: "raw") }

    XCTAssertTrue(state.chipMRU.contains(.steel))
}

func test_chip_order_reflects_usage_after_threshold() async throws {
    let state = AppState()
    let coord = CockpitCoordinator(state: state, sessionService: makeSessionService(), actionService: makeActionService())

    // Default order: memo, mece, items
    for _ in 0..<35 { try await coord.applyAction(.items, to: "raw") }

    XCTAssertEqual(state.chipMRU.first, .items)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "CockpitCoordinatorTests/test_chip"`

Expected: Both fail.

- [ ] **Step 3: Add promotion + reorder logic**

In `CockpitCoordinator.applyAction`, after incrementing the count:

```swift
state.chipInvocationCounts[action, default: 0] += 1
promoteIfNeeded(action)
totalInvocations += 1
if totalInvocations >= 30 { recomputeChipMRU() }
```

Add private state and helpers:

```swift
private var totalInvocations: Int = 0
private static let promotionThreshold = 3
private static let mruActivationThreshold = 30

private func promoteIfNeeded(_ action: SmartActionId) {
    guard !state.chipMRU.contains(action) else { return }
    let count = state.chipInvocationCounts[action] ?? 0
    if count >= Self.promotionThreshold {
        state.chipMRU.append(action)
    }
}

private func recomputeChipMRU() {
    let sorted = state.chipInvocationCounts
        .sorted { $0.value > $1.value }
        .map(\.key)
    let known = Set(sorted)
    // keep current actions if they aren't in counts (e.g., never used but in default set)
    let extras = state.chipMRU.filter { !known.contains($0) }
    state.chipMRU = Array((sorted + extras).prefix(6))
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter "CockpitCoordinatorTests/test_chip"`

Expected: Both pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/CockpitCoordinator.swift Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift
git commit -m "feat: chips promote after 3 invocations and reorder by usage after 30 total"
```

---

### Task 20: Voice prompt strip teaching mode

**Files:**
- Create: `Sources/VoxFlowApp/Views/Cockpit/VoicePromptStripView.swift`
- Modify: `Sources/VoxFlowApp/State/AppState.swift` (add `voicePromptStripDismissed`, `totalCaptureCount`)

- [ ] **Step 1: Add state**

In `AppState.swift`:

```swift
@Published var totalCaptureCount: Int = 0
@Published var voicePromptStripDismissed: Bool = false
```

Persist `totalCaptureCount` and `voicePromptStripDismissed` to UserDefaults via the existing settings persistence pattern.

- [ ] **Step 2: Implement strip view**

```swift
// Sources/VoxFlowApp/Views/Cockpit/VoicePromptStripView.swift
import SwiftUI

struct VoicePromptStripView: View {
    @EnvironmentObject var state: AppState

    var isVisible: Bool {
        !state.voicePromptStripDismissed && state.totalCaptureCount < 10
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11))
                Text("Voice: memo · MECE · items · cancel · undo")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
                Button("Dismiss") { state.voicePromptStripDismissed = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.blue.opacity(0.3), lineWidth: 1))
            .foregroundStyle(.blue)
        }
    }
}
```

Embed inside `CockpitWindowView` above the chip row.

- [ ] **Step 3: Wire capture counter**

In `CockpitCoordinator.applyAction`, increment `state.totalCaptureCount` when a session enters reviewing state. (Or hook in `LongFormSessionService.stop()` via a closure.) Pick the cleaner integration point.

- [ ] **Step 4: Build and visually verify**

Run: `swift build` and launch the app, open cockpit, complete a capture. Confirm strip is visible. Dismiss it. Confirm hidden.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/State/AppState.swift Sources/VoxFlowApp/Views/Cockpit/VoicePromptStripView.swift Sources/VoxFlowApp/Views/CockpitWindowView.swift Sources/VoxFlowApp/Services/CockpitCoordinator.swift
git commit -m "feat: voice prompt strip with teaching-mode auto-dismiss"
```

---

### Task 21: ⌘Z undo, ⌘↩ insert, ⌘C copy, ⌘\ distraction-free

**Files:**
- Modify: `Sources/VoxFlowApp/Views/CockpitWindowView.swift`
- Modify: `Sources/VoxFlowApp/Services/CockpitCoordinator.swift`
- Test: extend `CockpitCoordinatorTests`

- [ ] **Step 1: Write failing undo test**

```swift
func test_undoLastAction_restores_previous_transcript() async throws {
    let state = AppState()
    let sessionService = makeSessionService()
    let coord = CockpitCoordinator(state: state, sessionService: sessionService, actionService: makeActionService())
    sessionService.start()
    sessionService.appendChunk("raw text")
    sessionService.stop()
    let originalTranscript = try XCTUnwrap(sessionService.currentSession?.transcript)

    _ = try await coord.applyAction(.memo, to: originalTranscript)
    XCTAssertNotEqual(sessionService.currentSession?.transcript, originalTranscript)

    coord.undoLastAction()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(sessionService.currentSession?.transcript, originalTranscript)
}
```

- [ ] **Step 2: Run to confirm pass or fail**

Run: `swift test --filter "CockpitCoordinatorTests/test_undoLastAction"`

Expected: Should pass — the `undoLastAction` logic was added in Task 16. If it fails, fix the `actionService.popLast` integration so it restores the right value.

- [ ] **Step 3: Add insert and copy in CockpitCoordinator**

```swift
func insertIntoTarget() async {
    guard let session = sessionService.currentSession else { return }
    let text = session.transcript
    if let target = session.targetApp {
        // delegate to existing TextInsertionCoordinator
        await textInsertionCoordinator.insert(text: text, targetApp: target)
    } else {
        await textInsertionCoordinator.insertIntoFocusedApp(text: text)
    }
    state.cockpitVisible = false
    sessionService.reset()
}

func copyToClipboard() {
    guard let text = sessionService.currentSession?.transcript else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
```

Inject `textInsertionCoordinator` via the initializer.

- [ ] **Step 4: Wire keyboard shortcuts in CockpitWindowView**

Replace KeyEventBridge handler:

```swift
.background(KeyEventBridge { event in
    let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
    let key = event.charactersIgnoringModifiers
    if mods == .command, key == "k" { showPalette = true; return nil }
    if mods == .command, key == "z" { coordinator.undoLastAction(); return nil }
    if mods == .command, key == "\r" { Task { await coordinator.insertIntoTarget() }; return nil }
    if mods == .command, key == "c" { coordinator.copyToClipboard(); return nil }
    if mods == .command, key == "\\" { sidePanelHidden.toggle(); return nil }
    if key == String(UnicodeScalar(27)) { coordinator.close(); return nil }
    return event
})
```

Add `@State private var sidePanelHidden = false` and gate the side panel view on it.

- [ ] **Step 5: Run all cockpit tests**

Run: `swift test --filter "CockpitCoordinatorTests|VoiceCommandRouterTests|LongFormSessionServiceTests|SmartActionServiceTests"`

Expected: All pass.

- [ ] **Step 6: Final build**

Run: `swift build`

Expected: Clean build, no warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/VoxFlowApp/Services/CockpitCoordinator.swift Sources/VoxFlowApp/Views/CockpitWindowView.swift Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift
git commit -m "feat: ⌘Z undo, ⌘↩ insert, ⌘C copy, ⌘\\ distraction-free in cockpit"
```

---

## Final integration

### Task 22: End-to-end dogfood pass

- [ ] **Step 1: Run the full test suite**

Run: `./scripts/test_all.sh`

Expected: All Swift + Python tests pass. New tests should bring the count up.

- [ ] **Step 2: Launch the app**

```bash
open ~/Applications/VoxFlow.app
```

Verify:
- Pressing `⌥⌘V` opens the cockpit window
- `⌘R` starts long-form recording (after first granting mic permission)
- Speaking a few sentences with a 5-second pause produces a paragraph break in the transcript
- `⌘.` or clicking Stop transitions to review state
- Clicking the `memo` chip transforms the transcript via Gemma 4
- `⌘Z` reverts the transformation
- `⌘K` opens the action palette with all six actions
- Side panel shows target and recent
- Closing and reopening recovers the unfinished session

- [ ] **Step 3: Update CLAUDE.md**

Append to the project state section in `<repo>/CLAUDE.md`:

```markdown
## Cockpit (Layer 0)

The cockpit is the document-centric long-form workspace. Open with `⌥⌘V`.

- `CockpitCoordinator` (`Services/CockpitCoordinator.swift`) owns the window state, chip MRU, and action invocation.
- `LongFormSessionService` (`Services/LongFormSessionService.swift`) handles the recording lifecycle, 4s-silence paragraph breaks, 5s auto-save, and session recovery.
- `SmartActionService` actor (`Services/SmartActionService.swift`) calls `/v1/smart_action` and maintains the undo stack.
- `VoiceCommandRouter` (`Services/VoiceCommandRouter.swift`) parses single-keyword voice commands during review state only.
- Three actions ship Layer 0 with chips: `memo`, `mece`, `items`. Three more (`steel`, `pyramid`, `disclaimer`) are accessible via `⌘K` and promote to chips after 3 invocations.
- Session drafts persist to `~/Library/Application Support/VoxFlow/sessions/<uuid>.json`.

Do NOT route quick-utterance dictation through `CockpitCoordinator` — the existing palette path stays.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document cockpit Layer 0 in CLAUDE.md"
```

---

## Self-review checklist (run after every task is complete)

- [ ] All tests pass (`./scripts/test_all.sh`)
- [ ] No new compiler warnings (`swift build` is clean)
- [ ] No `TODO` / `FIXME` / `xxx` left in code
- [ ] `CockpitCoordinator`, `LongFormSessionService`, `SmartActionService`, `VoiceCommandRouter` all have unit tests
- [ ] `⌥⌘V` opens cockpit
- [ ] `⌘R` / `⌘.` / `⌘1` / `⌘2` / `⌘3` / `⌘K` / `⌘Z` / `⌘↩` / `⌘C` / `⌘\` / `esc` all work in cockpit
- [ ] Voice keywords `memo` / `MECE` / `items` / `steel` / `Pyramid` / `disclaimer` / `undo` / `cancel` / `insert` / `copy` all parse correctly
- [ ] Voice commands are IGNORED during recording (`.recording` state)
- [ ] Voice commands FIRE during review (`.reviewing` state)
- [ ] Long-form auto-save writes to `~/Library/Application Support/VoxFlow/sessions/` every 5s
- [ ] App relaunch surfaces the most recent unfinished session
- [ ] Voice prompt strip disappears after 10 captures or when dismissed
- [ ] Chip row reorders by usage after 30 total invocations
- [ ] `steel`, `Pyramid`, `disclaimer` get promoted to chips after 3 invocations each

---

## Out of scope (do not implement in this plan)

These are explicitly Layer 1 or Layer 2 work and must NOT be added during this implementation:

- Personal dictionary
- Notion deep integration
- Voice snippets (named expansions)
- Workflow chains
- Always-on ambient capture / VAD
- Context-aware app behavior inference
- Auto-summarization background task

Hooks (struct definitions, persistence directory creation, etc.) MAY appear preemptively if they're cheap, but no feature behavior beyond Layer 0.
