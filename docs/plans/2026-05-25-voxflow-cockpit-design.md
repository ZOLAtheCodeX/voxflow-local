# VoxFlow Cockpit — Design Spec

- **Date:** 2026-05-25
- **Status:** Design (brainstorming output, pre-implementation-plan)
- **Audience:** Solo developer (VoxFlow is a personal tool)
- **Dependencies:** Builds on `docs/plans/2026-05-25-stabilization-modernization-roadmap.md`. Cockpit work assumes Phases 1–3 of that roadmap are complete (stabilization + Ollama/Gemma 4 swap).

## 1. Vision

VoxFlow Cockpit turns VoxFlow from a quick-dictation utility into a **local AI-augmented writing surface** for framework-driven legal, governance, and policy work. It keeps the existing quick-utterance flow intact and adds a dedicated long-form workspace where transcripts can be reshaped by Gemma-powered smart actions (memo format, MECE structuring, action-item extraction) and routed to targets like Notion or any focused app.

The cockpit ships in three layers. Each layer is individually useful. None depend on layers below them shipping fully polished.

## 2. Strategic context

### What the cockpit is

- A **document-centric workspace** for sustained dictation, review, and post-processing
- An **AI-augmented surface** where local Gemma 4 reshapes transcripts on demand
- A **personal tool** tuned to the developer's actual workflow (legal/governance writing, frameworks, Notion-heavy delivery)

### What the cockpit is not

- Not a replacement for the existing palette — quick utterances stay on the palette path
- Not multi-user (no shared dictionaries, no team features, no sync)
- Not cloud-routed (local-first; Ollama+Gemma 4 is the only inference target for smart actions)
- Not "ambient first" — ambient capture is Layer 2 and is opt-in

### What differentiates it from Wispr Flow

- Local model, no cloud, no subscription
- Framework-aware smart actions (MECE, Pyramid, memo format) Wispr doesn't ship
- Hackable / inspectable prompt templates and models
- Per-app behavior owned by the user, not auto-detected

## 3. Surface map

VoxFlow ships three distinct surfaces after the cockpit lands:

| Surface | Type | Trigger | Primary role |
| --- | --- | --- | --- |
| **Palette** | Non-activating `NSPanel` (existing) | `⌥` hold | Quick utterances (1–3 sentences) inserted into focused app |
| **Cockpit** | `NSWindow` (new) | `⌥⌘V` dedicated hotkey | Long-form drafting, smart actions, target picking |
| **Dashboard** | `NSWindow` (existing) | Menu bar → Dashboard | Metrics, history, settings, admin |

Each surface owns its workflow. The palette is unchanged. The cockpit is the new workspace. The dashboard stays separate.

**Key decision:** the cockpit and palette do *not* merge. Two distinct surfaces with different interaction shapes is cleaner than a god-window that tries to be both.

## 4. Hotkey & gesture model

