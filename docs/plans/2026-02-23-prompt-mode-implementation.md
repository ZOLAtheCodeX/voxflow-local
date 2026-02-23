# Prompt Mode — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Prompt Mode as a fourth workflow mode — voice → cleanup → intent detection → structured LLM prompt → insert into focused app.

**Architecture:** New `PromptFramingService` static enum (mirrors `TextCleanupService`) handles intent detection via keyword/NLTagger matching and deterministic template framing. Plugs into the existing `processWithPrivacyGate` wrapper. Python backend gets a symmetric `/v1/prompt/frame` endpoint for non-WhisperKit paths.

**Tech Stack:** Swift 6.2 (NaturalLanguage framework), Python 3.11 (FastAPI), XCTest, pytest

---

## Context

VoxFlow Local is a macOS dictation app with SwiftUI frontend + Python FastAPI backend. It currently has three workflow modes: dictation, translate, meeting. Each follows the same pattern: hotkey capture → STT → process → insert/review. Prompt Mode adds a fourth mode that reformats spoken text into structured LLM prompts.

**Design doc:** `docs/plans/2026-02-23-prompt-mode-design.md`

**Key files to reference while implementing:**
- `Sources/VoxFlowApp/Services/TextCleanupService.swift` — pattern to mirror for PromptFramingService
- `Sources/VoxFlowApp/AppCoordinator.swift:694-740` — `processDictation` to mirror for `processPrompt`
- `Sources/VoxFlowApp/Services/SettingsCoordinator.swift:268-279` — `setMeetingModeEnabled` to mirror
- `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift` — test pattern to mirror

## Summary of Changes

| Area | Files | Action |
|------|-------|--------|
| Domain model | `AppModels.swift`, `AppState.swift` | Add `WorkflowMode.prompt`, `PromptIntent`, `PromptCandidate`, state properties |
| Core service | `PromptFramingService.swift` (new) | Intent detection + template framing |
| Commands | `CommandParser.swift` | Add `.switchToPromptMode` intent |
| Settings | `SettingsCoordinator.swift` | Add `setPromptModeEnabled`, persistence |
| Coordinator | `AppCoordinator.swift` | Add `processPrompt`, feature gate, forwarding |
| Views | `SettingsView.swift` | Add prompt mode toggle |
| Backend | `server.py` | Add `PromptFramingEngine`, `/v1/prompt/frame` endpoint |
| Backend client | `BackendAPIClient.swift` | Add `framePrompt` method |
| Swift tests | 3 new/modified test files | ~20 new tests |
| Python tests | `test_prompt_framing.py` (new) | ~10 new tests |

---

### Task 1: Add domain types and state properties

**Files:**
- Modify: `Sources/VoxFlowApp/Models/AppModels.swift:33-50`
- Modify: `Sources/VoxFlowApp/State/AppState.swift:25-27, 69-80, 108-117`

**Step 1: Add `case prompt` to WorkflowMode**

In `AppModels.swift`, add `case prompt` after `case meeting` (line 36), and add its `displayName` case:

```swift
case .prompt:
    return "Prompt"
```

**Step 2: Add PromptIntent enum**

Add after the `WorkflowMode` enum (after line 50):

```swift
enum PromptIntent: String, CaseIterable, Identifiable, Codable {
    case email
    case code
    case explain
    case creative
    case data
    case general

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email: return "Email"
        case .code: return "Code"
        case .explain: return "Explain"
        case .creative: return "Creative"
        case .data: return "Data"
        case .general: return "General"
        }
    }
}
```

**Step 3: Add PromptCandidate struct**

Add after the `PromptIntent` enum:

```swift
struct PromptCandidate {
    let sessionID: String
    let rawText: String
    let cleanedText: String
    let framedPrompt: String
    let detectedIntent: PromptIntent
}
```

**Step 4: Add AppState properties**

In `AppState.swift`, add after `meetingModeEnabled` (line 27):

```swift
@Published var promptModeEnabled = false
@Published var promptCandidate: PromptCandidate?
```

**Step 5: Update displayText**

In `AppState.swift`, update the `displayText` computed property (line 69) to add a prompt case before the `guard let transcriptCandidate`:

