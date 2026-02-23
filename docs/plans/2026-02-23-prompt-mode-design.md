# Prompt Mode — Design Document

> **Date:** 2026-02-23
> **Status:** Approved
> **Approach:** A — PromptFramingService (pure Swift static enum + Python backend fallback)

## Problem

VoxFlow captures speech and inserts cleaned text. But when the user wants to dictate an instruction for an LLM (Claude, ChatGPT, etc.), the raw cleaned text is a poor prompt. It lacks structure, constraints, and output format expectations. The user has to manually rewrite their spoken thought into a well-framed prompt.

## Solution

Add **Prompt Mode** as a fourth workflow mode. The user speaks naturally, VoxFlow transcribes → cleans (polish) → detects intent via keyword/NLTagger matching → wraps in a structured LLM prompt template → inserts into the focused app.

No ML models for framing. Deterministic keyword matching + string templates. Same insert behavior, privacy gate, and per-app profile system as dictation.

## Domain Model

### New/modified types in `AppModels.swift`

```swift
// WorkflowMode gains a fourth case
enum WorkflowMode: String, CaseIterable, Identifiable, Hashable, Codable {
    case dictation
    case translateEnToDe
    case meeting
    case prompt              // feature-gated
}

// New enum
enum PromptIntent: String, CaseIterable, Identifiable, Codable {
    case email       // "write an email", "draft a message", "reply to"
    case code        // "write a function", "review this code", "debug", "refactor"
    case explain     // "explain", "what is", "how does", "teach me"
    case creative    // "write a blog post", "draft a tweet", "tagline", "story"
    case data        // "summarize", "compare", "extract", "analyze"
    case general     // fallback — no specific intent detected
}

// New candidate struct
struct PromptCandidate {
    let sessionID: String
    let rawText: String          // original transcription
    let cleanedText: String      // after TextCleanupService.cleanup(.polish)
    let framedPrompt: String     // final structured prompt
    let detectedIntent: PromptIntent
}
```

### New state in `AppState.swift`

```swift
@Published var promptModeEnabled = false
@Published var promptCandidate: PromptCandidate?
```

`availableWorkflowModes` adds `.prompt` when `promptModeEnabled == true`.

`displayText` gains a case returning `promptCandidate?.framedPrompt`.

## PromptFramingService

**New file:** `Sources/VoxFlowApp/Services/PromptFramingService.swift`

Static enum mirroring `TextCleanupService`. Two public methods:

```swift
enum PromptFramingService {
    static func detectIntent(_ text: String) -> PromptIntent
    static func frame(_ text: String, intent: PromptIntent) -> String
}
```

### Intent Detection

Cascading keyword/phrase matching on lowercased text. NLTagger used to disambiguate "draft" (noun context → skip, verb context → email). Returns the intent with the most keyword hits. Ties broken by priority order: email > code > explain > creative > data > general.

| Intent | Trigger phrases |
|--------|----------------|
| `email` | "email", "draft", "reply", "message to", "follow up" |
| `code` | "function", "code", "debug", "refactor", "review", "implement", "API", "endpoint" |
| `explain` | "explain", "what is", "how does", "teach", "break down", "why does" |
| `creative` | "blog", "tweet", "post", "story", "tagline", "copy", "headline" |
| `data` | "summarize", "compare", "extract", "analyze", "list the", "differences between" |
| `general` | Fallback when no intent scores above threshold |

### Framing Templates

Each intent produces a structured prompt. Templates are static string-interpolation methods.

**Email:**
```
Task: Draft an email based on the following instructions.

Instructions: <cleaned text>

Constraints:
- Professional tone unless otherwise specified
- Concise — aim for 3-5 sentences
- Include subject line suggestion

Output format: Complete email with Subject and Body.
```

**Code:**
```
Task: <cleaned text>

Constraints:
- Write clean, production-ready code
- Include brief comments for non-obvious logic
- Handle edge cases

Output format: Code with explanation of approach.
```

**Explain:**
```
Task: Explain the following clearly and concisely.

Topic: <cleaned text>

Constraints:
- Assume intermediate knowledge level
- Use concrete examples where helpful
- Keep it under 200 words unless complexity requires more

Output format: Clear explanation with examples.
```

**Creative:**
```
Task: <cleaned text>

Constraints:
- Engaging and original
- Match the tone implied in the instructions
- Provide 2-3 variations if the output is short-form

Output format: Creative content as described.
```

**Data:**
```
Task: <cleaned text>

Constraints:
- Be precise and factual
- Use structured format (bullets, tables) where appropriate
- Call out assumptions

Output format: Structured analysis.
```

**General (fallback):**
```
Task: <cleaned text>

Please provide a thorough, well-structured response.
```

## Pipeline Flow

Mirrors `processDictation` with one added step (framing) between cleanup and insertion.

```
Hotkey release
  └─ finishCaptureAndTranscribe(commandLane: false)
       └─ switch state.workflowMode:
           case .prompt → processPrompt(sessionID, rawText)

processPrompt(sessionID, rawText)
  └─ processWithPrivacyGate(...)
       └─ process closure:
           1. resolveEffectiveProfile()
           2. cleanedText = TextCleanupService.cleanup(rawText, .polish, effectiveTone)
           3. intent = PromptFramingService.detectIntent(cleanedText)
           4. framedPrompt = PromptFramingService.frame(cleanedText, intent: intent)
           5. state.promptCandidate = PromptCandidate(...)
           6. Route by InsertBehavior:
              - autoInsert → textInsertion.insertText(framedPrompt, ...)
              - alwaysReview → sessionState = .review
```

