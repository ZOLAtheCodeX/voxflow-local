# Focus Bug Fix — Full Agent Mode Design

> VoxFlow Local — 2026-02-22
> Status: Approved

## Problem

When VoxFlow's menu bar palette is open during dictation, it steals focus from the target app. `simulatePaste` sends Cmd+V to VoxFlow itself instead of the intended target.

### Root Causes (three compounding layers)

1. **No target snapshot at `startCapture()`** — the app the user was typing in is never captured at hotkey-press time. `AccessibilityInsertService.insert()` reads `frontmostApplication` after the async pipeline completes, by which point VoxFlow is frontmost.

2. **`menuBarExtraStyle(.window)` activates VoxFlow** — SwiftUI's built-in MenuBarExtra creates an NSPanel that activates the VoxFlow process when opened. `FocusContextMonitor` overwrites `state.focusTarget` to reflect VoxFlow's own UI.

3. **`LSUIElement = false`** — VoxFlow is a full-citizen foreground app (Dock icon, app switcher). Every window interaction makes it frontmost.

## Approach: Full Agent Mode (C)

Three coordinated fixes applied together.

---

## Fix 1: Target Snapshot at Record Start

### Changes

**`AppCoordinator`**
- Add `capturedTargetApp: NSRunningApplication?` property.
- In `startCapture()`: set `capturedTargetApp = NSWorkspace.shared.frontmostApplication` before audio capture begins.
- Clear `capturedTargetApp = nil` in `state.resetForNewCapture()` or when session returns to `.idle`.
- Thread `capturedTargetApp` through `processDictation()` → `insertText()` → `insertService.insert(text:targetApp:)`.

**`FocusContextMonitor`**
- In `poll()`: skip updating `state.focusTarget` when `sessionState` is `.recording`, `.transcribing`, or `.inserting`. The monitor keeps running (for UI status) but does not overwrite the frozen target.
- Accept a closure or check `sessionState` to determine freeze condition.

**`AccessibilityInsertService`**
- Add overload: `insert(text: String, targetApp: NSRunningApplication?) -> InsertResult`.
- `simulatePaste` uses the passed `targetApp` for activation instead of reading `frontmostApplication`.
- `insertDirectly` still uses system-wide AX (which reads whatever is focused), but with the non-activating panel fix, this will point to the correct app.

**`TextInsertionCoordinator`**
- Update `insertText(_:statusSuffix:)` and `insertCurrentText()` to accept and forward `targetApp`.

### Data Flow

```
Fn press → startCapture()
  → capturedTargetApp = NSWorkspace.shared.frontmostApplication
  → AudioCaptureService.startCapture()
  → ... recording ...
Fn release → finishCaptureAndTranscribe()
  → BackendAPIClient.transcribe() [async]
  → processDictation() / processTranslation() / processMeeting()
    → insertText(text, targetApp: capturedTargetApp)
      → insertService.insert(text:, targetApp: capturedTargetApp)
        → simulatePaste activates capturedTargetApp
        → Cmd+V goes to the correct app
```

---

## Fix 2: Non-Activating Menu Bar Panel

Replace SwiftUI's `MenuBarExtra(.window)` with a custom `NSPanel`-backed implementation.

### New: `MenuBarPanelController`

An `@MainActor` class managing:
- `NSStatusItem` with click handler (toggle panel)
- `NSPanel` with `styleMask: [.nonactivatingPanel, .borderless]`, `level: .floating`
- `NSHostingView` wrapping existing `CommandPaletteView`
- Panel positioning below the status item
- Click-outside-to-dismiss via `NSEvent.addGlobalMonitorForEvents`

### Panel Configuration

```swift
panel.styleMask = [.nonactivatingPanel, .borderless]
panel.level = .floating
panel.becomesKeyOnlyIfNeeded = true
panel.hidesOnDeactivate = false
panel.isMovableByWindowBackground = false
panel.hasShadow = true
panel.backgroundColor = .clear  // SwiftUI handles background
```

### VoxFlowLocalApp Changes