```swift
if workflowMode == .prompt {
    return promptCandidate?.framedPrompt ?? ""
}
```

**Step 6: Update availableWorkflowModes**

In `AppState.swift`, add to `availableWorkflowModes` (after line 115):

```swift
if promptModeEnabled {
    modes.append(.prompt)
}
```

**Step 7: Update resetForNewCapture**

Find `resetForNewCapture()` and add `promptCandidate = nil` alongside the existing candidate resets.

**Step 8: Build to verify**

Run: `swift build`
Expected: Compile errors in `AppCoordinator.swift` switch statements (non-exhaustive) — these are expected and fixed in later tasks.

**Step 9: Commit**

```bash
git add Sources/VoxFlowApp/Models/AppModels.swift Sources/VoxFlowApp/State/AppState.swift
git commit -m "feat: add PromptIntent, PromptCandidate, WorkflowMode.prompt domain types"
```

---

### Task 2: Write PromptFramingService — intent detection with TDD

**Files:**
- Create: `Sources/VoxFlowApp/Services/PromptFramingService.swift`
- Create: `Tests/VoxFlowAppTests/PromptFramingServiceTests.swift`

**Step 1: Write failing intent detection tests**

Create `Tests/VoxFlowAppTests/PromptFramingServiceTests.swift`:

```swift
import XCTest
@testable import VoxFlowApp

final class PromptFramingServiceTests: XCTestCase {

    // MARK: - Intent detection — canonical phrases

    func testEmailIntent() {
        XCTAssertEqual(PromptFramingService.detectIntent("write an email to my manager declining the meeting"), .email)
    }

    func testEmailIntentDraft() {
        XCTAssertEqual(PromptFramingService.detectIntent("draft a reply to the client"), .email)
    }

    func testCodeIntent() {
        XCTAssertEqual(PromptFramingService.detectIntent("write a function that sorts an array"), .code)
    }

    func testCodeIntentDebug() {
        XCTAssertEqual(PromptFramingService.detectIntent("debug this API endpoint"), .code)
    }

    func testExplainIntent() {
        XCTAssertEqual(PromptFramingService.detectIntent("explain how dependency injection works"), .explain)
    }

    func testExplainIntentWhatIs() {
        XCTAssertEqual(PromptFramingService.detectIntent("what is a monad in functional programming"), .explain)
    }

    func testCreativeIntent() {
        XCTAssertEqual(PromptFramingService.detectIntent("write a blog post about remote work productivity"), .creative)
    }

    func testCreativeIntentTweet() {
        XCTAssertEqual(PromptFramingService.detectIntent("draft a tweet announcing our product launch"), .creative)
    }

    func testDataIntent() {
        XCTAssertEqual(PromptFramingService.detectIntent("summarize the quarterly revenue numbers"), .data)
    }

    func testDataIntentCompare() {
        XCTAssertEqual(PromptFramingService.detectIntent("compare the differences between React and Vue"), .data)
    }

    func testGeneralFallback() {
        XCTAssertEqual(PromptFramingService.detectIntent("help me think through this problem"), .general)
    }

    func testEmptyStringFallback() {
        XCTAssertEqual(PromptFramingService.detectIntent(""), .general)
    }

    // MARK: - Intent detection — priority / disambiguation

    func testCodeBeatsCreativeForReview() {
        // "review" is a code keyword; should not fall to creative
        XCTAssertEqual(PromptFramingService.detectIntent("review this pull request"), .code)
    }

    func testCreativePostNotDataPost() {
        // "post" is creative; should not be confused with data
        XCTAssertEqual(PromptFramingService.detectIntent("write a post about machine learning trends"), .creative)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter PromptFramingServiceTests 2>&1 | tail -5`
Expected: Compile error — `PromptFramingService` not defined.

**Step 3: Implement detectIntent**

Create `Sources/VoxFlowApp/Services/PromptFramingService.swift`:

```swift
import Foundation
import NaturalLanguage

enum PromptFramingService {

    private static let intentKeywords: [(intent: PromptIntent, phrases: [String])] = [
        (.email, ["email", "draft", "reply", "message to", "follow up", "follow-up"]),
        (.code, ["function", "code", "debug", "refactor", "review", "implement", "api", "endpoint", "algorithm", "class", "method"]),
        (.explain, ["explain", "what is", "how does", "teach", "break down", "why does", "how do"]),
        (.creative, ["blog", "tweet", "post", "story", "tagline", "copy", "headline", "slogan"]),
        (.data, ["summarize", "compare", "extract", "analyze", "list the", "differences between", "table of"]),
    ]

    static func detectIntent(_ text: String) -> PromptIntent {
        let lowered = text.lowercased()
        guard !lowered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .general
        }

        var scores: [PromptIntent: Int] = [:]
        for (intent, phrases) in intentKeywords {
            let count = phrases.filter { lowered.contains($0) }.count
            if count > 0 {
                scores[intent] = count
            }
        }

        guard !scores.isEmpty else {
            return .general
        }

        // Priority order for tie-breaking: email > code > explain > creative > data
        let priority: [PromptIntent] = [.email, .code, .explain, .creative, .data]
        let maxScore = scores.values.max()!
        for intent in priority {
            if scores[intent] == maxScore {
                return intent
            }
        }

        return .general
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter PromptFramingServiceTests 2>&1 | tail -5`
Expected: All intent detection tests pass. Some may need keyword tuning — adjust the `intentKeywords` table until all 14 tests pass.

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/PromptFramingService.swift \
      Tests/VoxFlowAppTests/PromptFramingServiceTests.swift
git commit -m "feat: add PromptFramingService.detectIntent with keyword matching

TDD: 14 intent detection tests passing"
```

---

### Task 3: Write PromptFramingService — framing templates with TDD

**Files:**
- Modify: `Sources/VoxFlowApp/Services/PromptFramingService.swift`
- Modify: `Tests/VoxFlowAppTests/PromptFramingServiceTests.swift`

**Step 1: Write failing framing tests**

Add to `PromptFramingServiceTests.swift`:

```swift
    // MARK: - Framing templates

    func testEmailFrameContainsSections() {
        let result = PromptFramingService.frame("tell the client we need to reschedule", intent: .email)
        XCTAssert(result.contains("Task:"), "Should contain Task section")
        XCTAssert(result.contains("Constraints:"), "Should contain Constraints section")
        XCTAssert(result.contains("Output format:"), "Should contain Output format section")
        XCTAssert(result.contains("tell the client we need to reschedule"), "Should contain original text")
    }

    func testCodeFrameContainsSections() {
        let result = PromptFramingService.frame("write a binary search function", intent: .code)
        XCTAssert(result.contains("Task:"), "Should contain Task section")
        XCTAssert(result.contains("Constraints:"), "Should contain Constraints section")
        XCTAssert(result.contains("write a binary search function"), "Should contain original text")
    }

    func testExplainFrameContainsTopic() {
        let result = PromptFramingService.frame("how dependency injection works", intent: .explain)
        XCTAssert(result.contains("Topic:"), "Should contain Topic section")
        XCTAssert(result.contains("how dependency injection works"), "Should contain original text")
    }

    func testCreativeFrameContainsSections() {
        let result = PromptFramingService.frame("a blog post about remote work", intent: .creative)
        XCTAssert(result.contains("Task:"), "Should contain Task section")
        XCTAssert(result.contains("a blog post about remote work"), "Should contain original text")
    }

    func testDataFrameContainsSections() {
        let result = PromptFramingService.frame("quarterly revenue trends", intent: .data)
        XCTAssert(result.contains("Task:"), "Should contain Task section")
        XCTAssert(result.contains("quarterly revenue trends"), "Should contain original text")
    }

    func testGeneralFrameIsMinimal() {
        let result = PromptFramingService.frame("help me think through this", intent: .general)
        XCTAssert(result.contains("Task:"), "Should contain Task section")
        XCTAssert(result.contains("help me think through this"), "Should contain original text")
        // General frame should NOT have Constraints section
        XCTAssertFalse(result.contains("Constraints:"), "General frame should be minimal")
    }
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter PromptFramingServiceTests 2>&1 | tail -5`
Expected: FAIL — `frame` method not defined.

**Step 3: Implement frame method**

Add to `PromptFramingService` in `PromptFramingService.swift`:

```swift
    static func frame(_ text: String, intent: PromptIntent) -> String {
        switch intent {
        case .email:
            return """
            Task: Draft an email based on the following instructions.

            Instructions: \(text)

            Constraints:
            - Professional tone unless otherwise specified
            - Concise — aim for 3-5 sentences
            - Include subject line suggestion

            Output format: Complete email with Subject and Body.
            """
        case .code:
            return """
            Task: \(text)

            Constraints:
            - Write clean, production-ready code
            - Include brief comments for non-obvious logic
            - Handle edge cases

            Output format: Code with explanation of approach.
            """
        case .explain:
            return """
            Task: Explain the following clearly and concisely.

            Topic: \(text)

            Constraints:
            - Assume intermediate knowledge level
            - Use concrete examples where helpful
            - Keep it under 200 words unless complexity requires more

            Output format: Clear explanation with examples.
            """
        case .creative:
            return """
            Task: \(text)

            Constraints:
            - Engaging and original
            - Match the tone implied in the instructions
            - Provide 2-3 variations if the output is short-form

            Output format: Creative content as described.
            """
        case .data:
            return """
            Task: \(text)

            Constraints:
            - Be precise and factual
            - Use structured format (bullets, tables) where appropriate
            - Call out assumptions

            Output format: Structured analysis.
            """
        case .general:
            return """
            Task: \(text)

            Please provide a thorough, well-structured response.
            """
        }
    }
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter PromptFramingServiceTests 2>&1 | tail -5`
Expected: All 20 tests pass.

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/PromptFramingService.swift \
      Tests/VoxFlowAppTests/PromptFramingServiceTests.swift
git commit -m "feat: add PromptFramingService.frame with 6 intent templates

TDD: 20 tests passing (14 intent detection + 6 framing)"
```

