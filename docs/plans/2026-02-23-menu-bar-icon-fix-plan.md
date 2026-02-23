# Menu Bar Icon Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the NSStatusItem (menu bar icon) survive activation policy transitions so it remains visible at all times.

**Architecture:** The NSStatusItem is created once in `MenuBarPanelController.init()` but gets silently deregistered when `NSApp.setActivationPolicy(.regular)` is called. Fix by (1) making `statusItem` mutable so it can be recreated, (2) adding a `refreshStatusItem()` method, (3) deferring initial panel setup until after the WindowGroup lifecycle settles, and (4) calling refresh after every policy revert.

**Tech Stack:** AppKit (NSStatusItem, NSStatusBar, NSPanel), SwiftUI, Combine

---

### Task 1: Make `statusItem` mutable and extract icon/wiring setup

**Files:**
- Modify: `Sources/VoxFlowApp/Services/MenuBarPanelController.swift:17,25-58`

**Step 1: Change `statusItem` from `let` to `var`**

In `MenuBarPanelController.swift`, line 17, change:

```swift
private nonisolated(unsafe) let statusItem: NSStatusItem
```

to:

```swift
private nonisolated(unsafe) var statusItem: NSStatusItem
```

**Step 2: Extract status item setup into a helper method**

Add a new private method `configureStatusItemButton()` that wires the icon and click action. This will be called from both `init()` and the new `refreshStatusItem()`.

After the `init` method (after line 59), add:

```swift
private func configureStatusItemButton(iconName: String) {
    if let button = statusItem.button {
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "VoxFlow")
        button.target = self
        button.action = #selector(statusItemClicked(_:))
    }
}
```

Then simplify the `init` to call it. Replace lines 27-30 and 57-58:

```swift
// In init, replace the statusItem setup block:
statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
configureStatusItemButton(iconName: iconName)
```

And remove the duplicate lines 57-58 (`statusItem.button?.target = self` / `statusItem.button?.action = ...`) since `configureStatusItemButton` handles that.

**Step 3: Store the current icon name for refresh**

Add a property to track the current icon so `refreshStatusItem()` can restore it:

```swift
private var currentIconName: String
```

Initialize it in `init`:

```swift
self.currentIconName = iconName
```

Update `updateIcon(systemName:)` to track it:

```swift
func updateIcon(systemName: String) {
    currentIconName = systemName
    statusItem.button?.image = NSImage(
        systemSymbolName: systemName,
        accessibilityDescription: "VoxFlow"
    )
}
```

**Step 4: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/MenuBarPanelController.swift
git commit -m "refactor: extract status item setup into configureStatusItemButton helper"
```

---

### Task 2: Add `refreshStatusItem()` method

**Files:**
- Modify: `Sources/VoxFlowApp/Services/MenuBarPanelController.swift`

**Step 1: Add the `refreshStatusItem()` method**

Add after `updateIcon(systemName:)`:

```swift
/// Re-register the status item with NSStatusBar after an activation policy change.
/// The old item's menu bar slot may have been invalidated by a
/// `.accessory` -> `.regular` -> `.accessory` policy round-trip.
func refreshStatusItem() {
    let wasOpen = panel.isVisible

    // Tear down old item
    removeClickMonitors()
    NSStatusBar.system.removeStatusItem(statusItem)

    // Create fresh item
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    configureStatusItemButton(iconName: currentIconName)

    // Restore panel state
    if wasOpen {
        open()
    }

    log.debug("Status item refreshed")
}
```

**Step 2: Update `deinit` to handle the mutable statusItem**

The `deinit` at line 138 already calls `NSStatusBar.system.removeStatusItem(statusItem)`. Since `statusItem` is now `var`, this still works — `deinit` reads the current value. No change needed, but verify the code compiles.

**Step 3: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 4: Commit**

```bash
git add Sources/VoxFlowApp/Services/MenuBarPanelController.swift
git commit -m "feat: add refreshStatusItem() to survive activation policy transitions"
```

---

### Task 3: Defer `setupMenuBarPanel()` in AppCoordinator

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:53-76` (init), `Sources/VoxFlowApp/AppCoordinator.swift:124-130` (appDidBecomeActive)

**Step 1: Remove `setupMenuBarPanel()` from `init()`**

In `AppCoordinator.swift`, line 75, delete the call:

```swift
// DELETE this line:
setupMenuBarPanel()
```