| Gesture | Action |
| --- | --- |
| `⌥` (hold) | Quick capture via palette (current behavior, unchanged) |
| `⌥⌘V` | Open cockpit window |
| Cockpit: `⌘R` | Start long-form recording |
| Cockpit: `⌘.` or `esc` | Stop long-form recording |
| Cockpit: `⌘1`–`⌘6` | Apply Nth chip action |
| Cockpit: `⌘K` | Open full action palette |
| Cockpit: `⌘↩` | Insert into target |
| Cockpit: `⌘C` | Copy to clipboard |
| Cockpit: `⌘\` | Toggle distraction-free mode (hide side panel) |
| Cockpit: `⌘Z` / `⌘⇧Z` | Undo / redo action (revert smart-action transform) |

**Explicitly rejected:** `⌥⌥` double-tap to enter long-form. Modal gestures with timing dependence are fragile and exactly the "sometimes buggy" pattern we're avoiding.

## 5. Layer 0 — Foundation

The first shippable cockpit milestone. ~3–4 weeks after roadmap Phase 3 (Ollama/Gemma 4) is complete.

### 5.1 Long-form mode

Long-form is **explicit start/stop**, not hold-release. The user presses `⌘R` to start, dictates with natural pauses, presses `⌘.` or `esc` to stop.

Behavior:

- **Pause tolerance**: silence up to 4 seconds does not end recording. Silence longer than 4s but shorter than 20s triggers a soft paragraph break in the transcript (visible double newline). Silence longer than 20s prompts a soft "still recording?" pill that auto-dismisses on next speech.
- **In-place edit on correction**: when the user says "no scratch that" or "actually" mid-sentence, the heuristic replaces the trailing partial sentence with the new content. Behind a feature flag for Layer 0; can be disabled.
- **Auto-saving**: every 5s of speech, draft is persisted to a per-session file in `~/Library/Application Support/VoxFlow/sessions/`. Survives crashes.
- **Continuation**: after stop, user can press `⌘R` again to append more to the same session before applying an action.

### 5.2 Smart actions

**Shipping Layer 0:** three actions, no more.

| Action | Chip label | Voice keyword | Prompt strategy |
| --- | --- | --- | --- |
| **Memo format** | `memo` | `memo` | Restructure transcript into Issue / Analysis / Recommendation sections with H2 headers |
| **MECE structure** | `MECE` | `MECE` | Reorganize content into mutually-exclusive, collectively-exhaustive bullet groups |
| **Action items** | `action items` | `items` | Extract action items as a clean checkbox list, preserving owners and dates if mentioned |

Three more chips become available in Layer 0 via `⌘K` palette only (no persistent chip), promoted to the chip row if the user invokes them ≥3 times:

- `steel-man` — produce strongest counter-argument or steel-manned version of a stated position
- `Pyramid intro` — restructure as Pyramid Principle (conclusion-first, supporting points, evidence)
- `disclaimer` — append user's stored legal-information disclaimer

**MRU ordering:** after 30 cumulative captures, chip row sorts by usage frequency. ⌘1–6 shortcuts follow the new order automatically.

### 5.3 Document-centric UI

Cockpit window layout (matches the approved mockup):

- **Top bar**: recording state pill (live or ready), model pill (`gemma4:e4b-mlx`), target picker pill (defaults to focused app)
- **Main pane** (left, ~66% width): transcript with editable cursor, voice prompt strip (teaching-only, dismisses after ~10 captures), chip row at bottom with `⌘K all actions` overflow chip
- **Side panel** (right, ~240px, collapsible with `⌘\`):
  - **Layer 0:** Target card (current target with override dropdown) + Recent card (last 3 captures)
  - **Layer 1:** + Dictionary card
  - **Layer 2:** + Ambient buffer status
- **Footer**: hotkey legend, system status dots

### 5.4 Hybrid invocation

Three ways to trigger the same actions:

1. **Click a chip** in the chip row
2. **Press `⌘1`–`⌘6`** for the corresponding chip
3. **Say a keyword** during review state (`memo`, `MECE`, `items`, `steel`, `Pyramid`, `disclaimer`, `cancel`, `undo`)

**Voice grammar rules:**

- Voice commands only listen during **review state** (after recording stops). Never during active recording — that's content.
- Grammar is **single keywords**. Phrases are deliberately not supported in Layer 0 to keep the parser unambiguous.
- `cancel` / `undo` work as special meta-commands.
- Voice command parsing happens locally in Swift via keyword match; no Gemma call needed for the trigger itself.

### 5.5 Target picker

The "insert into" pill shows where text will land after an action is applied.

- **Default**: the focused app at capture-start (uses existing frozen `capturedTargetApp` snapshot)
- **Override**: click the pill to choose a different target — recent targets pinned, common apps listed
- **Layer 0 supports**: any focused app via existing AccessibilityInsertService
- **Layer 1 adds**: "Notion · <page name>" as a first-class pinned target with append-at-cursor behavior

### 5.6 Voice prompt strip (teaching-only)

A small italic hint strip below the transcript shows voice commands for the first ~10 captures (`memo · MECE · items · cancel`). After threshold, the strip vanishes permanently. Settings has a toggle to bring it back.

## 6. Layer 1 — Power features

~2 weeks after Layer 0 ships. None of these are required for Layer 0 to be useful.

### 6.1 Personal dictionary

- Seeded with legal/governance terms: `ISO 42001`, `AIGP`, `CIPT`, `GDPR`, `HIPAA`, `WHEREFORE`, statute formats (`§`, `RCW`), common contact names
- **Learning**: when the user corrects a word in the transcript during review, the (wrong → right) mapping is captured and applied to future transcripts in a post-process pass
- **Storage**: `~/Library/Application Support/VoxFlow/dictionary.json`
- **UI**: dictionary card appears in side panel showing recent learned corrections; full list editable in Settings → Dictionary
- **Privacy**: dictionary is local-only; never sent to a model

### 6.2 Notion deep integration

- Settings → Integrations → Notion: paste a Notion integration token (per their API docs); pick default workspace
- Cockpit target picker gains "Notion · <page>" entries — append-at-cursor or new task in Tasks DB
- Smart actions can be composed with target: e.g., "memo format → insert into Notion: Privacy Notes"
- All Notion API calls go through the backend's existing `BackendAPIClient` pattern; never from Swift directly (centralizes timeout/error handling)
- **Privacy**: Notion token in Keychain (existing `KeychainService` pattern); never UserDefaults

### 6.3 Voice snippets

- Named text expansions triggered by voice keyword: say `boilerplate` during quick or long-form, the snippet text is inserted at cursor
- Initial seed: `sigoff`, `boilerplate`, `disclaimer`, `addr`, `bcc-paralegals`
- **Storage**: `~/Library/Application Support/VoxFlow/snippets.json`
- **UI**: Settings → Snippets table; each row = (trigger, expanded text, scope)
- **Scope**: snippets can be global, or restricted to long-form only / quick only

### 6.4 Workflow chains

- Named multi-step automations: e.g., "Memo to Notion" = long-form capture → memo-format action → append to Notion: Privacy Notes
- Triggered from cockpit by name (typed in ⌘K palette) or dedicated hotkey
- Definition format: declarative JSON in `~/Library/Application Support/VoxFlow/chains.json`
- Settings → Chains UI for creating/editing
- **No conditional logic** in Layer 1 — chains are linear, like Shortcuts but simpler

## 7. Layer 2 — Ambient

~3–4 weeks after Layer 1 stable. **Riskiest layer.** Battery, privacy, and conceptual coherence concerns. Designed here as the north-star direction; do not implement until 0+1 are battle-tested.

### 7.1 Ambient meeting capture

- **Opt-in only.** Off by default. Toggle in cockpit top bar: "Arm ambient capture".
- When armed: continuous audio buffer with **voice activity detection** (VAD) running in-process. Buffer is a rolling 30-minute window.
- **Privacy controls** (non-negotiable):
  - Persistent menu bar indicator (red dot) when armed
  - System-level mic indicator must be visible
  - Auto-disarm after 4 hours
  - One-tap "purge buffer" button in cockpit
  - Buffer never written to disk in raw audio form — only transcribed text
- On user demand (`⌘⇧S` "summarize last meeting" or click a button), the buffered audio is transcribed via WhisperKit, then run through a Gemma-powered "meeting summary" action that produces:
  - Bulleted action items
  - Key decisions
  - Open questions
- Output goes into the cockpit as a transcript, where standard smart actions apply

### 7.2 Context awareness

- Builds on existing per-app profile system (`AppProfile` in `AppModels.swift`)
- Auto-detection layer: when the user starts dictation in an app without an explicit profile, VoxFlow infers a reasonable profile from app metadata (Slack → casual tone, Mail → formal, Cursor → code-aware, Notion → structured)
- Inferred profiles are suggested ("I noticed you've been dictating in Cursor — apply code-aware profile?"), never applied silently
- User can promote an inferred profile to explicit, or override

### 7.3 Auto-summarization

- Cron-like background task that runs on the ambient buffer every N minutes (configurable, default 15min)
- Produces a rolling summary that's available in the cockpit's Recent panel
- Off by default; opt-in alongside ambient capture

## 8. Architecture

### 8.1 New Swift components

| Component | Type | Role |
| --- | --- | --- |
| `CockpitCoordinator` | `@MainActor` class | Owns cockpit window state, target picking, chip MRU, action invocation routing |
| `LongFormSessionService` | `@MainActor` class | Pause-tolerant capture loop, in-place edit handling, auto-save |
| `SmartActionService` | actor | Calls backend `/v1/smart_action`; manages action history for undo |
| `CockpitWindowView` | SwiftUI view | Document-centric cockpit UI |
| `VoiceCommandRouter` | nonisolated | Keyword-match parser for review-state voice commands |

`AppCoordinator` remains the orchestration root. It gains a new method `openCockpit()` and routes long-form sessions to `LongFormSessionService` instead of the existing dictation workflow processor.

### 8.2 New backend endpoints

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `POST /v1/smart_action` | sync | `{action: "memo"\|"mece"\|"items"\|..., transcript, context}` → transformed text via Gemma. Layer 0. |
| `POST /v1/dictionary/apply` | sync | Layer 1. Apply local dictionary corrections to text. |
| `POST /v1/chain/run` | sync | Layer 1. Execute a named workflow chain. |
| `POST /v1/ambient/summarize` | sync | Layer 2. Summarize buffered transcript. |

All endpoints honor the existing rate-limit + privacy-redaction + consent-token patterns. Smart actions run through `PolishEngine` → `OllamaBackend` (after Phase 3 of stabilization roadmap completes the FLAN-T5 removal).

### 8.3 Gemma prompt strategy (smart actions)

System prompt template (per action):

```
You are a writing assistant. Apply the requested transformation to the user's
text. Return only the transformed text. No explanation, no preamble, no
quotes around the output.