---

### Task 4: Add command parser support and settings persistence

**Files:**
- Modify: `Sources/VoxFlowApp/Services/CommandParser.swift:3-9, 29-44`
- Modify: `Sources/VoxFlowApp/Services/SettingsCoordinator.swift:4-21, 30-38, 80-160, 255-279`
- Modify: `Tests/VoxFlowAppTests/CommandParserTests.swift`

**Step 1: Write failing command parser test**

Add to `CommandParserTests.swift` after the meeting mode tests:

```swift
    func testPromptMode() {
        XCTAssertEqual(CommandParser.parse(from: "prompt mode"), .switchToPromptMode)
    }
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter CommandParserTests/testPromptMode 2>&1 | tail -5`
Expected: Compile error — `switchToPromptMode` not defined.

**Step 3: Add CommandParser support**

In `CommandParser.swift`:

Add `case switchToPromptMode` to the `CommandIntent` enum (after line 8, alongside the other switch cases).

Add the voice command pattern to `modePatterns` (around line 34):

```swift
(["prompt", "mode"], .switchToPromptMode),
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter CommandParserTests/testPromptMode 2>&1 | tail -5`
Expected: PASS.

**Step 5: Add SettingsCoordinator persistence**

In `SettingsCoordinator.swift`:

Add to the protocol (line 14, after `setMeetingModeEnabled`):

```swift
func setPromptModeEnabled(_ isEnabled: Bool)
```

Add the UserDefaults key (around line 33, after `meetingModeEnabledKey`):

```swift
private let promptModeEnabledKey = "voxflow.prompt.modeEnabled"
```

Add persistence in `configureInitialState()` — after the `meetingModeEnabled` line (around line 117):

```swift
state.promptModeEnabled = defaults.bool(forKey: promptModeEnabledKey)
```

Add the implementation method — directly after `setMeetingModeEnabled` (after line 279):

```swift
func setPromptModeEnabled(_ isEnabled: Bool) {
    state.promptModeEnabled = isEnabled
    UserDefaults.standard.set(isEnabled, forKey: promptModeEnabledKey)

    if !isEnabled, state.workflowMode == .prompt {
        state.workflowMode = .dictation
    }

    state.statusLine = isEnabled
        ? "Prompt experimental mode enabled"
        : "Prompt experimental mode disabled"
}
```

