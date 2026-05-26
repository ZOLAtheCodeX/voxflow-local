# Phase 4 — UI Modernization (Progress)

**Branch:** `feature/phase-3-ollama` (continuing — same branch carries Phase 3 + 4)
**Started:** 2026-05-26
**Spec:** `docs/plans/2026-05-25-stabilization-modernization-roadmap.md` §Phase 4
**Baseline at start:** 256 Swift + 325 Python (+ 9 skipped) = 581 tests, all green.

Phase 3 closed on commit `370d74c`. All sub-phases 3.1–3.5 checked. Ollama is the only polish backend; `apply_tone(light_cleanup())` is the documented guardrail-fallback when Ollama is unreachable.

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

### 4.4 — Build + test verification ✅

- [x] `swift build` clean — no new warnings, no errors.
- [x] `swift test` green — 256 tests, 0 failures.

## Ralph Loop Execution Protocol

Same shape as Phase 3:

1. Read this file. Find the first sub-phase whose checkbox is `[ ]`.
2. Implement it. Strict rules from CLAUDE.md.
3. Verify (`swift build` clean + `swift test` green + the two grep gates).
4. Commit (imperative subject + Co-Authored-By trailer).
5. Update this file: `[ ]` → `[x]` for the completed item.
6. When all `[ ]` are flipped AND the four acceptance criteria above all hold, output `<promise>PHASE_4_COMPLETE</promise>`.
