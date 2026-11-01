# UI and UX refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give VoxFlow one status vocabulary, a calmer palette, a pill that
reports every outcome, task-grouped Settings, a Setup checklist and a
document-grade cockpit, without changing any behavior behind the controls.

**Architecture:** Presentation only. New design primitives (`VFStatus`,
modifiers, components, copy helpers) are pure and value-driven, so they are
unit-tested and render in an offscreen harness. Large views become thin shells
over focused files. Every button keeps calling the same coordinator method it
calls today.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI and AppKit, macOS 14
deployment target built with the macOS 26-era SDK, XCTest via `swift test`.

**Spec:** `docs/superpowers/specs/2026-11-01-ui-ux-refresh-design.md`
(approved 2026-10-31, including its "Amendments after approval" section).

## Global Constraints

- Work only in the worktree `.claude/worktrees/ui-ux-refresh` on branch
  `feature/ui-ux-refresh`. Never switch branches in the main checkout, never
  stash, never push without the maintainer's explicit go-ahead.
- Diff allowlist, checked in Task 12: `Sources/VoxFlowApp/Views/**`,
  `Sources/VoxFlowApp/Services/RecordingOverlayController.swift`,
  `Tests/VoxFlowAppTests/**`, `docs/superpowers/**`, `CLAUDE.md`
  (architecture notes only), `CHANGELOG.md` (only after v0.1.6 is tagged).
- No edits to `AppCoordinator.swift`, any other file in `Services/`, `State/`,
  `Models/`, `backend/` or `VoxFlowLocalApp.swift`.
- No new `@Published` properties on `AppState`; no new UserDefaults keys.
- Every control calls the same coordinator method, with the same arguments, as
  before. Keyboard shortcuts stay: palette ⏎ Insert, ⌘R (now "Start Over"),
  ⌘1 Setup, ⌘2 Dashboard, ⌘, Settings, ⌘Q Quit, ⎋ Cancel; cockpit routing in
  `KeyEventBridge` and `CockpitKeyRouter` is untouched.
- No `.font(.system(size:` and no `Color.gray.opacity` anywhere in
  `Sources/VoxFlowApp/Views/` (existing `CLAUDE.md` rule, now tested).
- Copy: buttons and menu items in title-style capitalization; headings,
  section titles and descriptions in sentence case; no em dashes in new copy;
  no internal names (enum values, bundle IDs, "regex", "STT") outside Advanced
  and diagnostic detail. Glossary: Voice control, Skill profiles, Voice
  actions, Speech model, Engine, "Cleanup: local rules".
- Tests never write `NSPasteboard.general`, never read the Keychain, never
  construct real capture or insertion services (`CLAUDE.md` "Do Not").
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  (or the trailer of the model that did the task).
- Every commit that moves or rebuilds a control lists, in its body, each moved
  control and the coordinator call it makes (spec acceptance criterion 5).

## Review Focus

1. **Same-turn ordering in the pill.** If a code path sets `lastInsertResult`
   just after `sessionState` turns `.idle`, an eager classifier says the
   dictation did not insert. Expected: "Inserted". Test in Task 5.
2. **Captures that end without inserting by design** (built-in voice actions,
   voice-control commands). Expected: the status line, neutral, never "Not
   inserted". Test in Task 5.
3. **The Last-dictation card after a reject.** Expected: the reject reason and
   no Insert Again, never an older dictation offered as if it were the last
   one. Test in Task 6.
4. **A repeating animation that bypasses Reduce Motion** (`repeatForever`,
   `symbolEffect`, `VF.animationPulse` used directly in a view). Expected:
   impossible to merge. Lint rule in Task 2.
5. **Long strings** (a 300-character status line, "Microsoft Outlook (PWA)" as
   a target). Expected: one line, tail-truncated, the pill no wider than
   360 pt. Test in Task 5; `lineLimit` checked in the Task 6 and 7 renders.

---

### Task 1: Snapshot harness, Settings seams, "before" images

**Files:**
- Create: `Tests/VoxFlowAppTests/UISnapshot/SnapshotRenderer.swift`
- Create: `Tests/VoxFlowAppTests/UISnapshot/UISnapshotFixtures.swift`
- Create: `Tests/VoxFlowAppTests/UISnapshot/UISnapshotExportTests.swift`
- Modify: `Sources/VoxFlowApp/Views/SettingsView.swift` (two seams, no visual change)
- Create: `docs/superpowers/images/2026-11-01-ui-ux-refresh/before/*.png`

**Interfaces:**
- Produces: `typealias SecretLoader = (String) -> String?` (in `SettingsView.swift`);
  `enum SettingsTab: Hashable { case general, models, tools, privacy, advanced, permissions }`;
  `SettingsView(... , initialTab: SettingsTab = .general, secretLoader: @escaping SecretLoader = { KeychainService.load(account: $0) })`.
- Produces (tests): `@MainActor enum SnapshotRenderer { static func export<V: View>(_ view: V, name: String, size: CGSize, appearances: [NSAppearance.Name] = [.aqua, .darkAqua]) throws }`;
  `@MainActor enum UISnapshotFixtures` with `makeTempDirectory() -> URL`,
  `state(_ configure: (AppState) -> Void) -> AppState`,
  `receiptStore(lines: [String]) -> InsertionReceiptStore`,
  `cockpit(state: AppState, transcript: String?) -> CockpitFixture` (a struct
  holding a `CockpitCoordinator`, `LongFormSessionService`,
  `CockpitCaptureCoordinator`, `DictionaryStore` and `ChainStore` built on
  temp files and fakes).

- [ ] **Step 1: Add the two Settings seams.** In `SettingsView`, replace the three `KeychainService.load(account:)` calls in `.onAppear` with `secretLoader(...)` for the same accounts, and drive the `TabView` from `@State private var selection: SettingsTab` initialised from `initialTab`, tagging each tab. The default arguments keep the call in `VoxFlowLocalApp.swift` compiling unchanged.

- [ ] **Step 2: Build.** Run: `swift build` Expected: `Build complete!`

- [ ] **Step 3: Write `SnapshotRenderer.export`.** Host the view in an `NSHostingView` sized to `size`, put it in a borderless, never-ordered-front `NSWindow` with `appearance = NSAppearance(named:)`, call `layoutSubtreeIfNeeded()`, spin the main run loop for 0.4 s so `onAppear` and `.task` run, then `bitmapImageRepForCachingDisplay(in:)` plus `cacheDisplay(in:to:)` and write PNG to `<VOXFLOW_UI_SNAPSHOTS>/<name>-light.png` or `-dark.png`.