**Step 6: Build to verify**

Run: `swift build 2>&1 | grep error:`
Expected: Errors in `AppCoordinator.swift` for non-exhaustive switches and missing `setPromptModeEnabled` forwarding — fixed in Task 5.

**Step 7: Commit**

```bash
git add Sources/VoxFlowApp/Services/CommandParser.swift \
      Sources/VoxFlowApp/Services/SettingsCoordinator.swift \
      Tests/VoxFlowAppTests/CommandParserTests.swift
git commit -m "feat: add prompt mode command parsing and settings persistence

- CommandIntent.switchToPromptMode + voice pattern
- SettingsCoordinator.setPromptModeEnabled with UserDefaults
- 1 new command parser test"
```

---

### Task 5: Wire AppCoordinator — processPrompt, feature gate, forwarding

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:362-369, 502-527, 530-546, 868-884`

**Step 1: Add settings forwarding**

After `setMeetingModeEnabled` forwarding (line 535):

```swift
func setPromptModeEnabled(_ isEnabled: Bool) { settings.setPromptModeEnabled(isEnabled) }
```

**Step 2: Add feature gate in selectWorkflowMode**

After the meeting mode gate (lines 508-511):

```swift
if mode == .prompt && !state.promptModeEnabled {
    state.statusLine = "Enable Experimental Prompt Mode in Settings"
    return
}
```

**Step 3: Add prompt case to status line switch**

In `selectWorkflowMode`, after the meeting status line case (line 526):

```swift
case .prompt:
    state.statusLine = "Prompt mode active"
```

**Step 4: Add promptCandidate reset in selectWorkflowMode**

After `state.meetingCandidate = nil` (line 516):

```swift
state.promptCandidate = nil
```

**Step 5: Add processPrompt method**

Add after `processDictation` (around line 790). This method mirrors `processDictation` but always uses `.polish` cleanup and adds the framing step:

```swift
private func processPrompt(sessionID: String, rawText: String) async throws {
    try await processWithPrivacyGate(
        sessionID: sessionID, operation: .cleanup, inputText: rawText
    ) { [weak self] providerMode, consentToken, allowRaw in
        guard let self else { return }
        let profile = self.resolveEffectiveProfile()
        let effectiveTone = profile?.tone ?? self.state.toneStyle
        let effectiveInsert = profile?.insertBehavior ?? self.state.insertBehavior

        // Always polish for prompt framing
        let cleanedText: String
        if providerMode == .localOnly && self.state.sttBackend == .whisperKit {
            cleanedText = TextCleanupService.cleanup(rawText, mode: .polish, tone: effectiveTone)
        } else {
            let cleanupResponse = try await BackendAPIClient.cleanup(
                sessionID: sessionID, mode: .polish, inputText: rawText,
                toneStyle: effectiveTone, providerMode: providerMode,
                consentToken: consentToken, allowRaw: allowRaw
            )
            cleanedText = cleanupResponse.outputText
        }

        // Detect intent and frame
        let intent = PromptFramingService.detectIntent(cleanedText)
        let framedPrompt = PromptFramingService.frame(cleanedText, intent: intent)

        let candidate = PromptCandidate(
            sessionID: sessionID,
            rawText: rawText,
            cleanedText: cleanedText,
            framedPrompt: framedPrompt,
            detectedIntent: intent
        )
        self.state.promptCandidate = candidate

        // Route by insert behavior
        if let autoMode = effectiveInsert.cleanupMode, providerMode == .localOnly {
            let appLabel = self.state.focusTarget.appName ?? "app"
            if self.textInsertion.insertText(framedPrompt, statusSuffix: "Prompt inserted (\(intent.displayName) — \(appLabel))", targetApp: self.capturedTargetApp) {
                self.state.sessionState = .idle
            } else {
                self.state.sessionState = .review
            }
        } else {
            self.state.sessionState = .review
        }
    }
}
```

**Step 6: Add switch case in finishCaptureAndTranscribe**

In the `switch state.workflowMode` block (line 362), add before `case .dictation`:

```swift
case .prompt:
    try await processPrompt(sessionID: sessionID, rawText: rawText)
