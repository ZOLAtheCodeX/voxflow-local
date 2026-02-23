# Menu Bar Icon Fix — Design

## Problem

The NSStatusItem (menu bar icon) disappears after launch. Root cause: `setupMenuBarPanel()` creates the status item in `AppCoordinator.init()`, then `activateForWindow()` calls `NSApp.setActivationPolicy(.regular)` when the WindowGroup auto-opens its main window. macOS tears down the status item's menu bar slot during the `.accessory` → `.regular` transition. When windows close and policy reverts to `.accessory`, the status item object survives in memory but is no longer registered in the menu bar.

## Approach

Fix the activation policy interaction rather than replacing the panel system. The current `NSPanel` with `.nonactivatingPanel` provides two features that SwiftUI's `MenuBarExtra` cannot: programmatic auto-open on `.review` state, and stay-open behavior when the user clicks into a text field during review.

### Alternatives Considered

- **Pure MenuBarExtra:** Cleanest code but loses auto-open and stay-open — would re-introduce the "nothing happens" silent failure under `.alwaysReview` mode.
- **MenuBarExtra + NSPanel hybrid:** Most complex, two systems managing overlapping concerns.

## Changes

### 1. MenuBarPanelController.swift — Add `refreshStatusItem()`

New method that:
- Removes the old status item from `NSStatusBar`
- Creates a new status item with the same configuration
- Re-wires the button target/action
- Re-applies the current icon
- Re-installs click monitors if the panel is open

### 2. AppCoordinator.swift — Defer panel setup

Move `setupMenuBarPanel()` from `init()` to after the initial WindowGroup lifecycle settles. Options:
- Call at end of `warmup()` (after model load)
- Use `DispatchQueue.main.asyncAfter` with sufficient delay
- Observe `applicationDidFinishLaunching` notification

### 3. AppCoordinator.swift — Refresh after policy revert

In `checkAndRevertActivationPolicy()`, after `NSApp.setActivationPolicy(.accessory)`, call `menuBarPanel?.refreshStatusItem()` to re-register the icon.

### 4. VoxFlowLocalApp.swift — Suppress initial WindowGroup auto-open (optional)

If the WindowGroup auto-opening still causes a policy round-trip before the deferred panel setup, consider hiding the main window on launch or making it conditional.

## Edge Cases

- **Multiple policy transitions:** Each `.regular` → `.accessory` revert triggers a refresh. Icon survives any number of dashboard/settings open/close cycles.
- **Icon state:** `refreshStatusItem()` reads current state to apply the correct icon (idle=mic.fill, recording=record.circle.fill, etc.).
- **Click monitors:** Must be re-installed after refresh since they reference the old status item's window.
- **Auto-open on review:** Unaffected — uses `menuBarPanel?.open()` which operates on the NSPanel, not the status item.

## Testing

Manual verification:
1. Launch app — icon appears in menu bar
2. Open dashboard, close it — icon still present
3. Open settings, close them — icon still present
4. Dictate 3x — icon transitions correctly (mic → recording → waveform → idle)
5. Set insertBehavior to .alwaysReview, dictate — panel auto-opens with review card

No new unit tests — this is AppKit lifecycle behavior.

## Files Affected

- `Sources/VoxFlowApp/Services/MenuBarPanelController.swift` — add `refreshStatusItem()`
- `Sources/VoxFlowApp/AppCoordinator.swift` — defer setup, refresh after policy revert
- `Sources/VoxFlowApp/VoxFlowLocalApp.swift` — possibly suppress initial window
