# UI and UX refresh: design spec

The one bounded UI track the freeze allows (`CLAUDE.md`, "Exception: one UI
and UX track", decided 2026-10-31). Branch `feature/ui-ux-refresh`, cut from
local `master` at `2cf1cd8`. Status: **draft for the maintainer's review. No
code is written until this spec is approved.** The track changes views,
`VFDesignTokens.swift`, copy and layout only. It ends in one PR, reviewed with
Codex and with Gemini through `agy`, that is not merged or installed until the
14-day watch on v0.1.6 has passed (about 2026-11-16).

## What was asked, and what I assumed

Asked (relayed from the maintainer): an end-to-end redesign of the UI, GUI and
UX, grounded in research and design review, inside the freeze exception.

Constraints stated in the exception and the brief:

- Views under `Sources/VoxFlowApp/Views/`, `VFDesignTokens.swift`, copy and
  layout. Nothing in capture, STT, insertion, the clipboard
  (`PasteboardAccess`, `TemporaryPasteboard`), session storage, settings
  persistence, coordinator behavior or the backend.
- One spec, reviewed before code; one PR; not merged or installed during the
  watch; anything beyond the PR goes to the Someday list.

Assumptions (correct any of these in review):

- A1. The primary user dictates daily with automatic insertion and light
  cleanup, and uses the cockpit for long-form work. People running forks are
  the secondary audience.
- A2. "Improved" means clearer state, less clutter, no silent outcomes, one
  consistent look and better accessibility. It does not mean new features.
- A3. The menu-bar surface stays a custom panel in this track (see the
  counter-argument under "Approaches").
- A4. Nothing may look worse on macOS 14 and 15. macOS 26 and later may get
  Liquid Glass on floating surfaces.

## Measured facts driving this work

From a full read of the 25 files in `Views/` (5,016 lines) plus
`RecordingOverlayController.swift` (the pill), `MenuBarPanelController.swift`,
`MenuBarGlyph.swift` and `VoxFlowLocalApp.swift`. Live screenshots were not
possible: computer-use access to VoxFlow was declined, so this audit is from
source.

1. **Status is shown many ways at once, and they disagree.** The palette
   header carries the app title, `statusLine`, a hotkey line, a Ready or Not
   Ready capsule, and a second capsule showing `sessionState.rawValue.capitalized`
   (internal names such as "Review", "Inserting", "Onboarding"). The card below
   adds "Target Ready" or "No Text Target", the footer a polish-provider label,
   and a 10 pt last-capture row sits between them. Recording is orange in the
   session capsule, red in the palette waveform, teal in the pill and red in
   the cockpit.
2. **Colors bypass the tokens.** 24 color literals on 18 lines sit outside
   `VFDesignTokens.swift` in six files (lines: `CommandPaletteView` 9,
   `WelcomeView` 3, `SettingsView` 3, `SetupWizardView` 1,
   `DashboardWindowView` 1, the pill 1).
   The brand teal (`#2FD4C5`) is a raw RGB literal in two places.
   `Color(nsColor: .windowBackgroundColor)` is used directly in three windows.
   Font literals are at zero: the Phase 4 rule held.
3. **Configuration crowds the capture surface.** The palette's Dictate tab
   shows a provider picker, a workflow-mode picker (a one-segment control when
   no experimental mode is on), the review box, three cleanup chips, four tone
   buttons, an app-profile popover, Insert, Copy and Retry. Below the card sit
   menus for skill profiles and voice actions and an "Automatic Enter" line. A
   Stats tab duplicates the Dashboard window.
4. **Outcomes are silent where the user is looking.** The pill hides the
   moment the session leaves `.transcribing`. Rejects ("Too short", "Microphone
   delivered no audio") and insert failures reach only the palette's status
   line, and the palette is closed while the user dictates into another app.
5. **Both waveforms are decorative.** The palette and the pill animate a sine
   wave whether or not the microphone hears anything. No input level reaches
   `AppState`.
6. **Copy is partly internal and partly wrong.**
   - Internal: "STT", "regex fallback", "rules · local", "Backend Runtime",
     raw enum names, and bundle-ID fragments as app names in Settings ("slackmacgap").
     The Setup health check prints keys such as "Fallback active: false".
   - Wrong: Settings describes Always Review as "Default behavior"; the
     shipped default is `autoInsertLight` (`AppState.swift:23`). The palette's
     Retry (⌘R) does not retry: `retryLastCapture()` clears the candidate and
     returns to idle. Calibration is labeled "Required" next to a Skip button.
     "Setup Wizard" is a single page, not a wizard. Welcome hard-codes "Hold Fn"
     whatever hotkey preset is chosen.
   - Inconsistent: the command lane is "Command lane" in Settings, "Commands" in
     the palette hint and "VOICE CONTROL" on the badge. Skill profiles are
     "Voice Action Prompts", "Skills" and "Skill profile" on three surfaces.
7. **Accessibility settings are ignored.** No view reads Reduce Motion, Reduce
   Transparency, Increase Contrast or Differentiate Without Color, yet the
   session capsule, both waveforms and the staged-progress symbols animate
   forever. Text glyphs "●" and "→" in the cockpit are read aloud as
   characters. Status lives in 10 pt text in the last-capture row and the
   provider label.
8. **The cancel target is the whole pill.** One click anywhere on it cancels a
   recording of any length (`RecordingPillView.onTapGesture`).
9. **Information architecture is uneven.** In Settings, Privacy holds one
   section and Permissions two rows, while Advanced mixes experimental modes,
   translate profiles, engine controls and onboarding. Per-app profiles are
   edited in two places with different layouts. Permissions appear in Settings
   and Setup. Engine status appears in Settings, Dashboard, Setup and Welcome,
   phrased four ways.
10. **The cockpit's writing surface is small and translucent.** The whole
    window, text included, sits on `.regularMaterial`; the transcript is 13 pt
    with no line-length limit; the empty state is one line of text.
11. **The Dashboard is ordered as developer telemetry.** Recent captures, the
    most useful view for checking a lost dictation, comes fourth. Translate and
    meeting cards show even when those modes are off.
12. **Two files are too large to review well.** `CommandPaletteView.swift`
    (942 lines) and `SettingsView.swift` (1,113 lines) each mix many surfaces.

## Evidence from research

Gemini ran through `agy` as two parallel tracks, platform guidance and
comparable tools. The `gemini-4-argon-high` quota was exhausted (it resets
around 11:10 PDT on 2026-11-01), so both ran on `gemini-3.8-flash-high`. Its
output served only to locate sources. Every claim below was then checked
against the first-party page by a separate verification pass, and two Gemini
claims were corrected in the process.

### Platform guidance (Apple)

- **Menu bar extras.** Apple's default is a menu, not a popover, when people
  click a menu bar extra, unless the functionality is too complex for a menu.
  Icons are symbols drawn in black and clear so the system can tint them
  ([The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)).
  VoxFlow's panel is justified only by what needs a window: review editing,
  privacy approval, recent items. Everything else in it should be as light as
  a menu. The glyph already complies.
- **Panels.** Panels look less prominent than main windows, may use a dark
  translucent HUD style, and should prefer simple direct controls to typing
  and selecting ([Panels](https://developer.apple.com/design/human-interface-guidelines/panels)).
  Apple also expects panels to hide while their app is inactive; the pill
  deliberately does not, because its whole job is feedback over other apps.
- **Settings.** A toolbar of pane buttons that shows the active pane, a window
  title naming the pane, and dimmed minimize and maximize buttons
  ([Settings](https://developer.apple.com/design/human-interface-guidelines/settings)).
  The SwiftUI `Settings` scene with a `TabView` provides this, so six panes
  stay toolbar tabs rather than a sidebar.
- **Type.** 13 pt is the macOS default body size and 10 pt the minimum; macOS
  has no Dynamic Type
  ([Typography](https://developer.apple.com/design/human-interface-guidelines/typography)).
- **Progress.** Indeterminate indicators when the duration is unknown; every
  indicator disappears when the operation ends; status text only when it
  helps, short and specific; on macOS, avoid labeling a spinner
  ([Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)).
- **Errors and copy.** A title says what happened, never just "Error"
  ([Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)).
  Show the problem near where it happened, do not blame, say how to fix it
  ([Writing](https://developer.apple.com/design/human-interface-guidelines/writing)).
  Menu items and text buttons use title-style capitalization
  ([Menus](https://developer.apple.com/design/human-interface-guidelines/menus),
  [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)).
- **Permissions and onboarding.** Ask when people first use the feature unless
  the app cannot work without it; keep onboarding fast and optional; do not
  show a skipped tutorial again, but keep it easy to find
  ([Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy),
  [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)).
- **Liquid Glass.** A functional layer for controls and navigation that floats
  above content, not for the content layer; the regular variant suits
  text-heavy components
  ([Materials](https://developer.apple.com/design/human-interface-guidelines/materials)).
  `glassEffect(_:in:)` and `GlassEffectContainer` require macOS 26
  ([API](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))),
  so a macOS 14 target needs an availability check and a fallback. WWDC25
  "Meet Liquid Glass" (session 219) also advises against glass on glass; that
  wording was confirmed only as a paraphrase.
- **Accessibility.** Under Reduce Motion, reduce automatic and repetitive
  animation and replace movement with fades; never convey information by
  color alone
  ([Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)).

### Comparable tools (patterns, not designs to copy)

- **Honest input feedback.** Superwhisper's recording window draws microphone
  audio as a real-time waveform
  ([docs](https://superwhisper.com/docs/get-started/interface-rec-window)).
  Spokenly 2.33.1 (2026-10-23) changed its recording indicator to appear once
  the microphone is live ([release notes](https://spokenly.app/releases/macos)).
  VoiceInk issue #572 measured 874 to 1,092 ms between the start sound and
  capture, with speech lost in that gap
  ([issue](https://github.com/Beingpax/VoiceInk/issues/572)). VoxFlow's two
  waveforms are synthetic, so they promise more than they know.
- **One-step recovery of the last result.** Wispr Flow offers "Paste last
  transcript" from its menu-bar menu and floating bar
  ([docs](https://docs.wisprflow.ai/articles/6478598909-using-flow-with-linux-wsl-and-terminal-applications)).
  Spokenly 2.34.3 (2026-10-30) added a Paste Last Transcription shortcut.
  Aqua Voice keeps recent audio for three days so a session can be
  re-transcribed ([guide](https://aquavoice.com/guide/history)). VoxFlow
  already has Insert and Copy on recent dictations and keeps rejected audio,
  but buries both.
- **Mode on the recorder.** Superwhisper's recording window shows the active
  mode (same docs page). VoxFlow's pill looks the same in both lanes.
- **Cancel safety.** Superwhisper's Esc cancels recordings under 30 seconds at
  once and asks for confirmation above that (same docs page). VoiceInk
  requires Esc twice ([shortcuts](https://tryvoiceink.com/docs/shortcuts)).
  VoxFlow cancels on a single click anywhere on the pill.
- **Slow runs are named.** Wispr Flow shows "Taking longer than usual" with
  retry guidance
  ([docs](https://docs.wisprflow.ai/articles/4984532368-fix-taking-longer-than-usual-and-transcription-errors)).
  VoxFlow waits 90 seconds before saying anything, although cold model loads
  of 35 to 68 seconds are measured and expected.
- **Apple Dictation** signals with a pulsing cursor or a tone and stops after
  30 seconds without speech
  ([Mac User Guide](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac)).
  Gemini's claim of a "feedback window" did not survive verification.

## Goals

1. **One status vocabulary.** Every surface shows VoxFlow's state with the same
   symbol, word and color, and never with color alone.
2. **No silent outcomes.** The result of every quick dictation is visible in
   the pill, where the user is looking, for about 1.5 seconds.
3. **A calm palette.** The default view shows status, the last result with
   recovery actions, and one row of options. Everything else is one click away.
4. **Tokens are the only source of color and type in views**, enforced by a
   test rather than by review; motion and surfaces each go through one
   modifier.
5. **Accessibility settings are honored**: Reduce Motion, Increase Contrast,
   Differentiate Without Color, and VoiceOver announcements for outcomes.
6. **Copy is plain, correct and consistent**, following one glossary.
7. **Zero behavior change.** Every control calls the same coordinator method it
   calls today; `swift test` stays green.

## Non-goals

- Anything that needs a new signal from capture or a coordinator: a real level
  meter, an "arming" state before the first audio buffer, two-step cancel.
- New features: re-running cleanup, adding apps to profiles from Settings,
  persistent history.
- Status-line strings set inside `AppCoordinator` and the other coordinators.
- The menu-bar glyph (already a template image with stable bounds).
- Keyboard routing in the cockpit (`KeyEventBridge`, `CockpitKeyRouter`).

## Approaches

**A. Tokens and copy only.** Keep every layout; tokenize colors, fix copy, add
accessibility. About 15 files and low risk, but findings 1, 3, 4, 9 and 11
remain.

**B. Status-first restructure (recommended).** A, plus one status vocabulary
and a small component set; the palette reorganized around "state, last result,
options"; a pill with an honest listening state and an outcome state; Settings
regrouped by task and split one pane per file; Setup as a checklist; the
Dashboard reordered; a document-grade cockpit surface. All of it is
presentation: the same coordinator calls behind every control.

**C. Liquid Glass first.** B, plus a glass-native language everywhere: glass
palette, glass chips, sidebar Settings. Strongest look on macOS 26, but it
creates two divergent looks, goes beyond Apple's intent for glass (controls
floating over content, not content), and is the riskiest to judge without live
screenshots.

Recommendation: **B, with Liquid Glass only on surfaces that float over other
apps' content (the pill and the cockpit's ⌘K overlay), through one surface
token that falls back to today's materials below macOS 26.**

Counter-argument to B: Apple's guidance prefers a plain menu to a popover-style
window for a menu bar extra unless the functionality is complex. A native menu
for the default case, with the panel shown only when there is something to
review, would be more idiomatic and lighter. I am not proposing it here: it
changes what a click on the status item does and needs `AppCoordinator` to
decide when the panel appears, which is coordinator behavior. It goes to the
Someday list.

## Design

### 1. Tokens (`VFDesignTokens.swift`)

Typography keeps the current scale (13 pt body, the macOS default) and every
existing token name. Additions and one change:

- `readingFont` (15 pt regular) and `readingLineSpacing` (4 pt) for the cockpit
  transcript.
- `timerFont`: 30 pt semibold with monospaced digits instead of a monospaced
  design, replacing `monoTimerFont` at its one call site.
- `microFont` (10 pt) stays for keycaps and counts. It may not be the only
  carrier of status or content.

Color additions:

| Token | Value | Use |
|---|---|---|
| `colorBrand` | teal `#2FD4C5` | fills and marks only, never text on light backgrounds |
| `colorBrandInk` | dynamic: a darker teal in light mode, `#2FD4C5` in dark | brand symbols and text; at least 4.5:1 against the window background in both modes, checked by a test |
| `colorListening` | `colorBrandInk` | the listening state, every surface |
| `colorVoiceControl` | system indigo | the voice-control lane |
| `surfaceWindow`, `surfaceText` | `windowBackgroundColor`, `textBackgroundColor` | replace the three direct `NSColor` uses; `surfaceText` backs the cockpit transcript |
| `brandPlate`, `brandStroke` | the Waveline mark's plate gradient and stroke | move out of `WavelineMark` |

Red (`colorError`) is reserved for errors. Listening is the normal, happy state
of a dictation app, so it should not borrow the alarm color (see risks).

Motion: `animationStandard` is unchanged. Every repeating animation (live dot,
pulses, symbol effects) goes through one modifier, `vfLive(isActive:)`, that
renders a static frame when Reduce Motion is on. Transitions fall back to an
opacity fade under Reduce Motion.

Surfaces: one modifier, `vfSurface(_:in:)`, with four kinds:

- `.hud`: `glassEffect(.regular, in:)` on macOS 26 and later, `.regularMaterial`
  below (today's look).
- `.card`: `cardBackground`, as today.
- `.content`: opaque `surfaceText`.
- `.elevated`: `elevatedBackground`, as today.

Under Increase Contrast, `.hud` and `.card` gain a one-pixel separator border.
Glass is never placed on glass: cards inside a HUD use `.card`. The palette
panel's own material is set in `MenuBarPanelController` and stays as it is.

Spacing gains `spacingXSmall` (4) and `spacingXLarge` (24). Rewritten views use
tokens for padding; untouched views are not swept.

### 2. Status vocabulary (`VFStatus`, new)

| Status | Symbol | Color | Default label |
|---|---|---|---|
| ready | `checkmark.circle.fill` | `colorSuccess` | Ready |
| starting | `hourglass` | secondary | Starting |
| listening | `waveform` and a live dot | `colorListening` | Listening |
| voiceControl | `command` and a live dot | `colorVoiceControl` | Voice control |
| working | progress spinner | `colorInfo` | Transcribing, Cleaning up, Inserting |
| review | `text.cursor` | `colorInfo` | Review |
| attention | `exclamationmark.triangle.fill` | `colorWarning` | a specific phrase |
| error | `xmark.octagon.fill` | `colorError` | a specific phrase |

The mapping from app state to a status is a set of pure functions (palette,
pill, cockpit), unit-tested and kept in `Views/`. `VFStatusBadge` always draws
symbol plus word, and exposes one combined VoiceOver label.

### 3. Components (new, value-driven, in `Views/Components/`)

`VFStatusBadge`, `VFChip` (cockpit pills, receipt chips, active-option chips),
`VFKeycap` (⌘K, ⌘1 and the like), `VFBanner` (an inline notice or error with a
symbol, a message and an optional action or dismiss), `VFSectionHeader`
(sentence case, secondary; replaces the cockpit's tracked capitals) and
`VFEmptyState` (wraps `ContentUnavailableView`, macOS 14). None of them takes a
coordinator, so each renders in isolation for tests and images.

### 4. Recording pill

Before (156 by 30 pt, teal literal, synthetic bars, click anywhere cancels):

```
( ▮▮▯▮▯  7s )
( ◌ Transcribing )
```

After (about 220 by 32 pt; glass on macOS 26, material below):

```
( ● Listening      0:07   × )   listening: live dot, static under Reduce Motion
( ⌘ Voice control  0:03   × )   voice-control lane
( Transcribing… )               working: the word alone, no spinner
( ✓ Inserted )                  outcome, about 1.5 s, then hides
( ✓ Ready to review )           outcome when the capture waits for review
( ⚠ Insert failed. Copied to clipboard. )   outcome on failure or reject: the status line itself
```

- The live dot is an honest "listening" signal, not a level meter. A real meter
  needs a level from capture (non-goal).
- The working state drops today's labeled spinner. Apple advises against
  labeling spinners on macOS, and in a 32 pt HUD the word is what carries the
  information.
- Cancel becomes an explicit × that appears on hover and keeps the "Cancel
  (esc)" tooltip. It calls the same `onCancel`. Clicking elsewhere on the pill
  does nothing, so a stray click no longer throws away a long dictation.
- The outcome state (decision D2) lives inside `RecordingOverlayController`.
  On the transition out of `.transcribing` or `.inserting` it classifies the
  capture, in this order:
  1. "Not inserted": `lastInsertResult` changed during this capture and
     reports failure.
  2. "Inserted": `lastInsertResult` changed during this capture and reports
     success.
  3. "Ready to review": the session moved to `.review`.
  4. "Not inserted": anything else (an empty or rejected transcription).

  A "Not inserted" pill shows `statusLine` verbatim on one line, widening to
  about 360 pt and truncating the tail, so no coordinator string is parsed or
  rewritten. The outcome shows for an injectable duration (1.5 s by default)
  with mouse events passed through, then hides; a new capture replaces it at
  once. A recording that ends without transcribing (a cancel, or a press too
  short to count) shows no outcome, which matches how other tools treat
  accidental taps. The outcome is announced with
  `AccessibilityNotification.Announcement`.
- `RecordingPillView` moves from `Services/RecordingOverlayController.swift` to
  `Views/RecordingPillView.swift`, so the token test covers it.

### 5. Menu-bar palette

Before (from `CommandPaletteView.swift`):

```
VoxFlow Local [VOICE CONTROL]                [Ready]
Hold hotkey to talk                          [Idle]
Dictate: Fn · Commands: Fn+⌘+Space
┌────────────────────────────────────────────────┐
│ Target Ready                             Notes │
│ [ Dictate | Stats | Recent ]                   │
│ [ Local Only | Private API ]                   │
│ [ Dictation ]                                  │
│ ┌────────────────────────────────────────────┐ │
│ │ Hold Fn to dictate. Use … for command lane │ │
│ └────────────────────────────────────────────┘ │
│ (Raw)(Light)(Polish)                     ● 92% │
│ Tone [Neutral][Concise][Formal][Friendly]      │
│ [⚙ Profile: Notes] Custom                      │
│ [Insert] [Copy] [Retry]                        │
└────────────────────────────────────────────────┘
✓ 2m ax light Notes 1.2s "Lorem…"            (10 pt)
Skills: Off ▾
Voice actions: Off ▾
Automatic Enter: Off
[✦] [▦] [⚙]                     rules · local [⏻]
```

After:

```
✓ Ready · Notes                        ⌘ Voice control   (badge only while active)
Hold Fn to dictate · Fn ⌘ Space for voice control
┌ Last dictation ────────────────────────────────┐
│ ✓ Inserted in Notes · 2 min ago                │
│ "Lorem ipsum dolor sit amet, consectetur…"     │
│ [Insert Again] [Copy]                Details › │
└────────────────────────────────────────────────┘
[ Dictate | Recent ]
Cleanup: Light ▾   Tone: Neutral ▾   •••
[Automatic Enter: On] [Skill profile: Claude] [Private API]   (only when not default)
───────────────────────────────────────────────────
[⚙ Settings] [▦ Dashboard] [✎ Cockpit]   Cleanup: local rules   [⏻]
```

- **Header.** One `VFStatusBadge` plus the target app replaces the title, both
  capsules and the target line. The hint line shows the configured presets.
  `statusLine` appears in place of the hint only when it carries news (an
  error or a reject), as a `VFBanner`.
- **Main card, by state.**
  - Idle: "Last dictation" built from the latest receipt (outcome, time,
    target, snippet or reject reason). When that receipt is an insertion, the
    card offers Insert Again and Copy for the newest recent dictation. After a
    reject it shows the reason and no insert action, so it never offers an
    older dictation by mistake. Details opens the Dashboard, where retained
    audio can be revealed.
  - Review: the review editor, cleanup and tone, and Insert (⏎), Copy and
    Start Over (⌘R, today's Retry, renamed to say what it does).
  - Recording: the listening card (status, timer, target, Cancel ⎋).
  - Working: staged progress and elapsed time. After 15 seconds: "Still
    working. The first run after a pause can take up to a minute while the
    model loads."
  - Privacy review: unchanged in substance, given the most prominent styling
    because it is a consent gate.
- **Options row.** Cleanup and Tone become compact menus. The ••• menu holds
  the app profile, skill profile, voice actions, provider mode and, only when
  an experimental mode is enabled, the workflow mode. Chips appear for
  settings that are not at their default, because those change what a
  dictation does: Automatic Enter on, a skill profile active, Private API
  routing (shown with the warning tint, since text leaves the Mac).
- **Tabs.** Stats is removed; the Dashboard owns those numbers.
- **Footer.** A Cockpit button (⌥⌘V) is added. Setup leaves the footer:
  while a setup step is incomplete it appears as a banner ("Finish setup: 1
  step left"), otherwise in ••• (⌘1 keeps working through a hidden button).
  Quit stays.
- **Copy action.** The Last-dictation Copy reuses the Recent row's existing
  copy code unchanged. Routing view copies through `SystemClipboard.copy`
  stays the open spec 3 follow-up.
- `CommandPaletteView` remains the entry point (callers unchanged) and becomes a
  shell over files in `Views/Palette/`.

### 6. Cockpit

Before: text pills with "●" and "→" glyphs on `.regularMaterial`, a 13 pt
transcript, a one-line empty state, and side-panel cards nested in cards under
tracked capitals.

After:

```
● Recording 1:23  [Discard]  ◌ Memo 0:04        Cleanup: local rules   → Notes
──────────────────────────────────────────────────────────────────────────────
                 12 words · 1 paragraph · saved
                 Transcript in 15 pt reading type, at most ~70 characters
                 a line, on an opaque text background.
──────────────────────────────────────────────────────────────────────────────
ⓘ In review, say "memo", "MECE", "items", "cancel" or "undo".      [Dismiss]
[Memo ⌘1] [MECE ⌘2] [Items ⌘3]                                [All Actions ⌘K]
⚠ Memo failed: provider unavailable                                       [×]
```

- Top bar: `VFStatusBadge` and `VFChip`s; SF Symbols with labels replace the
  text glyphs. The save-failure warning becomes an error chip.
- Transcript: `vfSurface(.content)`, `readingFont`, a capped line length
  centered in wide windows. Editing behavior and commit-on-focus-loss are
  untouched.
- Empty state: `VFEmptyState` titled "No capture yet", listing ⌘R Record,
  ⌘. Stop, ⌘↩ Insert and ⌘K Actions.
- Error line: a `VFBanner` with a close button; the 8-second auto-dismiss stays.
- Side panel: `VFSectionHeader` and plain rows with separators instead of
  cards inside cards. Same five sections, same actions.
- The ⌘K overlay uses `vfSurface(.hud)`.

### 7. Dashboard

New order: header ("Dashboard", "This session, since 9:41", Reset Metrics);
a health strip (engine, speech model, cleanup provider, each a
`VFStatusBadge`); Recent Captures as two-line rows with the reject reason
visible and the existing reveal-audio button; session metrics (Captures,
Latency, Insert Success; Approvals only when translate or meeting is enabled);
app compatibility in a `Grid`; mode usage and benchmark only when an
experimental mode is enabled or data exists. "Good" stops using raw blue.

### 8. Settings

Panes before: General, Models, Dictation Tools, Privacy, Advanced, Permissions.
Panes after, still toolbar tabs (six panes suit tabs better than a sidebar):

| Pane | Sections (source pane) |
|---|---|
| General | Hotkeys; Dictation (insert behavior, corrected note); Automatic Enter (Dictation Tools); Targeting |
| Apps | Per-app profiles (General), shown with app names and icons resolved from bundle IDs via the existing `applicationName` helper, plus a line on built-in defaults |
| Voice | Vocabulary; Voice Snippets; Skill Profiles (was Voice Action Prompts); Voice Actions; Workflow Chains (all Dictation Tools) |
| Models | Local AI model; Speech model; Model providers; Benchmark |
| Privacy | Provider mode and Private API (Privacy); Permissions (Permissions pane) |
| Advanced | Experimental (protocol commands, translate, meeting and prompt modes, translate profiles); Integrations (Notion token from Dictation Tools, assistant handoff); Engine (start, stop, recheck); Setup (open setup, run calibration again) |

Each pane gets its own file in `Views/Settings/`. Bindings and coordinator
calls move verbatim; the drafts each pane needs move with it, and their
Keychain reads run when that pane appears instead of when the window appears.
`SettingsView` becomes the `TabView` shell.

### 9. Setup

Before: "Setup Wizard", four numbered cards all expanded, a raw health-key
dump, "Mark Complete" and "Run Full Setup Reset".

After, a checklist on one page:

```
Set Up VoxFlow                                            3 of 4 done
✓ Microphone          Lets VoxFlow hear you.                     Granted
✓ Accessibility       Lets VoxFlow type into other apps.         Granted
⚠ Speech engine       Transcribes on this Mac.     [Start Engine]  Details ›
○ Voice calibration   Optional. Can improve accuracy.     [Calibrate]
──────────────────────────────────────────────────────────────────────
Try it: click into any text field and hold Fn.        ✓ Notes is ready
```

Health details sit in a disclosure group of `LabeledContent` rows with plain
labels. "Mark Complete" becomes "Skip Calibration" and "Run Full Setup Reset"
becomes "Start Over" at the foot; both call the same methods. The note about
rebuilds invalidating the Accessibility grant stays for people building
forks, reworded.

### 10. Welcome

Layout unchanged. The hint uses the configured hotkey preset; the chips read
"Speech model ready" and "Cleanup: local rules"; the brand mark uses tokens.

## Copy rules and glossary

- Say what happened and what to do next, in plain words: "Not inserted: no text
  field was focused. Click into a field and try again."
- Buttons and menu items use title-style capitalization, as Apple's guidance
  asks ("Insert Again", "Skip Calibration"). Headings, section titles and
  descriptions use sentence case. Each element type keeps one style.
- No internal names (enum values, bundle IDs, "regex", "STT") outside Advanced
  and diagnostic detail.
- No em dashes in new copy.

| Today (varies by surface) | Proposed everywhere |
|---|---|
| Command lane, Commands, VOICE CONTROL | Voice control |
| Voice Action Prompts, Skills, Skill profile | Skill profiles |
| Voice action controls, voice actions | Voice actions |
| STT, STT Backend, Speech Models | Speech model |
| Backend, Backend Runtime, Local Backend Readiness | Engine ("backend" kept in parentheses in Advanced) |
| polish provider, regex fallback, rules · local | Cleanup: local rules (chosen); Cleanup: local rules, fallback (degraded); Cleanup: provider and model |
| Retry (palette) | Start Over |
| Setup Wizard | Setup |
| Mark Complete | Skip Calibration |

## File plan

New: `Views/VFStatus.swift`; `Views/Components/` (six components);
`Views/Palette/` (header, last-result card, review card, recording card,
progress card, options row, footer, recent list); `Views/Settings/` (six
panes); `Views/RecordingPillView.swift`.

Changed: `VFDesignTokens.swift`; `CommandPaletteView.swift` (shell);
`SettingsView.swift` (shell); `CockpitWindowView.swift` and the files in
`Views/Cockpit/`; `DashboardWindowView.swift`; `DashboardPanelView.swift`
(deleted if nothing else uses it); `SetupWizardView.swift`; `WelcomeView.swift`;
`StagedProgressView.swift`, `ModeChip.swift`, `ConfidenceBadge.swift` and
`MetricCardView.swift` (tokens); `Services/RecordingOverlayController.swift`
(pill size, outcome timing, view moved out).

Allowlist for the whole diff: `Sources/VoxFlowApp/Views/**`,
`Sources/VoxFlowApp/Services/RecordingOverlayController.swift`,
`Tests/VoxFlowAppTests/**`, `docs/superpowers/**`, `CLAUDE.md` (architecture
notes only) and `CHANGELOG.md` (an entry added after v0.1.6 is tagged, so it
does not land in v0.1.6's notes). A diff touching anything else fails review.

## Testing

New unit tests:

- `VFStatus` mappings for palette, pill and cockpit, including the voice-control
  lane, not-ready and review.
- Pill outcome classification and timing, with an injectable duration and
  clock: success, review, failure, reject, user cancel (no outcome), and a new
  capture during the outcome.
- Copy helpers: the cleanup-provider label in all three states; app display
  names, with a fallback to the bundle ID.
- Brand ink contrast: the WCAG ratio of `colorBrandInk` against the window
  background in light and dark appearances is at least 4.5:1.
- `DesignTokenLintTests`: scans `Views/**` for `Color(red:`, raw
  `.green`/`.orange`/`.red`/`.blue`/`.purple`/`.mint` used as colors,
  `.font(.system(size:`, `Color.gray.opacity` and `Color(nsColor:`, outside
  `VFDesignTokens.swift`. It turns the `CLAUDE.md` rule into a failing test.

Existing tests: `RecordingOverlayControllerTests` asserts the pill hides on
`.review` and `.idle`. Those tests construct the controller with an outcome
duration of zero, so their assertions keep their meaning; new tests cover the
linger. The other tests that touch view files cover types this track keeps
as they are (`ConfidenceBadge`, `PaletteSelectionModel`, `CockpitKeyRouter`,
and the Welcome-window routing in `WindowOpenRoutingTests`), so they keep
passing unchanged.

Images: `UISnapshotExportTests`, skipped unless `VOXFLOW_UI_SNAPSHOTS` names
an output folder (the pattern of the existing golden gates). It hosts each
surface in an offscreen window with a fixture `AppState`, in light and dark
appearances, and writes PNGs. It asserts nothing about pixels. It is the first
commit on the branch, so the "before" set is rendered from today's views and
the "after" set from the final ones. Offscreen rendering flattens materials
and glass; the PR labels the images accordingly.

## Acceptance criteria

1. `swift build` and `swift test` pass locally and in CI.
2. The token lint test passes: no color or font literal outside the tokens in
   `Views/**`, the pill included.
3. Every surface shows status through `VFStatusBadge` (symbol plus word).
4. With Reduce Motion on, nothing animates continuously: every repeating
   animation goes through `vfLive`, which has a unit test, and review confirms
   no view bypasses it.
5. The diff stays inside the allowlist, and for every control the reviewer can
   trace the same coordinator call before and after.
6. The PR carries before-and-after images for the pill (four states), palette
   (idle, review, recording, working), cockpit (empty, review), Dashboard,
   each Settings pane, Setup and Welcome, plus the Codex and Gemini review
   outcomes.
7. After the watch passes and before installing, the maintainer checks the
   live app: one dictation that inserts, one that is too short, one in the
   voice-control lane, the palette in each state, and the cockpit in review.

## Decisions for review

| # | Decision | Recommended |
|---|---|---|
| D1 | Approach | B, glass only on the pill and the ⌘K overlay |
| D2 | Pill shows each outcome for about 1.5 s | Yes |
| D3 | Listening color | Brand teal everywhere; red only for errors |
| D4 | Palette: drop Stats, collapse options into one row plus non-default chips | Yes |
| D5 | Settings panes: General, Apps, Voice, Models, Privacy, Advanced | Yes |
| D6 | Glossary above | Yes |
| D7 | Copy scope | View strings only; coordinator status lines stay as they are |
| D8 | Before-and-after images | Offscreen renders; or grant screenshot access for a live "before" set |

## Risks and counter-arguments

- **Merge conflicts during the watch.** A maintenance fix on `master` may touch
  `CommandPaletteView` or `SettingsView` while this branch has split them.
  Mitigation: the splits are mechanical move commits, separate from design
  commits, and the branch syncs with `master` before review.
- **Teal over red for listening.** Red is the conventional record color, and
  some users read teal as "idle". I still recommend teal: in a dictation app
  listening is the normal state, red already means error here, and the pill
  and the brand mark already use teal (the menu-bar glyph is a monochrome
  template and stays that way). Reject D3 if the red convention matters more.
- **Hiding options costs discoverability.** Tone is one click further away.
  The options row always shows the current values, and anything non-default
  that changes what a dictation does gets a chip.
- **The outcome state could mislead.** A misclassified outcome ("Not
  inserted" when text was inserted) would be worse than none. It is
  classified from `lastInsertResult` and the session-state transition only,
  tested case by case, and checked live before install. Rejecting D2 keeps
  today's behavior.
- **The pill stays on screen longer.** About 1.5 s more at the top center,
  click-through during the outcome, and replaced at once by a new capture.
- **Two looks.** macOS 26 gets glass on two surfaces; 14 and 15 keep today's
  materials. Acceptable because the fallback is the current look.
- **Images understate the result.** Offscreen renders flatten materials and
  glass, so the live check before install remains the real test.
- **Opportunity cost.** This is a large diff during a freeze. Approach A is the
  smaller alternative if the maintainer wants less.

## Amendments after approval (2026-10-31, during planning)

The spec was approved as written. Planning against the code surfaced four
refinements; the sections above keep their approved wording and these
override them.

1. **Pill outcome, case 4.** Rejects are not the only captures that end without
   inserting: built-in voice actions and voice-control commands do too, by
   design. Labeling them "Not inserted" would report a success as a failure.
   Case 4 therefore shows `statusLine` verbatim with a neutral info symbol and
   no "not inserted" claim; an empty status line shows no outcome. Case 1 (an
   insert that failed) keeps the "Not inserted" warning styling.
2. **An `inactive` status** ("Engine not needed", symbol `minus.circle`,
   secondary color) joins the vocabulary, for the engine when no workflow
   needs it. Today that state is a neutral dot.
3. **No spinner in status badges.** The working status uses the symbol
   `ellipsis.circle`, consistent with the pill and Apple's advice against
   labeled spinners.
4. **The cockpit says "Listening 1:23"**, not "Recording 1:23", so one word
   names the state everywhere. The Setup heading is "Set up VoxFlow" (sentence
   case, per the copy rules); its buttons stay title-style.

## Changes made during execution (2026-11-01)

Per-task and whole-branch reviews found places where the approved text, built
literally, would have hidden or misreported something. Each change below was a
recorded ruling; together they override the sections above.

- **Palette status line.** The header shows `statusLine` in every state. The
  coordinator appends lost-text warnings to it after an insert ("may be
  incomplete…", "limit reached"), and the approved design replaced it with the
  hotkey hint when ready. The hint now shows only before the first dictation.
- **Insert Again.** Offered only when the newest dictation produced the latest
  receipt's text, and it inserts or copies exactly that text (the matched
  cleanup variant). Never after a reject or a cockpit, translation, meeting or
  prompt insert.
- **Idle shortcuts.** ⏎ and ⌘R act only in the review card. An invisible idle ⏎
  that re-inserted old text was removed.
- **Options row.** Disabled while recording, transcribing or inserting (the
  workflow-mode switch restarts the engine). The cleanup menu appears only with
  the review card, labeled "Cleanup level"; the provider label keeps "Cleanup:".
- **Pill outcomes.** An `.error` ending shows "Not inserted" with the status
  line. A press too short to count and a cancelled transcription pass through
  transcribing, so they show their status line neutrally. When the reason is
  written late (an empty-capture reject), the pill keeps its working row for up
  to 3 seconds and then shows the reason with a full window; it follows at
  most one later change. VoiceOver can cancel from the pill. The pill's
  "Inserted" does not yet reflect the coordinator's "incomplete" warning; that
  needs a coordinator signal (Someday) and is a live check before install.
- **Provider labels.** Rows make no locality claim ("Ollama", not "Ollama
  (local)"); the backend decides locality from the URL and `:cloud` models.
- **Setup.** No summary line; engine readiness comes from live state only, so
  Start Engine shows whenever the engine is not ready. "Start Over" is "Reset
  Setup", so it is not confused with the palette's Start Over.
- **Images.** A rendering-only environment key makes the pill images use the
  material fallback, because Liquid Glass does not render offscreen.

## Excluded, to the Someday list after review

Each would need a signal from capture or a coordinator, or is a new feature:
a live input-level meter; an "arming" pill state until the first audio buffer
(the signal exists but only gates the start cue); two-step cancel for long
recordings; a native menu for the menu bar extra's default case; status-line
copy in the coordinators; routing view copies through `SystemClipboard.copy`
(the open spec 3 follow-up); a menu-bar glyph attention state; adding apps to
profiles from Settings; re-running cleanup on a past capture; and palette
history that survives a relaunch.