```

**Step 7: Add command lane handler**

In `executeCommandLane` switch (around line 874), add after the meeting case:

```swift
case .switchToPromptMode:
    selectWorkflowMode(.prompt)
```

**Step 8: Build and run tests**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: Build succeeds. All tests pass (183 existing + 1 command parser + ~20 framing = ~204).

**Step 9: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift
git commit -m "feat: wire processPrompt pipeline into AppCoordinator

- Feature gate, settings forwarding, candidate reset
- processPrompt: cleanup → detectIntent → frame → insert/review
- Command lane handler for switchToPromptMode"
```

---

### Task 6: Add SettingsView toggle

**Files:**
- Modify: `Sources/VoxFlowApp/Views/SettingsView.swift:266-272`

**Step 1: Add prompt mode toggle**

In the "Workflow" section of `SettingsView.swift`, after the "Enable Experimental Meeting Mode" toggle (line 272):

```swift
Toggle(
    "Enable Experimental Prompt Mode",
    isOn: Binding(
        get: { state.promptModeEnabled },
        set: { coordinator.setPromptModeEnabled($0) }
    )
)
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Clean build.

**Step 3: Commit**

```bash
git add Sources/VoxFlowApp/Views/SettingsView.swift
git commit -m "feat: add Prompt Mode toggle to SettingsView"
```

---

### Task 7: Add Python PromptFramingEngine and endpoint

**Files:**
- Modify: `backend/app/server.py` (add class, request/response models, endpoint, ProviderRouter integration)

**Step 1: Add request/response models**

Add after the existing `MeetingSummaryResponse` model (find it with `grep -n 'class MeetingSummaryResponse' backend/app/server.py`):

```python
class PromptFrameRequest(BaseModel):
    session_id: str
    text: str
    consent_token: str | None = None


class PromptFrameResponse(BaseModel):
    framed_prompt: str
    detected_intent: str
```

**Step 2: Add PromptFramingEngine class**

Add after the `TranslateEngine` class (find it with `grep -n 'class TranslateEngine' backend/app/server.py`):

```python
class PromptFramingEngine:
    _INTENT_KEYWORDS: list[tuple[str, list[str]]] = [
        ("email", ["email", "draft", "reply", "message to", "follow up", "follow-up"]),
        ("code", ["function", "code", "debug", "refactor", "review", "implement", "api", "endpoint", "algorithm", "class", "method"]),
        ("explain", ["explain", "what is", "how does", "teach", "break down", "why does", "how do"]),
        ("creative", ["blog", "tweet", "post", "story", "tagline", "copy", "headline", "slogan"]),
        ("data", ["summarize", "compare", "extract", "analyze", "list the", "differences between", "table of"]),
    ]

    _PRIORITY = ["email", "code", "explain", "creative", "data"]

    _TEMPLATES: dict[str, str] = {
        "email": (
            "Task: Draft an email based on the following instructions.\n\n"
            "Instructions: {text}\n\n"
            "Constraints:\n"
            "- Professional tone unless otherwise specified\n"
            "- Concise — aim for 3-5 sentences\n"
            "- Include subject line suggestion\n\n"
            "Output format: Complete email with Subject and Body."
        ),
        "code": (
            "Task: {text}\n\n"
            "Constraints:\n"
            "- Write clean, production-ready code\n"
            "- Include brief comments for non-obvious logic\n"
            "- Handle edge cases\n\n"
            "Output format: Code with explanation of approach."
        ),
        "explain": (
            "Task: Explain the following clearly and concisely.\n\n"
            "Topic: {text}\n\n"
            "Constraints:\n"
            "- Assume intermediate knowledge level\n"
            "- Use concrete examples where helpful\n"
            "- Keep it under 200 words unless complexity requires more\n\n"
            "Output format: Clear explanation with examples."
        ),
        "creative": (
            "Task: {text}\n\n"
            "Constraints:\n"
            "- Engaging and original\n"
            "- Match the tone implied in the instructions\n"
            "- Provide 2-3 variations if the output is short-form\n\n"
            "Output format: Creative content as described."
        ),
        "data": (
            "Task: {text}\n\n"
            "Constraints:\n"
            "- Be precise and factual\n"
            "- Use structured format (bullets, tables) where appropriate\n"
            "- Call out assumptions\n\n"
            "Output format: Structured analysis."
        ),
        "general": (
            "Task: {text}\n\n"
            "Please provide a thorough, well-structured response."
        ),
    }

    def detect_intent(self, text: str) -> str:
        lowered = text.lower()
        if not lowered.strip():
            return "general"

        scores: dict[str, int] = {}
        for intent, phrases in self._INTENT_KEYWORDS:
            count = sum(1 for p in phrases if p in lowered)
            if count > 0:
                scores[intent] = count

        if not scores:
            return "general"

        max_score = max(scores.values())
        for intent in self._PRIORITY:
            if scores.get(intent) == max_score:
                return intent

        return "general"

    def frame(self, text: str, intent: str) -> str:
        template = self._TEMPLATES.get(intent, self._TEMPLATES["general"])
        return template.format(text=text)