Transformation: {ACTION_DESCRIPTION}

Constraints:
- Preserve the user's meaning and intent.
- Do not add information not present in the input.
- Do not add caveats, hedging, or apologies.
```

Per-action description fills in:

- **memo**: "Restructure as a formal memo with H2 headings for Issue, Analysis, and Recommendation."
- **MECE**: "Reorganize into mutually exclusive, collectively exhaustive bullet groups."
- **items**: "Extract a clean checkbox list of action items. Include any owners or dates mentioned."

Each action passes through the existing `_guardrail_triggered` check. On guardrail trigger, the action returns the original transcript with a "guardrail prevented transform" status, and Swift surfaces this as a non-blocking warning.

### 8.4 Data model additions

```swift
// New types in AppModels.swift

struct LongFormSession: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var transcript: String
    var targetApp: FocusTargetSnapshot?
    var appliedActions: [AppliedAction]
}

struct AppliedAction: Codable {
    let actionId: String         // "memo", "mece", "items"
    let appliedAt: Date
    let beforeText: String        // for undo
    let afterText: String
}

struct DictionaryEntry: Codable {
    let wrong: String
    let right: String
    let context: String?          // optional disambiguation
    let learnedAt: Date
}

struct VoiceSnippet: Codable {
    let trigger: String           // keyword
    let expansion: String
    let scope: SnippetScope       // .global / .longFormOnly / .quickOnly
}

