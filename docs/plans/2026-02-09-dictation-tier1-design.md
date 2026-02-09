# Dictation Tier 1 Feature Design

**Date:** 2026-02-09
**Scope:** 4 features focused on dictation workflow speed, output quality, and integration
**Context:** VoxFlow is a personal daily-driver macOS dictation app. Meeting mode is intentionally excluded (crowded space — Zoom, Notion, Google all have native transcribers). These features optimize the dictation capture-to-insert loop.

---

## Feature Priority

| # | Feature | Category | Effort |
|---|---------|----------|--------|
| 1 | Auto-insert mode | Workflow speed | Small-medium |
| 2 | App-context formatting | Output quality | Medium |
| 3 | Session memory recall UI | Workflow speed | Medium |
| 4 | Clipboard history bridge | Integration | Trivial |

---

## Feature 1: Auto-Insert Mode

### Problem

Every dictation capture requires a review step before insertion. For confident, high-frequency dictation this is a speed bump — you almost always accept the cleaned text.

### Design

#### Data Model

Add `InsertBehavior` enum to `AppModels.swift`:

```swift
enum InsertBehavior: String, CaseIterable, Identifiable, Codable {
    case alwaysReview
    case autoInsertRaw
    case autoInsertLight
    case autoInsertPolish

    var id: String { rawValue }
    var cleanupMode: CleanupMode? {
        switch self {
        case .alwaysReview: return nil
        case .autoInsertRaw: return .raw
        case .autoInsertLight: return .light
        case .autoInsertPolish: return .polish
        }
    }
}
```

- `autoInsertRaw` skips cleanup API calls entirely — transcribe then insert, fastest path.
- Add `@Published var insertBehavior: InsertBehavior = .alwaysReview` to `AppState`.
- Persist via `SettingsCoordinator` using UserDefaults (preference, not a secret).

#### AppCoordinator Change

In `processDictation`, after cleanup completes, check `state.insertBehavior`:

- If `.alwaysReview`: current behavior unchanged (set `sessionState = .review`).
- If auto-insert variant: call `insertService.insert(text:)` directly with the text for the chosen cleanup level, set `sessionState = .idle`, update status line (e.g., "Inserted (polish, formal — Mail)").
- If `autoInsertRaw`: skip cleanup API calls entirely, insert raw transcription text.

The `processWithPrivacyGate` helper stays unchanged — auto-insert only affects what happens after the API call returns, not the privacy gating logic.

#### Failure Handling

If `insertService` returns a failed `InsertResult`, revert to review screen with status line "Auto-insert failed — review and retry". Text is never lost silently.

#### Settings UI

Add `InsertBehavior` picker in `SettingsView` under a "Dictation" section. Four radio options. Default remains `alwaysReview`.

#### Files Modified

- `AppModels.swift` — add `InsertBehavior` enum
- `AppState.swift` — add `insertBehavior` property
- `AppCoordinator.swift` — branch in `processDictation` based on insert behavior
- `SettingsCoordinator.swift` — persist/load `insertBehavior`
- `SettingsView.swift` — add picker

---

## Feature 2: App-Context Formatting

### Problem

Tone style is a manual selection. When you dictate into Slack you want concise, into Mail you want formal, into Xcode you want neutral. Switching manually per-app is friction.

### Design

#### Data Model

Add to `AppModels.swift`:

```swift
struct AppToneOverride: Codable, Identifiable {
    let appBundleID: String
    let appName: String
    let toneStyle: ToneStyle
    var id: String { appBundleID }
}
```

Add `@Published var appToneOverrides: [String: ToneStyle] = [:]` to `AppState` (keyed by bundle ID). Persist via UserDefaults as JSON dictionary.

#### FocusTargetSnapshot Change

Add `bundleID: String?` to `FocusTargetSnapshot`. Populate from `FocusContextMonitor` — `NSRunningApplication` already provides `bundleIdentifier` on the frontmost app.

#### Built-in Defaults

Ship hardcoded fallback map in `SettingsCoordinator`:

```swift
static let defaultAppTones: [String: ToneStyle] = [
    "com.tinyspeck.slackmacgap": .concise,
    "com.apple.mail": .formal,
    "com.microsoft.Outlook": .formal,
    "com.google.Chrome": .neutral,
    "com.apple.dt.Xcode": .neutral,
]
```

User overrides in `appToneOverrides` take precedence. No match falls back to `state.toneStyle` (the manual selection).

#### Integration Point

In `processDictation`, resolve effective tone before calling `BackendAPIClient.cleanup`:

```swift
let effectiveTone = state.appToneOverrides[state.focusTarget.bundleID ?? ""]
    ?? Self.defaultAppTones[state.focusTarget.bundleID ?? ""]
    ?? state.toneStyle
```

~5 line change. The `selectToneStyle` retone path still uses `state.toneStyle` — manual selection overrides auto-detection for the current review session.

#### Status Line

Surface the auto-selected tone in status messages:

- Auto-insert: "Inserted (polish, formal — Mail)"
- Review: "Review and insert (concise — Slack)"

#### Settings UI

Add "App Tones" section in Settings — a list of detected apps (populated from `insertStats` app names) with tone picker dropdown per row. Editable and deletable.

#### Files Modified

- `AppModels.swift` — add `AppToneOverride`
- `AppState.swift` — add `appToneOverrides`
- `AppCoordinator.swift` — resolve effective tone in `processDictation`
- `SettingsCoordinator.swift` — persist/load overrides, hardcoded defaults
- `SettingsView.swift` — add App Tones section
- `FocusContextMonitor.swift` — add `bundleID` to `FocusTargetSnapshot`

---

## Feature 3: Session Memory Recall UI

### Problem

`SessionMemoryStore` holds the last 20 transcripts in a ring buffer but nothing reads from it. You can't re-insert a previous dictation without re-speaking it.

### Design

#### SessionMemoryStore Change

Add a read accessor:

```swift
func recent(limit: Int = 10) -> [TranscriptCandidate] {
    Array(buffer.suffix(limit)).reversed()
}
```

Most recent first. Default limit of 10 — 20 is too noisy for a dropdown.

#### TranscriptCandidate Change

Add `timestamp: Date` field to `TranscriptCandidate`. Set at creation time in `processDictation`. Used for relative time display ("2m ago", "1h ago").

#### UI: Recent Tab

Add a "Recent" tab alongside existing Dashboard/Capture tabs in `CommandPaletteView`. Shows a scrollable list where each row displays:

- First ~80 characters of raw text (truncated with ellipsis)
- Cleanup mode that was selected
- Relative timestamp

#### Actions Per Row

Two buttons per row:

- **Insert** — inserts that transcript's text (at its original cleanup level) into the current focused field via `insertService`. No re-processing through cleanup API.
- **Copy** — copies to system clipboard.

#### Storage

In-memory only (session-scoped). Relaunch clears history. No dictation text persists to disk. Aligns with privacy-first design.

#### Files Modified

- `SessionMemoryStore.swift` — add `recent()` read accessor
- `AppModels.swift` — add `timestamp` to `TranscriptCandidate`
- `CommandPaletteView.swift` — add Recent tab
- `TextInsertionCoordinator.swift` — add direct text insert method if not already exposed

---

## Feature 4: Clipboard History Bridge

### Problem

Inserted dictation text vanishes into the target app. If you use a clipboard manager, it never sees the text because accessibility-based insertion bypasses the clipboard.

### Design

#### Implementation

In `TextInsertionCoordinator.insertCurrentText()`, after a successful insert via accessibility direct write, add:

```swift
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(insertedText, forType: .string)
```

#### Edge Case: Paste Fallback

When `insertService` falls back to simulated paste (`Cmd+V`), text is already on the clipboard. Guard with `result.method == .simulatedPaste` to skip the redundant write.

#### No Settings Toggle

Always-on behavior. No scenario where you'd insert text but not want it on the clipboard. One-line removal if this changes — not worth a toggle.

#### Status Line

No change. Clipboard write is silent background convenience.

#### Files Modified

- `TextInsertionCoordinator.swift` — add clipboard write after successful insert (~5 lines)

---

## Implementation Order

1. **Clipboard history bridge** (Feature 4) — trivial, ship first for immediate value
2. **Auto-insert mode** (Feature 1) — biggest friction reduction, moderate effort
3. **App-context formatting** (Feature 2) — compounds with auto-insert
4. **Session memory recall UI** (Feature 3) — standalone, no dependency on others

Features 1 and 2 interact: auto-insert uses the effective tone from app-context formatting. Building Feature 1 first with `state.toneStyle` fallback, then layering Feature 2's tone resolution on top, avoids coupling during development.

---

## Out of Scope

- Meeting mode features (Notion export, system audio capture) — intentionally excluded
- Translation mode enhancements — deferred to Tier 2+
- Streaming transcription — deferred to Tier 3
- Disk persistence of dictation history — violates privacy-first design
- Correction learning — Tier 2 feature, depends on auto-insert being stable first

## Verification

Each feature should include:
- Unit tests for new model types and store accessors
- Manual verification of status line messages for each workflow x provider mode combination
- `swift build` + `swift test` passing before merge