```

**Step 3: Add PromptFramingEngine to global state and ProviderRouter**

In the global initialization block (near `whisper_engine = WhisperEngine()`), add:

```python
prompt_framing_engine = PromptFramingEngine()
```

Add `prompt_framing_engine` parameter to `ProviderRouter.__init__`:

```python
prompt_framing_engine: PromptFramingEngine,
```

And store it: `self._prompt_framing_engine = prompt_framing_engine`

Add method to `ProviderRouter`:

```python
def frame_prompt(self, session_id: str, text: str, consent_token: str | None) -> tuple[str, str]:
    intent = self._prompt_framing_engine.detect_intent(text)
    framed = self._prompt_framing_engine.frame(text, intent)
    return framed, intent
```

Update the `ProviderRouter(...)` constructor call to include `prompt_framing_engine=prompt_framing_engine`.

**Step 4: Add the endpoint**

Add after the `/v1/meeting_summarize` endpoint:

```python
@app.post("/v1/prompt/frame", response_model=PromptFrameResponse)
def prompt_frame(payload: PromptFrameRequest) -> PromptFrameResponse:
    framed, intent = provider_router.frame_prompt(
        session_id=payload.session_id,
        text=payload.text,
        consent_token=payload.consent_token,
    )
    audit_logger.log(
        operation="prompt_frame",
        provider_mode="local_only",
        session_id=payload.session_id,
        payload_length=len(payload.text),
        redacted=False,
    )
    return PromptFrameResponse(framed_prompt=framed, detected_intent=intent)
```

**Step 5: Commit**

```bash
git add backend/app/server.py
git commit -m "feat: add PromptFramingEngine and /v1/prompt/frame endpoint

Pure keyword matching + string templates, no ML.
Symmetric implementation with Swift PromptFramingService."
```

---

### Task 8: Add BackendAPIClient.framePrompt (Swift)

**Files:**
- Modify: `Sources/VoxFlowApp/Services/BackendAPIClient.swift`

**Step 1: Add response type and method**

Add after the existing `CleanupResponse` (or similar response struct). Find the pattern with `grep -n 'struct.*Response.*Codable' Sources/VoxFlowApp/Services/BackendAPIClient.swift`.

Add response struct:

```swift
struct PromptFrameResponse: Codable {
    let framedPrompt: String
    let detectedIntent: String