struct WorkflowChain: Codable {
    let id: UUID
    let name: String
    let steps: [ChainStep]
}

enum ChainStep: Codable {
    case capture(mode: CaptureMode)
    case action(actionId: String)
    case insert(targetHint: TargetHint)
}
```

### 8.5 Persistence

- Long-form session drafts: `~/Library/Application Support/VoxFlow/sessions/<uuid>.json`
- Dictionary: `~/Library/Application Support/VoxFlow/dictionary.json`
- Snippets: `~/Library/Application Support/VoxFlow/snippets.json`
- Chains: `~/Library/Application Support/VoxFlow/chains.json`
- Action history (for ⌘Z): in-memory ring buffer of last 20 actions per session
- Ambient buffer: in-memory only (never disk)

## 9. Voice grammar (canonical)

| Keyword | Effect |
| --- | --- |
| `memo` | Apply memo format |
| `MECE` | Apply MECE structure |
| `items` | Extract action items |
| `steel` | Steel-man (Layer 0, no chip until promoted) |
| `Pyramid` | Pyramid intro (Layer 0, no chip until promoted) |
| `disclaimer` | Append disclaimer (Layer 0, no chip until promoted) |
| `cancel` | Cancel pending action |
| `undo` | Revert last applied action |
| `insert` | Insert current text into target |
| `copy` | Copy current text to clipboard |
| `dictionary` | Add the last correction to dictionary (Layer 1) |

Listening window: **only during review state** (after recording stops). Never during active recording. Never persistently in the background.

## 10. Implementation phasing

This spec corresponds to multiple implementation plans. Layer 0 gets its own plan first.

### Phasing within Layer 0

| Step | Effort | Description |
| --- | --- | --- |
| L0.1 | M (~1w) | `CockpitCoordinator` + `CockpitWindowView` skeleton; ⌥⌘V opens window; transcript display only |
| L0.2 | M (~1w) | `LongFormSessionService` — start/stop/pause-tolerance/auto-save; integrate with existing AudioCaptureService |
| L0.3 | S (~3d) | Backend `/v1/smart_action` endpoint + Gemma prompt templates; 3 action types |
| L0.4 | M (~5d) | Hybrid invocation: chip row, ⌘1–6 shortcuts, voice keyword router, ⌘K palette |
| L0.5 | S (~3d) | Side panel: Target + Recent cards; target picker dropdown |
| L0.6 | S (~2d) | MRU chip ordering; chip promotion at 3-invoke threshold |
| L0.7 | S (~2d) | Voice prompt strip teaching mode; auto-dismiss after 10 captures |
| L0.8 | S (~2d) | Long-form session persistence; recover-on-launch |
| L0.9 | M (~3d) | Tests: session state machine, smart action routing, voice grammar parser |

Total Layer 0: ~4 weeks of focused work.

### Layer 1 phasing (high-level only — separate plan when ready)

- L1.1 Personal dictionary (storage + learning loop + Settings UI)
- L1.2 Notion integration (token, target picker entries, append-at-cursor)
- L1.3 Voice snippets (storage + trigger pipeline + Settings UI)
- L1.4 Workflow chains (definition format + executor + Settings UI)

### Layer 2 phasing (high-level only — separate plan when ready)

- L2.1 Ambient capture infrastructure (VAD, rolling buffer, privacy controls)
- L2.2 Meeting summary action
- L2.3 Context awareness (inferred profiles, suggestion UX)
- L2.4 Auto-summarization background task

## 11. Out of scope

- Multi-language transcription. VoxFlow stays English-only unless the developer explicitly needs another language later.
- Team / shared features (shared dictionary, snippets, chains). Solo tool by design.
- Mobile / iOS port. macOS only.
- Cloud sync. Local-first by physics.
- Pricing, marketing, App Store distribution. Personal tool.

## 12. Open questions

- **Chip promotion threshold**: 3 invocations is a guess. Tune to actual usage during Layer 0 beta.
- **Voice grammar disambiguation**: if user says "memo" while dictating their content (unlikely but possible), the listening-only-during-review rule prevents misfire. But during quick captures, voice commands don't apply at all. Is there a use case for voice commands during quick capture? Probably not — quick utterances are too short for post-processing to be worth a voice step. Defer.
- **Long-form session ownership**: should completed sessions appear in the Dashboard window's history pane, or stay scoped to the cockpit's Recent card only? Lean toward cockpit-only for simplicity.
- **Smart action undo behavior**: `⌘Z` reverts the last applied action. Does it revert the *transcript edit* (in-place change) or pop the action from the history stack? Lean toward replacing transcript with last `beforeText`. Confirm during L0.4.
- **Action chip overflow**: ⌘K palette shows all actions including unpromoted ones. Should it also show recently-considered-but-not-applied actions? Probably no — adds noise.

## 13. Decisions deferred to implementation plans

- Specific Gemma prompt wording per action (tune during Phase 3.4 of stabilization roadmap)
- Cockpit window size / position memory across launches
- Whether cockpit auto-closes on insert, or stays open for follow-up captures
- Keyboard shortcut conflicts with apps that capture global hotkeys (e.g., Slack ⌘K)

---

## Revision log

- 2026-05-25 — initial spec from brainstorming session; reflects user choices: Cockpit philosophy (full 3-layer vision), document-centric layout, hybrid invocation, separate cockpit window for long-form, all 7 recommended cuts applied (no ⌥⌥ gesture, 3 actions instead of 6, teaching-only voice strip, single-keyword grammar, side panel content per layer, target defaults to focused app, MRU chip order).