- [ ] **Step 4: Write the fixtures.** Fixture stores live in a fresh temp directory. Receipt lines follow the format in `InsertionReceiptStoreTests.line(second:text:)`. Fakes for `AudioCapturing`, `ChunkTranscribing` and `SmartActionBackend` return fixed values. A reviewing cockpit is reached through `LongFormSessionService.start(targetApp:)`, `setTranscript(_:)` and `stop()`. Fixture text is invented (for example "Draft the quarterly update for the design team."), never copied from real data.

- [ ] **Step 5: Write `UISnapshotExportTests`.** Every test starts with `try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)`. Surfaces and sizes:

| name | view | size |
|---|---|---|
| `pill-listening`, `pill-voice-control`, `pill-transcribing` | `RecordingPillView` with fixture state | 220×32 |
| `palette-idle`, `palette-review`, `palette-recording`, `palette-transcribing`, `palette-recent` | `CommandPaletteView(coordinator: .shared, state:, receiptStore:)` | 430×600 |
| `cockpit-empty`, `cockpit-review` | `CockpitWindowView` from `CockpitFixture` | 960×620 |
| `dashboard` | `DashboardWindowView(coordinator: .shared, ...)` | 860×720 |
| `settings-<tab>` for each `SettingsTab` | `SettingsView(..., initialTab:, secretLoader: { _ in nil })` with fixture stores | 660×560 |
| `setup`, `welcome` | `SetupWizardView`, `WelcomeView` | 660×720, 420×480 |

- [ ] **Step 6: Confirm the gate.** Run: `swift test --filter UISnapshotExportTests` Expected: all tests skipped, 0 failures.

- [ ] **Step 7: Render the "before" set.** Run: `VOXFLOW_UI_SNAPSHOTS=$PWD/docs/superpowers/images/2026-11-01-ui-ux-refresh/before swift test --filter UISnapshotExportTests` Expected: PNGs written, 0 failures. Then delete the `-dark` files except for the pill, palette and cockpit, and run `du -sh` on the folder: under 2 MB, else `sips -Z 1200` the largest.

- [ ] **Step 8: Inspect every image** (open each PNG). It must show no real data: no real dictation text, vocabulary, skill profile name, Notion page, path or key. A real skill-profile name from `AppCoordinator.shared` is the known risk; if one appears, render with no active profile or crop it out.

- [ ] **Step 9: Run the suite.** Run: `swift test` Expected: same pass count as before plus the skipped export tests, 0 failures.

- [ ] **Step 10: Commit** the harness, the Settings seams and the before images: `git commit -m "UI refresh: snapshot harness, Settings seams, before images"`.

### Task 2: Tokens, brand-ink contrast, token lint

**Files:**
- Modify: `Sources/VoxFlowApp/Views/VFDesignTokens.swift`
- Modify: `Sources/VoxFlowApp/Views/CommandPaletteView.swift:631` (only `monoTimerFont` → `timerFont`)
- Test: `Tests/VoxFlowAppTests/BrandInkContrastTests.swift`, `Tests/VoxFlowAppTests/DesignTokenLintTests.swift`

**Interfaces:**
- Produces on `VF`: `readingFont` (15 pt regular), `readingLineSpacing: CGFloat = 4`,
  `readingMaxWidth: CGFloat = 640`, `timerFont` (30 pt semibold,
  `.monospacedDigit()`), `colorBrand` (`#2FD4C5`), `brandInkNSColor: NSColor`,
  `colorBrandInk`, `colorListening` (= `colorBrandInk`), `colorVoiceControl`
  (`.indigo`), `surfaceWindow` (`windowBackgroundColor`), `surfaceText`
  (`textBackgroundColor`), `hairline` (`separatorColor`), `brandPlateTop`,
  `brandPlateBottom`, `brandStroke` (the three `WavelineMark` RGB values),
  `spacingXSmall: CGFloat = 4`, `spacingXLarge: CGFloat = 24`. `monoTimerFont`
  is removed.
- Produces (tests): `DesignTokenLintTests.pendingFiles: Set<String>`, which later
  tasks shrink.

- [ ] **Step 1: Write the failing contrast test.**

```swift
final class BrandInkContrastTests: XCTestCase {
    func test_brandInk_reaches_4_5_to_1_on_window_background_light_and_dark() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let ratio = wcagContrast(VF.brandInkNSColor, NSColor.windowBackgroundColor, in: name)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, name.rawValue)
        }
    }
}
```

`wcagContrast` resolves both colors with `NSAppearance(named:)!.performAsCurrentDrawingAppearance` and `usingColorSpace(.sRGB)`, then applies the WCAG 2 relative-luminance formula.

- [ ] **Step 2: Run it.** `swift test --filter BrandInkContrastTests` Expected: FAIL, `brandInkNSColor` undefined.

- [ ] **Step 3: Add the tokens.** `brandInkNSColor` is `NSColor(name: "VoxFlowBrandInk")` whose provider returns `#2FD4C5` when `appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua` and `#0A6F68` otherwise (about 5.1:1 on `#ECECEC`). Move `monoTimerFont`'s one use to `timerFont`.

- [ ] **Step 4: Run it.** Expected: PASS.

- [ ] **Step 5: Write the lint test.** Scan every `.swift` file under `Sources/VoxFlowApp/Views/` (repo root found by walking up from `#filePath`), skipping lines whose trimmed text starts with `//`. Rules, each a regex:
  - color: `Color\((red|hue|white):`, `Color\(nsColor:`, `Color\.gray\.opacity`, `Color\.(green|orange|red|blue|purple|mint|yellow|pink|teal|cyan|indigo|brown)\b`, and `(?<![\w.])\.(green|orange|red|blue|purple|mint|yellow|pink|teal|cyan|indigo|brown)\b`
  - type: `\.system\(size:`
  - motion: `repeatForever`, `\.symbolEffect\(`, `VF\.animationPulse`

  `VFDesignTokens.swift` is exempt from all rules; `VFModifiers.swift` (Task 4) only from motion.

```swift
static let pendingFiles: Set<String> = [
    "CommandPaletteView.swift", "DashboardWindowView.swift", "SettingsView.swift",
    "SetupWizardView.swift", "WelcomeView.swift", "StagedProgressView.swift",
]
func test_views_use_tokens_for_color_type_and_motion()   // no violation outside pendingFiles; message lists file:line:rule
func test_every_pending_file_still_needs_its_fix()        // each pending file has ≥ 1 violation
```