**Local path (WhisperKit STT):** Steps 2-4 run entirely in-process. No backend needed.

**Backend path (non-WhisperKit or private API):** Cleanup goes through `BackendAPIClient.cleanup()`, framing through new `BackendAPIClient.framePrompt()`.

### What doesn't change

- `startCapture` / `finishCaptureAndTranscribe` — new switch case only
- `processWithPrivacyGate` — reused as-is
- `TextInsertionCoordinator` — reused as-is
- `InsertBehavior` logic — reused as-is
- Audio capture, STT, hotkeys — all unchanged

## UI, Commands, and Settings

### Settings

- `SettingsCoordinator`: new `promptModeEnabledKey`, `setPromptModeEnabled(_:)` method
- `SettingsCoordinating` protocol: add method
- `AppCoordinator`: forwarding method

### SettingsView

One toggle in the "Workflow" section:

```swift
Toggle(
    "Enable Experimental Prompt Mode",
    isOn: Binding(
        get: { state.promptModeEnabled },
        set: { coordinator.setPromptModeEnabled($0) }
    )
)
```

No template picker, no intent override. YAGNI.

### Command Lane

```swift
// CommandIntent
case switchToPromptMode

// CommandParser modePatterns
(["prompt", "mode"], .switchToPromptMode)

// AppCoordinator.executeCommandLane
case .switchToPromptMode:
    selectWorkflowMode(.prompt)
```

### WorkflowMode display

```swift
case .prompt:
    return "Prompt"
```

### Not in V1

- No prompt template picker UI
- No intent override in settings
- No per-app prompt style profiles
- No prompt history separate from session memory

## Python Backend

### New endpoint: `POST /v1/prompt/frame`

Only invoked on the backend path (non-WhisperKit STT or private API mode).

```python
class PromptFrameRequest(BaseModel):
    session_id: str
    text: str
    consent_token: str | None = None

class PromptFrameResponse(BaseModel):
    framed_prompt: str
    detected_intent: str
```

### PromptFramingEngine

Pure Python, no ML. Same keyword matching + template logic as Swift `PromptFramingService`.

```python
class PromptFramingEngine:
    def detect_intent(self, text: str) -> str: ...
    def frame(self, text: str, intent: str) -> str: ...
```

### ProviderRouter integration

```python
def frame_prompt(self, session_id: str, text: str, consent_token: str | None) -> tuple[str, str]:
    intent = self._prompt_framing_engine.detect_intent(text)
    framed = self._prompt_framing_engine.frame(text, intent)
    return framed, intent
```

### BackendAPIClient (Swift)

```swift
static func framePrompt(
    sessionID: String,
    text: String,
    consentToken: String?
) async throws -> (framedPrompt: String, detectedIntent: String)
```

### Not in backend V1

- No FLAN-T5 usage for framing
- No ML model loading
- No new consent/privacy changes

## Testing Strategy

### Swift (~20 tests)

**PromptFramingServiceTests.swift:**
- Intent detection: one test per intent with canonical phrases (~6)
- Edge cases: ambiguous text, empty string, single word (~4)
- NLTagger disambiguation for "draft" (~2)
- Framing: verify output structure per intent (~6)
- Verify cleaned text appears in framed output (~2)

**Integration:**
- `CommandParser.parse(from: "prompt mode")` → `.switchToPromptMode`
- `selectWorkflowMode(.prompt)` blocked when `promptModeEnabled == false`

### Python (~10 tests)

**test_prompt_framing.py:**
- Mirror Swift intent detection tests (same inputs, same expected outputs)
- Endpoint test: `POST /v1/prompt/frame` returns valid response

### Estimated total: ~30 new tests

## Architecture Diagram

```
┌─────────────┐    ┌──────────────┐    ┌────────────────────┐    ┌────────────────┐
│ Audio/STT   │───▶│ TextCleanup  │───▶│ PromptFraming      │───▶│ Insert/Review  │
│ (unchanged) │    │ Service      │    │ Service             │    │ (unchanged)    │
│             │    │ (.polish)    │    │ detectIntent()      │    │                │
│             │    │              │    │ frame()             │    │                │
└─────────────┘    └──────────────┘    └────────────────────┘    └────────────────┘
                         │                       │
                    [WhisperKit path:       [Backend path:
                     in-process]            /v1/prompt/frame]
```

## Decisions Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Intent detection approach | Keyword/NLTagger matching | Deterministic, testable, no model dependency. CoreML classifier can be added later. |
| Framing approach | Static string templates | No ML overhead, predictable output, easy to tune |
| Runtime | Hybrid (Swift local + backend fallback) | Preserves WhisperKit zero-backend path |
| Cleanup mode | Always `.polish` | Prompts should be fully cleaned before framing |
| Insert behavior | Follow existing `InsertBehavior` | Consistency with dictation mode |
| V1 intents | 6 categories | Covers ~90% of LLM prompt use cases without overcomplicating detection |
| Template picker UI | Not in V1 | YAGNI — auto-detection is the core value prop |
