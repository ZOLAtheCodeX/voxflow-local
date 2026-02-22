# WhisperFlow Alignment Pass (7-Workstream Swarm)

Date: 2026-02-14
Scope: Tighten VoxFlow dictation-core UX against current Wispr Flow positioning and Apple macOS guidance without changing local/privacy-first constraints.

## Sources Benchmarked

- Wispr Flow product updates and positioning:
  - https://wisprflow.ai/blog
  - https://wisprflow.ai/features
  - https://wisprflow.ai/apps
  - https://wisprflow.ai/shortcuts
- Apple guidance:
  - https://developer.apple.com/documentation/swiftui/menubarextra
  - https://developer.apple.com/design/human-interface-guidelines/designing-for-macos
  - https://support.apple.com/guide/mac-help/use-your-keyboard-like-a-mouse-mchlp1399/mac
  - https://support.apple.com/en-mn/guide/mac-help/mchlp1011/mac

## 7 Workstreams

## 1) Dictation-Core Default UX

- Adopt:
  - Dictation-first panel as default.
  - Keep single-primary action loop: capture -> review -> insert.
- Reject:
  - Broad first-run complexity in advanced modes.
- Defer:
  - Rich command expansion beyond dictation-core release scope.

## 2) Hotkeys and Keyboard-First Speed

- Adopt:
  - Keep hold-to-talk as main interaction.
  - Add explicit Escape-based cancel path in palette.
  - Use modifier-based in-app shortcuts for setup/dashboard/retry/quit.
- Reject:
  - Single-letter destructive shortcuts (e.g., bare `q`) in focused app UI.
- Defer:
  - User-customizable global hotkey mappings.

## 3) Menu Bar Native Behavior

- Adopt:
  - Window-style menu bar extra for richer control surface.
  - Keep stateful icon signals (recording/transcribing/error).
- Reject:
  - Overloading the menu bar surface with secondary configuration.
- Defer:
  - Additional menu command surfaces until post-v1.

## 4) Recording Loop Feedback

- Adopt:
  - Clear session-state cards for recording/transcribing/review.
  - Visual recording feedback (waveform + timer + pulse badge).
- Reject:
  - Hidden state transitions without visible status feedback.
- Defer:
  - Full waveform DSP/reactive redesign.

## 5) Privacy and Local-First Guardrails

- Adopt:
  - Preserve privacy preview + consent token gate for private API mode.
  - Preserve local/offline default routing.
- Reject:
  - Any cloud-only routing assumptions.
- Defer:
  - Enterprise policy layers outside v1.

## 6) Release and Reliability Contracts

- Adopt:
  - `/v1/ready` as launch/readiness contract.
  - Signed/notarized release script contract.
- Reject:
  - Replacing release gates with manual checklist-only flow.
- Defer:
  - Full CI notarization matrix until credentials/runners are finalized.

## 7) Accessibility and Safety

- Adopt:
  - Explicit labels/help for icon-only controls.
  - Escape and command-modifier shortcuts to support keyboard navigation.
- Reject:
  - Keyboard-only dead ends in review/capture flows.
- Defer:
  - Expanded VoiceOver rotor/announcement tuning.

## Changes Applied In This Pass

- `CommandPaletteView` now uses safer modifier-based shortcuts (`Cmd+1`, `Cmd+2`, `Cmd+,`, `Cmd+Q`, `Cmd+R`).
- Escape now cancels privacy review and active recording from the palette.
- `AppCoordinator` now exposes `cancelActiveCapture()` for keyboard-driven cancellation.
- Hotkey presets are now configurable in Settings for both dictation and command lane, and they apply immediately.
