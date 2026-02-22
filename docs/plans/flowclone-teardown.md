# FlowClone Competitive Teardown (Adopt / Reject / Defer)

Date: 2026-02-14  
Scope: Benchmark `MichalBastrzyk/FlowClone` as a reference implementation for Mac-native dictation UX and release posture.

## Decision Rules

- Adopt: Improves Mac-native reliability or polish without weakening VoxFlow's local/privacy priorities.
- Reject: Introduces cloud lock-in or conflicts with private/local-first positioning.
- Defer: Valuable, but not required for dictation-core v1.

## Snapshot of Compared Baselines

- VoxFlow: SwiftUI menu bar app + Python sidecar backend, local-first with optional private/openai routing, privacy preview gate.
- FlowClone: SwiftUI/Xcode-first macOS app with focused dictation workflow and polished native UX posture.

## Decisions By Area

## 1) App Architecture / State Model

### Adopt

- Introduce explicit feature gates in app state for experimental modes (`translationModeEnabled`, `meetingModeEnabled`, dictation core always-on).
- Keep the coordinator boundary and continue decomposing large orchestration paths into focused services.

### Reject

- Full template-level migration to FlowClone architecture. VoxFlow retains its existing coordinator + sidecar model in v1.

### Defer

- Full finite-state-machine formalization of all UI/session transitions. Defer until post-v1 once release path is stable.

## 2) Hotkey + Recording Loop UX

### Adopt

- Keep "dictation core first" interaction defaults.
- Prioritize recording/transcribing visual-state tightening in the Week 3-4 polish window.

### Reject

- Any changes that reduce existing command-lane and privacy-review safeguards for convenience.

### Defer

- Full waveform/animation redesign until release engineering and readiness contracts are complete.

## 3) macOS Packaging / Signing

### Adopt

- Hardened runtime + notarized DMG release path.
- Explicit release script contract: `scripts/release_signed.sh --version --identity --team-id --notary-profile`.

### Reject

- Ad-hoc signatures as a release method.

### Defer

- Mac App Store packaging and sandbox conversion.

## 4) Build Tooling (SPM-only vs Xcode/XcodeGen Hybrid)

### Adopt

- Keep source-of-truth in current SPM layout.
- Allow release-oriented wrapper scripts around build/sign/notarize.

### Reject

- Forced immediate migration to Xcode project ownership for all development.

### Defer

- XcodeGen layer for release ergonomics if notarized direct-app pipeline proves insufficient.

## 5) Test Strategy / CI Shape

### Adopt

- One-command reproducible test entrypoint (`scripts/test_all.sh`) using project venv for backend tests.
- Keep both Swift and backend suites as release gates.

### Reject

- Testing posture that validates only UI/build without backend contract checks.

### Defer

- Full CI matrix for packaging/notarization until release credentials and runner strategy are finalized.

## 6) Local-vs-Cloud Inference Assumptions

### Adopt

- Dictation core remains local-first and operational offline where models are available.
- Cloud/private routes remain optional advanced settings.

### Reject

- Cloud-only assumptions that make dictation core dependent on remote providers.

### Defer

- Any model-provider simplification that removes local fallback guarantees.

## 7) Privacy / Security Posture

### Adopt

- Keep explicit consent gate and redaction preview before private API processing.
- Preserve metadata-only audit logging behavior for private API operations.

### Reject

- Removing per-request consent in private API mode.

### Defer

- Additional policy surface (enterprise policy bundles, signed policy manifests) after v1.

## Implementation Gate

Before major UI refactor work begins, this teardown must remain current and each `Defer` item must be either:

- moved to `Adopt` with implementation tasks, or
- reaffirmed as post-v1 backlog.