    enum CodingKeys: String, CodingKey {
        case framedPrompt = "framed_prompt"
        case detectedIntent = "detected_intent"
    }
}
```

Add the method after `cleanup()`:

```swift
static func framePrompt(
    sessionID: String,
    text: String,
    consentToken: String? = nil
) async throws -> PromptFrameResponse {
    struct Payload: Codable {
        let session_id: String
        let text: String
        let consent_token: String?
    }

    let payload = Payload(
        session_id: sessionID,
        text: text,
        consent_token: consentToken
    )

    var request = URLRequest(url: baseURL.appendingPathComponent("v1/prompt/frame"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)

    let (data, _) = try await session.data(for: request)
    return try decoder.decode(PromptFrameResponse.self, from: data)
}
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Clean build.

**Step 3: Commit**

```bash
git add Sources/VoxFlowApp/Services/BackendAPIClient.swift
git commit -m "feat: add BackendAPIClient.framePrompt for backend path"
```

---

### Task 9: Add Python tests for PromptFramingEngine

**Files:**
- Create: `backend/tests/test_prompt_framing.py`

**Step 1: Write tests**

Create `backend/tests/test_prompt_framing.py`:

```python
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

from server import PromptFramingEngine


class TestPromptFramingDetectIntent:
    def setup_method(self):
        self.engine = PromptFramingEngine()

    def test_email_intent(self):
        assert self.engine.detect_intent("write an email to my manager") == "email"

    def test_code_intent(self):
        assert self.engine.detect_intent("write a function that sorts an array") == "code"

    def test_explain_intent(self):
        assert self.engine.detect_intent("explain how dependency injection works") == "explain"

    def test_creative_intent(self):
        assert self.engine.detect_intent("write a blog post about remote work") == "creative"

    def test_data_intent(self):
        assert self.engine.detect_intent("summarize the quarterly revenue") == "data"

    def test_general_fallback(self):
        assert self.engine.detect_intent("help me think through this") == "general"

    def test_empty_string(self):
        assert self.engine.detect_intent("") == "general"


class TestPromptFramingFrame:
    def setup_method(self):
        self.engine = PromptFramingEngine()

    def test_email_frame_contains_sections(self):
        result = self.engine.frame("reschedule the meeting", "email")
        assert "Task:" in result
        assert "Constraints:" in result
        assert "reschedule the meeting" in result

    def test_code_frame_contains_text(self):
        result = self.engine.frame("binary search function", "code")
        assert "binary search function" in result
        assert "Constraints:" in result

    def test_general_frame_is_minimal(self):
        result = self.engine.frame("help me think", "general")
        assert "Task:" in result
        assert "help me think" in result
        assert "Constraints:" not in result
```

**Step 2: Run tests**

Run: `./.venv/bin/python -m pytest backend/tests/test_prompt_framing.py -v`
Expected: All 10 tests pass.

**Step 3: Commit**

```bash
git add backend/tests/test_prompt_framing.py
git commit -m "test: add Python tests for PromptFramingEngine

10 tests: 7 intent detection + 3 framing template tests"
```

---

### Task 10: Run full test suite, update docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `progress.txt`

**Step 1: Run full Swift test suite**

Run: `swift test 2>&1 | tail -5`
Expected: ~204 tests, 0 failures.

**Step 2: Run full Python test suite**

Run: `./.venv/bin/python -m pytest backend/tests -v 2>&1 | tail -10`
Expected: ~67 tests, 0 failures.

**Step 3: Grep check**

Run: `grep -ri "PromptFramingService\|PromptIntent\|promptCandidate\|promptModeEnabled" Sources/ Tests/ backend/ scripts/ | wc -l`
Expected: 30+ matches (all the new code).

**Step 4: Update CLAUDE.md**

- Add `PromptFramingService` to the Key Patterns → Swift section:
  `- **PromptFramingService**: Static 2-step pipeline (detectIntent → frame) using keyword/NLTagger matching + string templates. Six intent categories (email, code, explain, creative, data, general). Used in-process on WhisperKit path, backend fallback via /v1/prompt/frame.`
- Update test count.
- Add `case prompt` to the WorkflowMode description in the Architecture section if it lists modes.

**Step 5: Update progress.txt**

- Add Prompt Mode to Completed section with task/commit summary.
- Update test counts.

**Step 6: Commit**

```bash
git add CLAUDE.md progress.txt
git commit -m "docs: update CLAUDE.md and progress.txt for Prompt Mode"
```

---

## Verification

After all tasks complete:

1. **Swift build**: `swift build` — must compile cleanly
2. **Swift tests**: `swift test` — all tests pass (~204)
3. **Python tests**: `./.venv/bin/python -m pytest backend/tests -v` — all tests pass (~67)
4. **Manual smoke test**: Enable Prompt Mode in Settings, switch to it, dictate "write an email declining the meeting politely", verify the review screen shows a framed prompt with Task/Constraints/Output format sections
5. **Command lane test**: Use command lane hotkey, say "prompt mode", verify mode switches
