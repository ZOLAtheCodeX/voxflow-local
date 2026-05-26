# Phase 4 — UI Modernization (Progress)

**Branch:** `feature/phase-4-ui` (branched from `370d74c`, Phase 3 tip)
**Started:** 2026-05-26
**Spec:** `docs/plans/2026-05-25-stabilization-modernization-roadmap.md` §Phase 4
**Baseline at start:** 256 Swift + 325 Python (+ 9 skipped) = 581 tests, all green.

Phase 3 closed on commit `370d74c`. All sub-phases 3.1–3.5 checked. Ollama is the only polish backend; `apply_tone(light_cleanup())` is the documented guardrail-fallback when Ollama is unreachable.

Phase 4 is **visual / UX only** — no backend changes. The chain of 5 commits on this branch contains zero modifications under `backend/app/`. Phase 5.1 (whisper short-audio fast path) and 5.2 (Luhn validator on redaction) work that the parallel ralph-loop iteration started while Phase 4 was open has been rebased off this branch; references preserved on `phase-5-stash` and `feature/phase-5-perf` for the next iteration.

## Acceptance criteria (from prompt)

1. Zero hardcoded `.font(.system(size:))` literals in `SetupWizardView.swift`, `SettingsView.swift`, `DashboardWindowView.swift`.
2. Zero `Color.gray.opacity(...)` references in any file under `Sources/VoxFlowApp/Views/`.
3. `swift build` warning-clean on UI changes.
4. `swift test` stays green (256+ tests).

## Task tracker

### 4.1 — Expand VFDesignTokens for full coverage ✅

- [x] Typography: display / large / title / heading / bodyEmphasized / body / label / secondary / captionEmphasized / caption (existing).
- [x] Add monospaced + micro variants: `monoCaptionFont`, `monoMicroFont`, `microFont` (used by Ollama pull-progress lines and host-memory readout).
- [x] Semantic colors: `colorSuccess` / `colorWarning` / `colorError` / `colorNeutral` (existing) + `tintedBackground(_:opacity:)` helper.
- [x] Motion presets: `animationStandard`, `animationPulse` (existing).
- [x] Background surfaces: `cardBackground` (= `.quaternary`), `elevatedBackground` (= `.regularMaterial`), `panelMaterial` (= `.ultraThinMaterial`).

### 4.2 — Replace `.font(.system(size:))` literals across the three target views ✅

- [x] `SettingsView.swift` — 35 literals → 0 (sed-driven systematic replacement using the VF token map; ternary-weight `selected ? .semibold : .regular` rewritten as `selected ? VF.bodyEmphasizedFont : VF.bodyFont`).
- [x] `DashboardWindowView.swift` — 28 literals → 0.
- [x] `SetupWizardView.swift` — 16 literals → 0.

Verification: `grep -c 'font(.system(size:' Sources/VoxFlowApp/Views/{SetupWizardView,SettingsView,DashboardWindowView}.swift` returns 0/0/0.

### 4.3 — Replace `Color.gray.opacity(...)` across all Views ✅

- [x] Materials sweep across `Sources/VoxFlowApp/Views/` — already done by prior edits; every legacy `Color.gray.opacity(0.08/0.10)` is now `VF.cardBackground` (= `.quaternary`) or `VF.elevatedBackground` (= `.regularMaterial`).
- [x] VFDesignTokens.swift docstring no longer contains the literal `Color.gray.opacity` phrase that the verification grep would catch.

Verification: `grep -r 'Color\.gray\.opacity' Sources/VoxFlowApp/Views/` returns zero hits.

### 4.4 — UX wins ✅

- [x] **Headliner #1 — Translucent menu bar panel** (`MenuBarPanelController.swift`): panel `.isOpaque = false`, `.backgroundColor = .clear`, hosting layer background `.clear`. SwiftUI root wrapped in `.background(VF.panelMaterial).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))`. Biggest visual delta of Phase 4.
- [x] **Stage progress (4-step)** — new `Sources/VoxFlowApp/Views/StagedProgressView.swift` replaces the plain `ProgressView()` in `CommandPaletteView.transcribingStateCard`. Renders capture → transcribe → cleanup → insert pills with checkmarks for completed, pulsing `.symbolEffect(.pulse)` for active, muted for pending. Collapsed VoiceOver label announces e.g. "Transcribing, step 2 of 4".
- [x] **Target app indicator** — `recordingStateCard` shows `Label("Inserting into \(state.focusTarget.appName)", systemImage: "arrow.right.circle")` with VoiceOver `accessibilityLabel`.
- [x] **Conditional Settings fields** (`SettingsView.swift`) — Local Whisper model fields render only when `state.sttBackend == .whisper`; OpenAI fields only when `.openAI`.
- [x] **Skip Calibration** (`OnboardingCalibrationView.swift`) — secondary `.bordered` button calling `coordinator.completeOnboardingManually()` with a `.help(...)` tooltip explaining recalibration is always available.
- [x] **ConfidenceBadge a11y** (`ConfidenceBadge.swift`) — `.accessibilityElement(children: .combine)` + `.accessibilityLabel("Confidence \(percent) percent")`. Colors migrated to `VF.colorSuccess/Warning/Error` (yellow → orange per Apple HIG warning convention; ConfidenceBadgeTests updated to match).
- [x] **T0·M0 expansion + shared `MetricCardView`** — both dashboards used near-identical metric-card helpers; extracted to `Sources/VoxFlowApp/Views/MetricCardView.swift`. Abbreviation `T<n> · M<n>` expanded to `Translate <n> · Meeting <n>`. `MetricCardView` combines its three Text rows into a single VoiceOver utterance.

### 4.5 — Build + test verification ✅

- [x] `swift build` clean — no new warnings, no errors.
- [x] `swift test` green — 256 tests, 0 failures.

## Commit history

```
76b23a5 refactor(ui): expand T0·M0 abbreviations + share MetricCardView (Phase 4)
d8b8ee4 feat(ui): conditional STT backend fields + extracted MetricCardView (Phase 4 closeout)
a8b67eb feat(ui): Phase 4 UX polish — stage progress, target indicator, a11y, more VF tokens
cf280ba refactor(ui): migrate inline status colors to VF semantic tokens
31f9561 feat(ui): Phase 4 — replace font/Color literals with VFDesignTokens
```

Five commits on the branch, each a clean logical group for review.

## Ralph Loop Execution Protocol

Same shape as Phase 3:

1. Read this file. Find the first sub-phase whose checkbox is `[ ]`.
2. Implement it. Strict rules from CLAUDE.md.
3. Verify (`swift build` clean + `swift test` green + the two grep gates).
4. Commit (imperative subject + Co-Authored-By trailer).
5. Update this file: `[ ]` → `[x]` for the completed item.
6. When all `[ ]` are flipped AND the four acceptance criteria above all hold, output `<promise>PHASE_4_COMPLETE</promise>`.