- Remove `MenuBarExtra { ... }` scene entirely.
- `MenuBarPanelController` created and held by `AppCoordinator` (owns the status item lifecycle).
- Menu bar icon updates driven by observing `state.sessionState` (same icon logic, just on the status item button).

---

## Fix 3: LSUIElement Agent Mode

### Info.plist

Set `LSUIElement` to `true`. App starts as an accessory (no Dock, no app switcher).

### Dynamic Activation Policy

When user explicitly opens a managed window (Dashboard, Setup, Settings, Main):
```swift
NSApp.setActivationPolicy(.regular)
NSApp.activate(ignoringOtherApps: true)
```

When the last managed window closes:
```swift
NSApp.setActivationPolicy(.accessory)
```

Monitor via `NSWindow.willCloseNotification` on all managed windows.

### NSApp.activate() Audit

| Call Site | Current | After Fix |
|---|---|---|
| `showMainWindowIfNeeded(force: true)` | `NSApp.activate(...)` | Keep (user-initiated) + dynamic policy |
| `showMainWindowIfNeeded(force: false)` | `NSApp.activate(...)` | Remove |
| `showMainWindowIfNeeded` (new window) | `NSApp.activate(...)` | Keep + dynamic policy |
| `openSettings()` | `NSApp.activate(...)` | Keep + dynamic policy |
| `activateAndOpenWindow()` | `NSApp.activate(...)` | Keep + dynamic policy |

All remaining `activate()` calls go through a gated helper that also sets `.regular` policy.

---

## Testing

### Unit Tests

1. **`FocusContextMonitorTests`** — verify poll() skips `focusTarget` update during `.recording` / `.transcribing` / `.inserting`.
2. **`AccessibilityInsertServiceTests`** — verify `insert(text:targetApp:)` uses passed target, not `frontmostApplication`.
3. **`AppCoordinatorTests`** — verify `startCapture()` captures target; verify it flows through to insertion.

### Manual Testing Protocol

1. Open palette → Fn dictate → text lands in target app (not VoxFlow).
2. Open Dashboard → dictate → target is correct.
3. Palette visible → VoxFlow NOT in Dock, NOT in Cmd+Tab.
4. Open Dashboard → VoxFlow appears in Dock → close → disappears.
5. Target app quit during transcription → graceful clipboard fallback.
6. User switches apps during recording → frozen snapshot still targets original app (correct for dictation use case).

---

## Files Modified

| File | Change |
|---|---|
| `Sources/VoxFlowApp/AppCoordinator.swift` | `capturedTargetApp` snapshot, threading, activation policy helpers |
| `Sources/VoxFlowApp/Services/AccessibilityInsertService.swift` | `insert(text:targetApp:)` overload |
| `Sources/VoxFlowApp/Services/TextInsertionCoordinator.swift` | Thread `targetApp` parameter |
| `Sources/VoxFlowApp/Services/FocusContextMonitor.swift` | Freeze during active session |
| `Sources/VoxFlowApp/VoxFlowLocalApp.swift` | Remove MenuBarExtra, wire MenuBarPanelController |
| `Sources/VoxFlowApp/Services/MenuBarPanelController.swift` | **New** — NSPanel + NSStatusItem |
| `dist/VoxFlow.app/Contents/Info.plist` | `LSUIElement = true` |
| `scripts/build_app_bundle.sh` | Ensure `LSUIElement = true` in generated plist |
| `Tests/VoxFlowTests/FocusContextMonitorTests.swift` | New tests |
| `Tests/VoxFlowTests/AccessibilityInsertServiceTests.swift` | New tests |

## Risks

- **NSPanel + SwiftUI hosting:** Well-documented pattern but needs testing with VoxFlow's specific view hierarchy. SwiftUI controls inside an NSHostingView in a non-activating panel may have subtle keyboard event issues.
- **Dynamic activation policy:** Toggling between `.regular` and `.accessory` is well-supported but can cause a brief visual flash in the Dock. Mitigate by toggling policy before showing the window.
- **Frozen target during review mode:** If `alwaysReview` is set and user clicks "Insert" button in the palette, the frozen target is still correct because the panel is non-activating.