**Step 2: Add deferred setup via `applicationDidFinishLaunching` observer**

At the end of `init()` (where `setupMenuBarPanel()` was), add:

```swift
// Defer panel setup until after the app lifecycle settles.
// WindowGroup auto-opens a window which triggers activateForWindow() →
// setActivationPolicy(.regular). Creating the status item before that
// would cause macOS to tear down its menu bar slot during the policy change.
NotificationCenter.default.addObserver(
    forName: NSApplication.didFinishLaunchingNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    // Additional delay ensures the WindowGroup window + activation policy
    // round-trip has fully completed before we create the status item.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        guard let self, self.menuBarPanel == nil else { return }
        self.setupMenuBarPanel()
        self.log.info("Menu bar panel setup (deferred)")
    }
}
```

**Step 3: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 4: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift
git commit -m "fix: defer setupMenuBarPanel to after WindowGroup activation policy settles"
```

---

### Task 4: Refresh status item after policy revert

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:1058-1071` (checkAndRevertActivationPolicy)

**Step 1: Add refresh call after policy revert**

In `checkAndRevertActivationPolicy()`, after `NSApp.setActivationPolicy(.accessory)` (line 1065), add the refresh:

```swift
private func checkAndRevertActivationPolicy() {
    let hasManagedWindows = NSApp.windows.contains { window in
        window.isVisible
        && window.level == .normal
        && window.className != "NSStatusBarWindow"
    }
    if !hasManagedWindows {
        NSApp.setActivationPolicy(.accessory)
        // Re-register status item — the .regular -> .accessory round-trip
        // may have invalidated its menu bar slot.
        menuBarPanel?.refreshStatusItem()
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowCloseObserver = nil
        }
    }
}
```

**Step 2: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift
git commit -m "fix: refresh status item after activation policy reverts to .accessory"
```

---

### Task 5: Suppress initial main window auto-open

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:61-63` (deferred showMainWindow in init)

The `init()` at line 61-63 schedules `showMainWindow()` after 0.4s, which calls `activateForWindow()` → `.regular` policy. Since VoxFlow is a menu-bar-first app, we should not auto-open the main window on launch. The user opens it via the panel's Dashboard button.

**Step 1: Remove the auto-open**

Delete lines 61-63:

```swift
// DELETE these lines:
DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
    self?.showMainWindow()
}
```

**Step 2: Also update `appDidBecomeActive()`**

In `appDidBecomeActive()` (line 124-130), the call to `showMainWindowIfNeeded()` triggers the same policy toggle. For a menu-bar-first app, becoming active should not force-open a window. Change it to only configure hotkeys and check readiness:

```swift
func appDidBecomeActive() {
    configureHotkeysIfNeeded()
    if !state.backendReadyForDictation {
        beginWarmupMonitoring()
    }
}
```

**Step 3: Build and verify**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 4: Run tests**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed 219 tests, with 0 failures`

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift
git commit -m "fix: stop auto-opening main window on launch — menu bar is primary UI"
```

---

### Task 6: Full integration test — reinstall and verify

**Step 1: Kill all running instances**

```bash
pkill -f VoxFlowLocal 2>/dev/null; pkill -f "server.py" 2>/dev/null; lsof -t -iTCP:8765 2>/dev/null | xargs kill 2>/dev/null; sleep 1
```

**Step 2: Reinstall**

```bash
./scripts/reinstall_and_launch.sh 2>&1 | tail -10
```

**Step 3: Wait for WhisperKit model load (~90s)**

```bash
sleep 95 && /usr/bin/log show --predicate 'subsystem == "local.voxflow.app"' --last 2m --style compact --info 2>&1 | grep -E "loaded|Menu bar|refreshed|deferred"
```

Expected: See "Menu bar panel setup (deferred)" and "WhisperKit model loaded successfully"

**Step 4: Verify icon is visible**

Look for the mic icon in the macOS menu bar. Click it — the command palette panel should open.

**Step 5: Verify dictation works**

Use the hotkey to dictate. Text should auto-insert (insertBehavior is currently .autoInsertLight).

**Step 6: Verify policy round-trip resilience**

Open the Dashboard window (Cmd+2 from the panel). Close it. Verify the menu bar icon is still visible.

**Step 7: Update progress.txt and commit**

```bash
git add progress.txt
git commit -m "docs: update progress.txt with menu bar icon fix"
```