- [ ] **Step 6: Run it.** `swift test --filter DesignTokenLintTests` Expected: PASS. If the first test reports a file not in the list, it is a real pre-existing literal: add the file to `pendingFiles` and name it in the commit message.

- [ ] **Step 7: Commit.** `git commit -m "UI refresh: brand, surface and reading tokens; token lint"`

### Task 3: Status vocabulary and badge

**Files:**
- Create: `Sources/VoxFlowApp/Views/VFStatus.swift`
- Create: `Sources/VoxFlowApp/Views/Components/VFStatusBadge.swift`
- Test: `Tests/VoxFlowAppTests/VFStatusTests.swift`

**Interfaces:**
- Produces: `struct VFStatus: Equatable { enum Kind { case ready, starting, listening, voiceControl, working, review, attention, error, inactive }; let kind: Kind; let label: String; init(_ kind: Kind, _ label: String) }`
  with computed `symbol: String`, `color: Color`, `isLive: Bool` (true for
  listening and voiceControl) and defaults `static let ready` ("Ready"),
  `starting` ("Starting"), `listening` ("Listening"), `voiceControl` ("Voice
  control"), `review` ("Review").
- Symbols and colors (spec table plus amendments 2 and 3): ready
  `checkmark.circle.fill`/`colorSuccess`; starting `hourglass`/secondary;
  listening `waveform`/`colorListening`; voiceControl `command`/`colorVoiceControl`;
  working `ellipsis.circle`/`colorInfo`; review `text.cursor`/`colorInfo`;
  attention `exclamationmark.triangle.fill`/`colorWarning`; error
  `xmark.octagon.fill`/`colorError`; inactive `minus.circle`/secondary.
- Produces mappings:
  - `static func palette(sessionState: SessionState, isCommandLaneActive: Bool, dictationReady: Bool, isWarmingUp: Bool, hasTextTarget: Bool) -> VFStatus`
  - `static func pill(sessionState: SessionState, isCommandLaneActive: Bool) -> VFStatus?`
  - `static func cockpit(_ state: LongFormState) -> VFStatus`
  - `static func engine(_ readiness: BackendReadinessState, backendShouldRun: Bool) -> VFStatus`
  - `static func speechModel(_ readiness: BackendReadinessState) -> VFStatus`
- Produces: `struct VFStatusBadge: View { let status: VFStatus; var detail: String? = nil }`,
  which draws the symbol, `label` and an optional "· detail", with one
  combined accessibility label "\(label), \(detail)".

- [ ] **Step 1: Write the failing tests.**

```swift
func test_palette_recording_in_voice_control_lane() { XCTAssertEqual(VFStatus.palette(sessionState: .recording, isCommandLaneActive: true, dictationReady: true, isWarmingUp: false, hasTextTarget: true), .voiceControl) }
func test_palette_recording() { /* .recording, lane false → .listening */ }
func test_palette_transcribing() { /* → VFStatus(.working, "Transcribing") */ }
func test_palette_inserting() { /* → VFStatus(.working, "Inserting") */ }
func test_palette_review() { /* → .review */ }
func test_palette_onboarding() { /* → VFStatus(.working, "Calibrating") */ }
func test_palette_error() { /* → VFStatus(.error, "Failed") */ }
func test_palette_idle_warming() { /* idle, ready false, warming true → .starting */ }
func test_palette_idle_not_ready() { /* idle, ready false, warming false → VFStatus(.attention, "Not ready") */ }
func test_palette_idle_no_text_field() { /* idle, ready true, target false → VFStatus(.attention, "No text field") */ }
func test_palette_idle_ready() { /* → .ready */ }
func test_pill_visible_only_while_capturing() { /* .recording → .listening, lane → .voiceControl, .transcribing → working "Transcribing", .inserting → working "Inserting"; .idle, .review, .onboarding, .error → nil */ }
func test_cockpit() { /* .idle → .ready, .recording(startedAt:) → .listening, .reviewing → .review */ }
func test_engine() { /* not needed → VFStatus(.inactive, "Engine not needed"); ready → VFStatus(.ready, "Engine ready"); warming → VFStatus(.starting, "Engine starting"); else VFStatus(.error, "Engine not ready") */ }
func test_speech_model() { /* whisperKitReady or readyForDictation → VFStatus(.ready, "Speech model ready"), else VFStatus(.starting, "Speech model loading") */ }
func test_every_kind_has_a_symbol_and_a_label() { /* for each Kind: symbol non-empty, label non-empty: color is never the only signal */ }
```

"Not needed" means `!backendShouldRun && !processRunning && !warmupInProgress`, the predicate `DashboardWindowView.backendStatusColor` uses today.

- [ ] **Step 2: Run them.** `swift test --filter VFStatusTests` Expected: FAIL, `VFStatus` undefined.
- [ ] **Step 3: Implement `VFStatus` and `VFStatusBadge`** in the files above.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "UI refresh: one status vocabulary and badge"`

### Task 4: Modifiers, components, copy helpers, setup progress

**Files:**
- Create: `Sources/VoxFlowApp/Views/VFModifiers.swift`
- Create: `Sources/VoxFlowApp/Views/Components/VFChip.swift`, `VFKeycap.swift`, `VFBanner.swift`, `VFSectionHeader.swift`, `VFEmptyState.swift`
- Create: `Sources/VoxFlowApp/Views/VFCopy.swift`, `Sources/VoxFlowApp/Views/SetupProgress.swift`
- Test: `Tests/VoxFlowAppTests/VFCopyTests.swift`, `Tests/VoxFlowAppTests/SetupProgressTests.swift`, `Tests/VoxFlowAppTests/VFMotionTests.swift`

**Interfaces:**
- Produces: `enum VFMotion { static func allowsRepeatingAnimation(isActive: Bool, reduceMotion: Bool) -> Bool }`;
  `extension View { func vfLive(_ isActive: Bool) -> some View; func vfSurface<S: InsettableShape>(_ kind: VFSurfaceKind, in shape: S) -> some View }`;
  `enum VFSurfaceKind { case hud, card, content, elevated }`;
  `extension AnyTransition { static func vfStateChange(reduceMotion: Bool) -> AnyTransition }`.
  - `vfStateChange` returns `.opacity` under Reduce Motion, and
    `.opacity.combined(with: .move(edge: .trailing))` (today's palette
    transition) otherwise.
  - `vfLive` pulses opacity between 1 and 0.35 with `VF.animationPulse` when
    allowed, otherwise draws the view static.
  - `vfSurface(.hud)` uses `glassEffect(.regular, in: shape)` inside
    `if #available(macOS 26, *)`, else `.regularMaterial`. `.card` uses
    `VF.cardBackground`, `.content` uses `VF.surfaceText`, `.elevated` uses
    `VF.elevatedBackground`.
  - When `colorSchemeContrast == .increased`, `.hud` and `.card` add a 1 px
    `VF.hairline` stroke.
- Produces components:
  - `struct VFChip: View { let text: String; var symbol: String? = nil; var tint: Color = VF.colorNeutral }`
  - `struct VFKeycap: View { let keys: String }`
  - `struct VFBanner: View { enum Kind { case info, warning, error }; let kind: Kind; let message: String; var actionTitle: String? = nil; var action: (() -> Void)? = nil; var onDismiss: (() -> Void)? = nil }`
  - `struct VFSectionHeader: View { let title: String }`
  - `struct VFShortcutHint: Hashable { let keys: String; let label: String }`
  - `struct VFEmptyState: View { let title: String; let symbol: String; let message: String; var shortcuts: [VFShortcutHint] = [] }`

  `VFEmptyState` wraps `ContentUnavailableView`. Fonts come from `VF.captionFont` and up; `VF.microFont` is used only inside `VFKeycap`.
- Produces copy helpers on `enum VFCopy`:
  - `cleanupProviderLabel(provider: String, model: String) -> String`
  - `isCleanupDegraded(provider: String) -> Bool`
  - `hotkeyHint(dictation: DictationHotkeyPreset, voiceControl: CommandLaneHotkeyPreset) -> String`
  - `paletteSecondLine(status: VFStatus, hint: String, statusLine: String) -> String`
  - `slowRunNotice(elapsedSeconds: Int) -> String?`
  - `yesNo(_ raw: String?) -> String`
- Produces: `struct SetupProgress: Equatable { let microphone, accessibility, engine, calibration: Bool; var doneCount: Int; var total: Int { 4 }; var remainingRequired: Int }`.
  Only microphone and accessibility are required.

- [ ] **Step 1: Write the failing tests.**

```swift
func test_cleanup_label_degraded()  { XCTAssertEqual(VFCopy.cleanupProviderLabel(provider: "", model: ""), "Cleanup: local rules, fallback") }
func test_cleanup_label_rules()     { XCTAssertEqual(VFCopy.cleanupProviderLabel(provider: ProviderConfigStore.rulesSentinel, model: ""), "Cleanup: local rules") }
func test_cleanup_label_provider()  { XCTAssertEqual(VFCopy.cleanupProviderLabel(provider: "ollama", model: "gemma4:e2b-mlx"), "Cleanup: ollama · gemma4:e2b-mlx") }
func test_cleanup_label_no_model()  { XCTAssertEqual(VFCopy.cleanupProviderLabel(provider: "lmstudio", model: ""), "Cleanup: lmstudio") }
func test_degraded_only_when_empty() { XCTAssertTrue(VFCopy.isCleanupDegraded(provider: "")); XCTAssertFalse(VFCopy.isCleanupDegraded(provider: ProviderConfigStore.rulesSentinel)) }
func test_hotkey_hint() { XCTAssertEqual(VFCopy.hotkeyHint(dictation: .fnOnly, voiceControl: .fnCommandSpace), "Hold Fn to dictate · Fn + Command + Space for voice control") }
func test_second_line_ready_shows_hint() { XCTAssertEqual(VFCopy.paletteSecondLine(status: .ready, hint: "H", statusLine: "Inserted"), "H") }
func test_second_line_otherwise_shows_status_line() { XCTAssertEqual(VFCopy.paletteSecondLine(status: .starting, hint: "H", statusLine: "Backend starting"), "Backend starting") }
func test_slow_notice_threshold() { XCTAssertNil(VFCopy.slowRunNotice(elapsedSeconds: 14)); XCTAssertEqual(VFCopy.slowRunNotice(elapsedSeconds: 15), "Still working. The first run after a pause can take up to a minute while the model loads.") }
func test_yes_no() { XCTAssertEqual(VFCopy.yesNo("true"), "Yes"); XCTAssertEqual(VFCopy.yesNo("false"), "No"); XCTAssertEqual(VFCopy.yesNo(nil), "Unknown"); XCTAssertEqual(VFCopy.yesNo("ok"), "ok") }
func test_setup_progress() { let p = SetupProgress(microphone: true, accessibility: false, engine: true, calibration: false); XCTAssertEqual(p.doneCount, 2); XCTAssertEqual(p.remainingRequired, 1) }
func test_motion_gate() { XCTAssertFalse(VFMotion.allowsRepeatingAnimation(isActive: true, reduceMotion: true)); XCTAssertTrue(VFMotion.allowsRepeatingAnimation(isActive: true, reduceMotion: false)); XCTAssertFalse(VFMotion.allowsRepeatingAnimation(isActive: false, reduceMotion: false)) }
func test_app_display_name_falls_back_to_bundle_id() { XCTAssertEqual(SkillProfileSettingsSection.applicationName("local.voxflow.nonexistent"), "local.voxflow.nonexistent") }
```

- [ ] **Step 2: Run them.** `swift test --filter "VFCopyTests|SetupProgressTests|VFMotionTests"` Expected: FAIL on undefined symbols.
- [ ] **Step 3: Implement** the helpers, `SetupProgress`, the modifiers and the components.
- [ ] **Step 4: Run them, then the lint test.** Expected: PASS (the motion exemption for `VFModifiers.swift` holds).
- [ ] **Step 5: Commit.** `git commit -m "UI refresh: motion and surface modifiers, components, copy helpers"`

### Task 5: Recording pill

**Files:**
- Create: `Sources/VoxFlowApp/Views/RecordingPillView.swift` (moved out of the controller file, restyled)
- Modify: `Sources/VoxFlowApp/Services/RecordingOverlayController.swift`
- Test: `Tests/VoxFlowAppTests/RecordingOverlayControllerTests.swift`, `Tests/VoxFlowAppTests/PillOutcomeTests.swift`
- Modify: `Tests/VoxFlowAppTests/UISnapshot/UISnapshotExportTests.swift` (outcome renders)

**Interfaces:**
- Consumes: `VFStatus.pill(sessionState:isCommandLaneActive:)`, `VFStatusBadge`, `vfLive`, `vfSurface(.hud, in: Capsule())`, `VF.timerFont`.
- Produces: `enum PillOutcome: Equatable { case inserted, readyToReview, notInserted(message: String), status(message: String) }`
  with `static func classify(finalState: SessionState, insertSucceeded: Bool?, statusLine: String) -> PillOutcome?`
  and `var announcement: String`.
- Produces: `@MainActor final class PillPresentation: ObservableObject { @Published var outcome: PillOutcome? }`;
  `struct RecordingPillView: View { @ObservedObject var state: AppState; @ObservedObject var presentation: PillPresentation; var onCancel: () -> Void }`.
- Produces on the controller:
  - `init(state: AppState, outcomeDuration: Duration = .milliseconds(1500), onCancel: @escaping () -> Void)`.
    The trailing-closure call in `AppCoordinator` compiles unchanged.
  - `var currentOutcome: PillOutcome? { get }`
  - `nonisolated static func pillSize(for outcome: PillOutcome?) -> NSSize`:
    220×32, or 360×32 for `.notInserted` and `.status`.
  - `pillOrigin(...)` is unchanged.

Classification order (spec amendment 1): `insertSucceeded == false` →
`.notInserted(statusLine)`; `== true` → `.inserted`; `finalState == .review` →
`.readyToReview`; otherwise `.status(statusLine)`, or `nil` when `statusLine`
is empty. Announcements: "Inserted", "Ready to review", "Not inserted.
\(message)", and the message itself.

- [ ] **Step 1: Write the failing outcome tests** (`PillOutcomeTests`): one per classification branch; empty status line → nil; `classify(finalState: .idle, insertSucceeded: nil, statusLine: "Voice action: new tab") == .status(message: "Voice action: new tab")` (Review Focus 2); `pillSize(for: .status(message: String(repeating: "x", count: 300))).width == 360` (Review Focus 5); `pillSize(for: nil) == NSSize(width: 220, height: 32)`.

- [ ] **Step 2: Write the failing controller tests.** Existing tests construct the controller with `outcomeDuration: .zero` and keep their assertions. New `async` tests use `outcomeDuration: .milliseconds(80)` and drive `state` plus `sessionStateChanged`:
  - `test_successful_insert_shows_inserted_then_hides`: `.recording`, `.transcribing`, set `lastInsertResult` with success, `.idle`. After 20 ms, visible with `.inserted`; after 200 ms, hidden.
  - `test_result_set_just_after_idle_still_counts` (Review Focus 1): `.idle` first, then `lastInsertResult` in the same turn. Outcome `.inserted`.
  - `test_review_shows_ready_to_review`.
  - `test_failed_insert_shows_not_inserted_with_status_line`: `statusLine = "Insert failed. Copied to clipboard."`, `.review`. Outcome `.notInserted(message: "Insert failed. Copied to clipboard.")`, because a failure wins over review.
  - `test_recording_straight_to_idle_shows_nothing`: cancel or too short.
  - `test_new_recording_replaces_outcome`.
  - `test_outcome_passes_mouse_events_through`: `panelForTesting.ignoresMouseEvents` is true during an outcome and false while live.
  - `test_review_insert_without_capture_stays_hidden`: `.inserting` then `.idle` with no prior `.recording`.

- [ ] **Step 3: Run them.** `swift test --filter "PillOutcomeTests|RecordingOverlayControllerTests"` Expected: FAIL on undefined symbols.

- [ ] **Step 4: Implement.**
  - Show live UI for `.recording`, and for `.transcribing` and `.inserting` only while a capture is active. Hide immediately for everything else.
  - On leaving `.transcribing` or `.inserting`, classify on the next main-actor turn (`await Task.yield()`) so a same-turn `lastInsertResult` is seen. Then publish the outcome, post `AccessibilityNotification.Announcement(outcome.announcement)`, resize and re-center with `pillSize(for:)`, set `ignoresMouseEvents = true`, sleep `outcomeDuration`, and hide unless a new capture started.
  - Subscribe to `state.$lastInsertResult` with `dropFirst()`. Record `insertSucceeded` only while a capture is active; reset it at `.recording`.
  - The view shows a `vfLive` dot plus "Listening" or "Voice control" and an `m:ss` timer in `VF.timerFont` at caption size. Working is the word alone, with no spinner. Outcomes are a `VFStatusBadge`, kept to one line with `.truncationMode(.tail)`.
  - Cancel is an `xmark.circle.fill` button, shown on `onHover`, with `.help("Cancel (esc)")` and accessibility label "Cancel dictation". There is no tap gesture on the capsule.

- [ ] **Step 5: Run them, then the full suite.** Expected: PASS; `swift test` 0 failures.
- [ ] **Step 6: Render the pill** (all live states plus the four outcomes) with the harness, and look at each image.
- [ ] **Step 7: Commit.** `git commit -m "UI refresh: pill with honest listening state, outcomes and explicit cancel"`

### Task 6: Menu-bar palette

**Files:**
- Modify: `Sources/VoxFlowApp/Views/CommandPaletteView.swift` (becomes the shell; public initializer unchanged)
- Create in `Sources/VoxFlowApp/Views/Palette/`: `PaletteHeaderView.swift`, `PaletteLastResultCard.swift`, `PaletteReviewCard.swift`, `PaletteRecordingCard.swift`, `PaletteProgressCard.swift`, `PaletteOptionsRow.swift`, `PaletteFooter.swift`, `PaletteRecentList.swift`
- Delete: `Sources/VoxFlowApp/Views/DashboardPanelView.swift` (after confirming its only use is the Stats tab: `grep -rn DashboardPanelView Sources`)
- Test: `Tests/VoxFlowAppTests/PaletteLastResultTests.swift`; `DesignTokenLintTests.pendingFiles` loses `CommandPaletteView.swift`

**Interfaces:**
- Consumes: `VFStatus.palette`, `VFStatusBadge`, `VFBanner`, `VFChip`, `VFKeycap`, `VFCopy.*`, `SetupProgress`, `CaptureReceiptRowModel`, `VF.timerFont`.
- Produces: `enum PaletteLastResult { static func canReinsert(receiptIsReject: Bool, hasRecentDictation: Bool) -> Bool }`.
- Produces views:
  - `PaletteHeaderView(status: VFStatus, targetAppName: String?, isVoiceControlActive: Bool, secondLine: String, errorMessage: String?)`
  - `PaletteLastResultCard(row: CaptureReceiptRowModel?, canReinsert: Bool, onInsertAgain: () -> Void, onCopy: () -> Void, onDetails: () -> Void)`
  - `PaletteRecordingCard(duration: TimeInterval, targetAppName: String?, isVoiceControl: Bool, onCancel: () -> Void)`
  - `PaletteProgressCard()`, which owns its elapsed counter
  - `PaletteReviewCard(coordinator: AppCoordinator, state: AppState)`, which holds today's privacy, translation, meeting and dictation review views
  - `PaletteOptionsRow(coordinator: AppCoordinator, state: AppState, onOpenSetup: () -> Void)`
  - `PaletteFooter(state: AppState, onOpenDashboard: () -> Void, onOpenSetup: () -> Void, onQuit: () -> Void)`
  - `PaletteRecentList(coordinator: AppCoordinator, state: AppState)`

- [ ] **Step 1: Mechanical move.** Cut each private computed view of `CommandPaletteView` into `extension CommandPaletteView` blocks in the new files, dropping `private` from what crosses files. No visual change.
- [ ] **Step 2: Build and test.** `swift build && swift test` Expected: 0 failures.
- [ ] **Step 3: Commit.** `git commit -m "Palette: move subviews into Views/Palette (no visual change)"`
- [ ] **Step 4: Write the failing test** (Review Focus 3):

```swift
func test_no_reinsert_after_reject() { XCTAssertFalse(PaletteLastResult.canReinsert(receiptIsReject: true, hasRecentDictation: true)) }
func test_reinsert_after_insert_with_recent() { XCTAssertTrue(PaletteLastResult.canReinsert(receiptIsReject: false, hasRecentDictation: true)) }
func test_no_reinsert_without_recent() { XCTAssertFalse(PaletteLastResult.canReinsert(receiptIsReject: false, hasRecentDictation: false)) }
```

- [ ] **Step 5: Run it.** Expected: FAIL. Implement `canReinsert`; run again. Expected: PASS.
- [ ] **Step 6: Rebuild the palette as in spec §5.**
  - **Header.** `VFStatus.palette` with `dictationReady` computed as today. The second line comes from `VFCopy.paletteSecondLine`, with the hint from `VFCopy.hotkeyHint`. `errorMessage` renders as a `VFBanner(.error)`.
  - **Main card by state.** Idle shows `PaletteLastResultCard` from `receiptStore.latest`. Insert Again calls `coordinator.insertRecentDictation(state.recentDictations[0])`. Copy runs the Recent row's existing three-line pasteboard copy, moved into one shared function, unchanged. Details calls `onOpenDashboardWindow`. Review and privacy states show `PaletteReviewCard`: Insert ⏎ → `insertCurrentText()`, Copy → `copyCurrentText()`, Start Over ⌘R → `retryLastCapture()`, and the confidence badge. Recording shows `PaletteRecordingCard`, whose Cancel ⎋ calls `cancelActiveCapture()`. Transcribing and inserting show `PaletteProgressCard` with `StagedProgressView` and `VFCopy.slowRunNotice`.
  - **Options row.** Cleanup and Tone menus call `selectCleanupMode` and `selectToneStyle`. The ••• menu holds "Profile for <app>…" (opens today's popover), `SkillProfileMenu`, `VoiceActionModeMenu`, a provider-mode picker (`selectProviderMode`), a workflow-mode picker only when `availableWorkflowModes.count > 1`, and "Setup…" (⌘1).
  - **Chips.** One each when not at default: Automatic Enter (warning tint), skill profile active, voice actions not off, Private API (warning, symbol `network`), workflow mode not Dictation.
  - **Setup banner.** "Finish setup: N step(s) left" with Open, shown when `SetupProgress.remainingRequired > 0`. It is computed in `onAppear` from `coordinator.permissionSnapshot()`.
  - **Tabs.** Dictate | Recent.
  - **Footer.** Settings (`SettingsLink`, ⌘,), Dashboard (⌘2), Cockpit (posts `.voxflowOpenCockpit`, shows `VFKeycap("⌥⌘V")` in its help), the cleanup label (warning tint when degraded), and Quit (⌘Q). A zero-size, accessibility-hidden button keeps ⌘1 → `onOpenSetup`.
  - **Voice-control background tint** uses `VF.colorVoiceControl` at 0.08.
  - **Card transitions** use `.vfStateChange(reduceMotion:)`, reading
    `@Environment(\.accessibilityReduceMotion)` in the shell.
  - **Privacy review** opens with `VFBanner(.warning, message: "This text will
    leave your Mac. Check it before you approve.")`. Its three buttons keep
    their calls and the ⎋ shortcut on Cancel.
  - **Delete `DashboardPanelView.swift`**, remove `CommandPaletteView.swift` from `pendingFiles`, and check that every button maps to the method it called before (list them in the commit body).
- [ ] **Step 7: Build, test, render.** `swift build && swift test`, then render the palette states. Expected: 0 failures. In the images, nothing below `VF.captionFont` carries status, and long strings stay on their lines.
- [ ] **Step 8: Commit.** `git commit -m "Palette: status, last result, one options row"`

### Task 7: Cockpit

**Files:**
- Modify: `Sources/VoxFlowApp/Views/CockpitWindowView.swift`, and in `Views/Cockpit/`: `CockpitTopBarView.swift`, `CockpitTranscriptView.swift`, `CockpitChipRowView.swift`, `CockpitSidePanelView.swift`, `VoicePromptStripView.swift`, `ActionPaletteView.swift`

**Interfaces:**
- Consumes: `VFStatus.cockpit`, `VFStatusBadge`, `VFChip`, `VFKeycap`, `VFBanner`, `VFSectionHeader`, `VFEmptyState`, `vfSurface`, `VF.readingFont`, `VF.readingLineSpacing`, `VF.readingMaxWidth`, `VFCopy.cleanupProviderLabel`.

- [ ] **Step 1: Restyle per spec §6** and amendment 4.
  - **Top bar.** `VFStatusBadge(status: .cockpit(state), detail: elapsed while recording)`; Discard unchanged. In-flight: `VFChip(text: "\(label) \(elapsed)", symbol: "ellipsis.circle", tint: VF.colorInfo)`. Provider: `VFChip` with a warning tint when degraded. Save failure: `VFChip("Not saving to disk", symbol: "exclamationmark.triangle.fill", tint: VF.colorError)`. Target: symbol `arrow.right` plus a chip with accessibility label "Target: <name>".
  - **Transcript.** On `vfSurface(.content)` with `readingFont`, `lineSpacing(VF.readingLineSpacing)`, and `frame(maxWidth: VF.readingMaxWidth)` centered. Editing and commit-on-focus-loss code are untouched. Empty: `VFEmptyState(title: "No capture yet", symbol: "waveform", message: "Press ⌘R to start a long-form capture.", shortcuts: [⌘R Record, ⌘. Stop, ⌘↩ Insert, ⌘K Actions])`.
  - **Root background** is `VF.surfaceWindow`. The bars keep `.thinMaterial`. The ⌘K overlay uses `vfSurface(.hud, in: RoundedRectangle(cornerRadius: VF.cornerLarge, style: .continuous))`. Handoff cards use `vfSurface(.elevated, …)`.
  - **Chips.** `VFKeycap("⌘\(n)")`; "All Actions" with `VFKeycap("⌘K")`.
  - **Voice strip.** `VFBanner(.info, message: "In review, say “memo”, “MECE”, “items”, “cancel” or “undo”.", onDismiss:)`. The dismiss closure keeps today's two lines verbatim.
  - **Error line.** `VFBanner(.warning, message: lastError, onDismiss: { lastError = nil })`. The 8 s `.task(id:)` stays.
  - **Side panel.** `VFSectionHeader` titles in sentence case, plain rows with `Divider()`, no card-in-card. Same five sections, same actions.
- [ ] **Step 2: Build, test, render.** `swift build && swift test --filter "Cockpit|PaletteSelection"`, then the full suite, then render the empty and review states. Expected: 0 failures, including `CockpitKeyRouterTests`.
- [ ] **Step 3: Commit.** `git commit -m "Cockpit: reading surface, status badge, calmer side panel"`

### Task 8: Settings mechanical split

**Files:**
- Modify: `Sources/VoxFlowApp/Views/SettingsView.swift` (becomes the `TabView` shell)
- Create in `Sources/VoxFlowApp/Views/Settings/`: `GeneralSettingsPane.swift`, `ModelsSettingsPane.swift`, `ToolsSettingsPane.swift`, `PrivacySettingsPane.swift`, `AdvancedSettingsPane.swift`, `PermissionsSettingsPane.swift`

**Interfaces:**
- Produces: one `struct <Name>SettingsPane: View` per old tab. Each pane takes the
  `coordinator`, `state` and stores it uses, plus `secretLoader` where it loads
  secrets (Models, Privacy, Tools for the Notion token). Each owns the `@State`
  drafts and helpers only it uses.

- [ ] **Step 1: Move each tab's body, its `@State` and its helpers verbatim** into its pane. Keychain loads move into the owning pane's `.onAppear` through `secretLoader`. The permission timer moves to the Permissions pane.
- [ ] **Step 2: Build and test.** `swift build && swift test` Expected: 0 failures.
- [ ] **Step 3: Render** each `SettingsTab`, and compare with the before images. Expected: identical layout.
- [ ] **Step 4: Commit.** `git commit -m "Settings: split panes into files (no visual change)"`

### Task 9: Settings regroup and copy

**Files:**
- Modify: the panes from Task 8 and `SettingsView.swift`
- Rename: `ToolsSettingsPane.swift` → `VoiceSettingsPane.swift`
- Create: `AppsSettingsPane.swift`; delete `PermissionsSettingsPane.swift` (merged into Privacy)
- Modify: `VocabularySettingsView.swift`, `ComputerActionSettingsView.swift`, `SkillProfileSettingsView.swift` (section titles and menu labels only)
- Modify: `UISnapshotExportTests.swift` (new tab cases)

**Interfaces:**
- Produces: `enum SettingsTab: Hashable { case general, apps, voice, models, privacy, advanced }`
  with toolbar labels General, Apps, Voice, Models, Privacy, Advanced and
  symbols `gearshape`, `app.badge`, `waveform`, `cpu`, `lock.shield`,
  `wrench.and.screwdriver`.

- [ ] **Step 1: Regroup sections per the spec §8 table.** Bindings and coordinator calls stay verbatim. The Notion section moves to Advanced → Integrations with its token draft and `secretLoader` load, so `AdvancedSettingsPane` takes `secretLoader` and `VoiceSettingsPane` no longer does.
- [ ] **Step 2: Rewrite the copy.**
  - **Section titles** in sentence case: Hotkeys, Dictation, Automatic Enter, Targeting, App profiles, Vocabulary, Voice snippets, Skill profiles, Voice actions, Workflow chains, Local AI model, Speech model, Model providers, Benchmark, Provider mode, Permissions, Experimental, Integrations, Engine (backend), Setup.
  - **Pickers.** "Command lane" → "Voice control"; "STT Backend" → "Speech model".
  - **Menu labels.** `SkillProfileMenu` reads "Skill profile: X". Its empty hint is "Add profiles in Settings → Voice".
  - **Insert-behavior notes** make no "default" claim:
    - Always Review: "Text waits in the VoxFlow panel until you insert it."
    - Raw: "Inserts the transcription as heard, with no cleanup."
    - Light: "Applies light cleanup, then inserts."
    - Polish: "Applies full cleanup, then inserts."
  - **App profiles** show `SkillProfileSettingsSection.applicationName(bundleID)` with the app icon (`NSWorkspace.shared.icon(forFile:)` when the URL resolves).
  - **Permissions rows** use `VFStatusBadge`: `VFStatus(.ready, "Granted")` or `VFStatus(.attention, "Missing")`.
  - **Engine status** uses `VFStatus.engine`.
  - Remove `SettingsView.swift` from `pendingFiles`.
- [ ] **Step 3: Build, test, render** each pane. Expected: 0 failures. Each pane fits 660×560 or scrolls, and no label is truncated.
- [ ] **Step 4: Commit.** `git commit -m "Settings: six task-grouped panes and plain copy"`

### Task 10: Dashboard

**Files:**
- Modify: `Sources/VoxFlowApp/Views/DashboardWindowView.swift`, `Sources/VoxFlowApp/Views/MetricCardView.swift`

**Interfaces:**
- Consumes: `VFStatus.engine`, `VFStatus.speechModel`, `VFStatusBadge`, `VFChip`, `VFCopy.cleanupProviderLabel`, `CaptureReceiptRowModel`.

- [ ] **Step 1: Reorder and restyle** per spec §7.
  - **Header.** "Dashboard", "This session, since" + `Text(state.launchedAt, style: .time)`, Reset Metrics.
  - **Health strip.** Three `VFStatusBadge`s.
  - **Recent Captures.** Two-line rows (outcome symbol, time, target and chips; then the snippet or reject reason), with the reveal-audio button unchanged.
  - **Metrics.** The Approvals card shows only when `translationModeEnabled || meetingModeEnabled`.
  - **App compatibility** in a `Grid`, with "Good" in `VF.colorInfo`.
  - **Mode usage and benchmark** show only when an experimental mode is on or `benchmarkHistoryByProfile` is non-empty.
  - **Background** `VF.surfaceWindow`.
  - Remove the file from `pendingFiles`.
- [ ] **Step 2: Build, test, render.** Expected: 0 failures.
- [ ] **Step 3: Commit.** `git commit -m "Dashboard: health first, recent captures second"`

### Task 11: Setup and Welcome

**Files:**
- Modify: `Sources/VoxFlowApp/Views/SetupWizardView.swift`, `WelcomeView.swift`, `OnboardingCalibrationView.swift`, `StagedProgressView.swift`, `ModeChip.swift`, `ConfidenceBadge.swift`

**Interfaces:**
- Consumes: `SetupProgress`, `VFStatus`, `VFStatusBadge`, `VFCopy.yesNo`, `VFCopy.hotkeyHint`, `vfLive`, brand tokens.

- [ ] **Step 1: Rebuild Setup as the spec §9 checklist** with amendment 4's heading "Set up VoxFlow" and "\(doneCount) of \(total) done".
  - **Rows.** Microphone, Accessibility, Speech engine, Voice calibration (optional), each with symbol, title, one-line purpose and one action. The actions call the same methods: `requestMicrophonePermission`, `requestAccessibilityPermission`, `startBackend`, `restartOnboardingCalibration`.
  - **Engine details** sit in a `DisclosureGroup("Details")` of `LabeledContent` rows: Engine status, Ready for dictation, Speech model loaded, Speech engine, Active model, Cloud fallback in use, Offline mode, Issues. Values pass through `VFCopy.yesNo`.
  - **Buttons.** "Skip Calibration" → `completeOnboardingManually()`. "Start Over" → today's full-reset sequence, verbatim.
  - **Try-it line** uses `VFCopy.hotkeyHint` and a `VFStatusBadge`.
  - **Accessibility-grant note:** "If you rebuild VoxFlow yourself, macOS may forget the Accessibility grant. Remove VoxFlow in System Settings → Privacy & Security → Accessibility and add it again."
- [ ] **Step 2: Welcome.**
  - The hint is built from the configured presets.
  - Badges: `VFStatus.speechModel` and the cleanup label.
  - `WavelineMark` takes its colors from the `brandPlateTop`/`brandPlateBottom`/`brandStroke`/`colorBrand` tokens.
  - The background is `VF.surfaceWindow`.
- [ ] **Step 3: Small views.**
  - `StagedProgressView`: drop the pulse `symbolEffect`; mark the active stage by symbol and color only.
  - `ModeChip`, `ConfidenceBadge` and `OnboardingCalibrationView`: tokens only.
  - Remove `SetupWizardView.swift`, `WelcomeView.swift` and `StagedProgressView.swift` from `pendingFiles`.
- [ ] **Step 4: Build, test, render.** Expected: 0 failures.
- [ ] **Step 5: Commit.** `git commit -m "Setup checklist, Welcome and small views on tokens"`

### Task 12: Finish: lint clean, after images, docs, scope check

**Files:**
- Modify: `Tests/VoxFlowAppTests/DesignTokenLintTests.swift` (`pendingFiles` becomes empty; the second test asserts that)
- Create: `docs/superpowers/images/2026-11-01-ui-ux-refresh/after/*.png`
- Modify: `CLAUDE.md` (Architecture tree: `Views/Components/`, `Views/Palette/`, `Views/Settings/`, `VFStatus.swift`, `VFModifiers.swift`, `VFCopy.swift`, the pill view's new home; Testing: `DesignTokenLintTests`, `VOXFLOW_UI_SNAPSHOTS`)

- [ ] **Step 1: Empty `pendingFiles`.** Run `swift test --filter DesignTokenLintTests`. Expected: PASS.
- [ ] **Step 2: Scope check.** Run: `git diff --name-only 2cf1cd8...HEAD | grep -vE '^(Sources/VoxFlowApp/Views/|Sources/VoxFlowApp/Services/RecordingOverlayController\.swift$|Tests/VoxFlowAppTests/|docs/superpowers/|CLAUDE\.md$)'` Expected: no output.
- [ ] **Step 3: Full suite.** `swift build && swift test` Expected: 0 failures; report the counts.
- [ ] **Step 4: Render the "after" set** into `after/`, keeping the same light and dark subset as `before/`. Inspect every image as in Task 1 Step 8.
- [ ] **Step 5: Update `CLAUDE.md`** architecture and testing notes (no other sections).
- [ ] **Step 6: Commit.** `git commit -m "UI refresh: lint clean, after images, architecture notes"`

## After the last task: reviews and the PR

1. **Codex.** Run `codex` over `git diff 2cf1cd8...HEAD` (use its review mode
   if present, else a read-only exec), asking for behavior changes behind
   controls, accessibility gaps and Swift 6 concurrency issues.
2. **Gemini.** Run `agy` with `gemini-4-argon-high` (quota returns about 11:10
   PDT on 2026-11-01) on the same diff, through the scratchpad runner, with the
   diff inlined in the prompt and terminal use forbidden.
3. **Verify, then fix.** Check each finding against the code before acting
   (`superpowers:receiving-code-review`). Fix the ones that hold, with a test
   where the finding is behavioral, and record each finding's outcome.
4. **Ask before pushing.** Get the maintainer's go-ahead, then push
   `feature/ui-ux-refresh` and open one PR against `master`. The body holds
   before-and-after images (labeled as offscreen renders), the review
   outcomes, the test counts and the manual check list from spec acceptance
   criterion 7. Add a `CHANGELOG.md` entry only if v0.1.6 is already tagged;
   otherwise say so in the body.
5. **Do not merge, and do not reinstall.** Bind the PR with the ccd_pr tools
   and report CI.
6. **Someday list.** Write the spec's excluded items to the Someday list on the
   Notion project page.
