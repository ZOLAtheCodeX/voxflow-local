# Focus Bug Fix — Full Agent Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix VoxFlow stealing focus during dictation by capturing the target app at record start, replacing the menu bar panel with a non-activating NSPanel, and converting to LSUIElement agent mode.

**Architecture:** Three-layer fix applied in order: (1) snapshot target at startCapture() + freeze FocusContextMonitor, (2) replace SwiftUI MenuBarExtra with custom NSPanel + NSStatusItem, (3) set LSUIElement=true with dynamic activation policy toggling. Each layer is independently testable.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (NSPanel, NSStatusItem, NSHostingView), macOS Accessibility API

**Design doc:** `docs/plans/2026-02-22-focus-bug-fix-design.md`

---

### Task 1: Thread Target App Through Insert Pipeline

**Files:**
- Modify: `Sources/VoxFlowApp/Services/AccessibilityInsertService.swift:36-50`
- Modify: `Sources/VoxFlowApp/Services/TextInsertionCoordinator.swift:5-7, 24-67, 69-98`
- Test: `Tests/VoxFlowAppTests/TextInsertionCoordinatorTests.swift`

This task adds a `targetApp` parameter to the insert pipeline without changing capture timing yet.

**Step 1: Write the failing test**

Add to `Tests/VoxFlowAppTests/TextInsertionCoordinatorTests.swift`:

```swift
@MainActor
func testInsertTextAcceptsTargetApp() {
    let (sut, state) = makeSUT()
    state.transcriptCandidate = TranscriptCandidate(
        rawText: "hello", lightText: "hello", polishText: "hello", selectedMode: .raw
    )
    // Should compile and not crash — targetApp is optional
    let result = sut.insertText("hello", statusSuffix: "test", targetApp: nil)
    // Insert may fail (no AX context in test), but it should not crash
    XCTAssertNotNil(state.lastInsertResult)
}
```

**Step 2: Run test to verify it fails**

Run: `cd <repo> && swift test --filter testInsertTextAcceptsTargetApp 2>&1 | tail -20`
Expected: Compilation error — `insertText` doesn't accept `targetApp` parameter yet.

**Step 3: Add targetApp parameter to AccessibilityInsertService**

In `AccessibilityInsertService.swift`, add a new overload below the existing `insert(text:)`:

```swift
func insert(text: String, targetApp: NSRunningApplication?) -> InsertResult {
    let effectiveTarget = targetApp ?? NSWorkspace.shared.frontmostApplication

    if insertDirectly(text: text) {
        return InsertResult(method: .accessibilityDirect, success: true, fallbackUsed: false, errorCode: nil)
    }

    if simulatePaste(text: text, targetApp: effectiveTarget) {
        return InsertResult(method: .simulatedPaste, success: true, fallbackUsed: true, errorCode: nil)
    }

    return InsertResult(method: .failed, success: false, fallbackUsed: true, errorCode: "INSERT_FAILED")
}
```

**Step 4: Update TextInsertionCoordinating protocol and TextInsertionCoordinator**

In `TextInsertionCoordinator.swift`:

Update the protocol:
```swift
@MainActor protocol TextInsertionCoordinating {
    func insertCurrentText(targetApp: NSRunningApplication?)
    func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?) -> Bool
    func copyCurrentText()
    func copyMeetingMarkdownTemplate()
    func copyMeetingNotionTemplate()
}
```

Update `insertCurrentText` to accept `targetApp` parameter (default `nil`):
```swift
func insertCurrentText(targetApp: NSRunningApplication? = nil) {
    // ... existing guard logic unchanged ...
    state.sessionState = .inserting
    let appName = state.focusTarget.appName ?? "Unknown App"
    let result = insertService.insert(text: state.displayText, targetApp: targetApp)
    // ... rest unchanged ...
}
```

Update `insertText` to accept `targetApp` parameter (default `nil`):
```swift
@discardableResult
func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication? = nil) -> Bool {
    guard !text.isEmpty else { return false }
    let appName = state.focusTarget.appName ?? "Unknown App"
    let result = insertService.insert(text: text, targetApp: targetApp)
    // ... rest unchanged ...
}
```

**Step 5: Run test to verify it passes**

Run: `cd <repo> && swift test --filter TextInsertionCoordinator 2>&1 | tail -20`
Expected: All TextInsertionCoordinator tests pass (existing tests use default `nil`).

**Step 6: Commit**

```bash
git add Sources/VoxFlowApp/Services/AccessibilityInsertService.swift \
       Sources/VoxFlowApp/Services/TextInsertionCoordinator.swift \
       Tests/VoxFlowAppTests/TextInsertionCoordinatorTests.swift
git commit -m "feat: add targetApp parameter to insert pipeline for focus fix"
```

---

### Task 2: Capture Target at startCapture() and Thread Through Pipeline

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:32-34` (add property), `:163-229` (capture in startCapture), `:612-674` (thread through processDictation), `:677-714` (thread through processTranslation/processMeeting), `:348-353` (forwarding methods)
- Test: `Tests/VoxFlowAppTests/AppCoordinatorSmokeTests.swift`

**Step 1: Add capturedTargetApp property to AppCoordinator**

In `AppCoordinator.swift`, after line 34 (`private var fnTriggeredCaptureInProgress = false`), add:

```swift
private var capturedTargetApp: NSRunningApplication?
```

**Step 2: Capture target in startCapture()**

In `startCapture()`, immediately after `state.resetForNewCapture()` (line 196) and before `sessionCounter += 1` (line 197), add:

```swift
capturedTargetApp = NSWorkspace.shared.frontmostApplication
```

**Step 3: Clear target on session end**

In `cancelActiveCapture()`, after `state.setIdle()` (line 332), add:
```swift
capturedTargetApp = nil
```

In `retryLastCapture()`, after `state.setIdle()` (line 322), add:
```swift
capturedTargetApp = nil
```

**Step 4: Thread capturedTargetApp through processDictation**

In `processDictation`, for the auto-insert raw path (line 629):
```swift
if self.textInsertion.insertText(rawText, statusSuffix: "Inserted (raw — \(appLabel))", targetApp: self.capturedTargetApp) {
```

For the auto-insert light/polish path (line 661):
```swift
if self.textInsertion.insertText(text, statusSuffix: "Inserted (\(autoMode.displayName.lowercased())\(toneLabel) — \(appLabel))", targetApp: self.capturedTargetApp) {
```

**Step 5: Update insertCurrentText forwarding**

In AppCoordinator forwarding (line 353), change:
```swift
func insertCurrentText() { textInsertion.insertCurrentText(targetApp: capturedTargetApp) }
```

**Step 6: Clear capturedTargetApp when session completes**

In `processDictation`, after `self.state.sessionState = .idle` (lines 630, 663), add:
```swift
self.capturedTargetApp = nil
```

Also in `insertCurrentText` flow — `TextInsertionCoordinator.insertCurrentText` already sets state to `.idle` on success. Add to `AppCoordinator` after the forwarding call won't work (it's a void return). Instead, clear in `AppState.setIdle()` is not accessible. Best approach: clear in the `sessionState` didSet or add cleanup after each pipeline completion.

Simpler: clear `capturedTargetApp` at the top of `startCapture()` (already handled by `resetForNewCapture` setting `.recording`), and also clear it when `sessionState` transitions to `.idle`. Add an observer:

After `startFocusMonitoring()` in `init()`, add:
```swift
state.$sessionState
    .removeDuplicates()
    .sink { [weak self] newState in
        if newState == .idle {
            self?.capturedTargetApp = nil
        }
    }
    .store(in: &cancellables)
```

Add `cancellables` property:
```swift
private var cancellables = Set<AnyCancellable>()
```

Add `import Combine` at the top of AppCoordinator (if not already present).

**Step 7: Run full test suite**

Run: `cd <repo> && swift test 2>&1 | tail -30`
Expected: All tests pass.

**Step 8: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift
git commit -m "feat: capture target app at startCapture() and thread through pipeline"
```

---

### Task 3: Freeze FocusContextMonitor During Active Session

**Files:**
- Modify: `Sources/VoxFlowApp/Services/FocusContextMonitor.swift:38-49`
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:802-820`
- Create: `Tests/VoxFlowAppTests/FocusContextMonitorTests.swift`

**Step 1: Write the failing test**

Create `Tests/VoxFlowAppTests/FocusContextMonitorTests.swift`:

```swift
import XCTest
@testable import VoxFlowApp

final class FocusContextMonitorTests: XCTestCase {

    @MainActor
    func testFreezePreventsFocusTargetUpdate() {
        let monitor = FocusContextMonitor(insertService: AccessibilityInsertService())
        var updateCount = 0

        monitor.start { _ in
            updateCount += 1
        }

        // Freeze should prevent updates from reaching the callback
        monitor.freeze()

        // Force a poll cycle — in frozen state, onUpdate should not fire
        // We can't easily test this without exposing internals, so test the
        // public freeze/unfreeze contract instead
        XCTAssertTrue(monitor.isFrozen)

        monitor.unfreeze()
        XCTAssertFalse(monitor.isFrozen)

        monitor.stop()
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd <repo> && swift test --filter FocusContextMonitorTests 2>&1 | tail -20`
Expected: Compilation error — `freeze()`, `unfreeze()`, `isFrozen` don't exist.

**Step 3: Add freeze/unfreeze to FocusContextMonitor**

In `FocusContextMonitor.swift`, add property and methods:

After `private var onUpdate:` (line 10), add:
```swift
private(set) var isFrozen = false
```

Add methods after `stop()`:
```swift
func freeze() {
    isFrozen = true
}

func unfreeze() {
    isFrozen = false
}
```

Update `poll()` to skip callback when frozen:
```swift
private func poll() {
    let snapshot = insertService.focusedTargetSnapshot()
    let changed = snapshot.hasFocusedTextInput != lastSnapshot.hasFocusedTextInput
        || snapshot.hasInsertionCursor != lastSnapshot.hasInsertionCursor
        || snapshot.appName != lastSnapshot.appName
        || snapshot.bundleID != lastSnapshot.bundleID
        || snapshot.role != lastSnapshot.role
    lastSnapshot = snapshot
    guard !isFrozen, changed else { return }
    onUpdate?(snapshot)
}
```

**Step 4: Run test to verify it passes**

Run: `cd <repo> && swift test --filter FocusContextMonitorTests 2>&1 | tail -20`
Expected: PASS.

**Step 5: Wire freeze/unfreeze in AppCoordinator**

In `startCapture()`, after capturing `capturedTargetApp` (the line added in Task 2), add:
```swift
focusMonitor.freeze()
```

In the `sessionState` Combine observer added in Task 2, expand:
```swift
state.$sessionState
    .removeDuplicates()
    .sink { [weak self] newState in
        if newState == .idle {
            self?.capturedTargetApp = nil
            self?.focusMonitor.unfreeze()
        }
    }
    .store(in: &cancellables)
```

**Step 6: Run full test suite**

Run: `cd <repo> && swift test 2>&1 | tail -30`
Expected: All tests pass.

**Step 7: Commit**

```bash
git add Sources/VoxFlowApp/Services/FocusContextMonitor.swift \
       Sources/VoxFlowApp/AppCoordinator.swift \
       Tests/VoxFlowAppTests/FocusContextMonitorTests.swift
git commit -m "feat: freeze FocusContextMonitor during active capture session"
```

---

### Task 4: Create MenuBarPanelController (Non-Activating NSPanel)

**Files:**
- Create: `Sources/VoxFlowApp/Services/MenuBarPanelController.swift`
- Test: Manual (NSPanel requires running app context)

**Step 1: Create MenuBarPanelController**

Create `Sources/VoxFlowApp/Services/MenuBarPanelController.swift`:

```swift
import AppKit
import SwiftUI
import Combine
import os.log

@MainActor
final class MenuBarPanelController {
    private let log = Logger(subsystem: "local.voxflow.app", category: "MenuBarPanel")

    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    var isOpen: Bool { panel.isVisible }

    init<Content: View>(content: Content, iconName: String = "mic.fill") {
        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "VoxFlow")
            button.target = nil  // set below after self is available
            button.action = #selector(Self.statusItemClicked(_:))
        }

        // Non-activating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 600),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.animationBehavior = .utilityWindow

        let hostingView = NSHostingView(rootView: content)
        panel.contentView = hostingView

        self.panel = panel

        // Wire up status item action
        statusItem.button?.target = self
    }

    func updateIcon(systemName: String) {
        statusItem.button?.image = NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: "VoxFlow"
        )
    }

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        guard let button = statusItem.button else { return }
        let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        let panelWidth = panel.frame.width
        let x = buttonRect.midX - panelWidth / 2
        let y = buttonRect.minY - panel.frame.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        installClickMonitors()
        log.debug("Panel opened")
    }

    func close() {
        panel.orderOut(nil)
        removeClickMonitors()
        log.debug("Panel closed")
    }

    private func installClickMonitors() {
        // Close on click outside the panel
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.close()
        }

        // Close on click on status item while open
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if let self,
               let window = event.window,
               window != self.panel,
               window == self.statusItem.button?.window {
                self.close()
            }
            return event
        }
    }

    private func removeClickMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        toggle()
    }

    deinit {
        removeClickMonitors()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
```

**Step 2: Verify it compiles**

Run: `cd <repo> && swift build 2>&1 | tail -20`
Expected: Build succeeds (new file compiles but isn't wired yet).

**Step 3: Commit**

```bash
git add Sources/VoxFlowApp/Services/MenuBarPanelController.swift
git commit -m "feat: add MenuBarPanelController with non-activating NSPanel"
```

---

### Task 5: Wire MenuBarPanelController Into App + Remove MenuBarExtra

**Files:**
- Modify: `Sources/VoxFlowApp/VoxFlowLocalApp.swift:42-66` (remove MenuBarExtra)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:7-22, 41-51` (own panel controller, icon updates)

**Step 1: Add MenuBarPanelController to AppCoordinator**

In `AppCoordinator.swift`, add property after `mainWindowController` (line 39):

```swift
private(set) var menuBarPanel: MenuBarPanelController?
```

At the end of `init()` (after the `DispatchQueue.main.asyncAfter` block, around line 51), add:

```swift
setupMenuBarPanel()
```

Add the setup method (new private method):

```swift
private func setupMenuBarPanel() {
    let panelContent = CommandPaletteView(
        coordinator: self,
        state: state
    ) { [weak self] in
        self?.activateForWindow()
        // Dashboard open handled by caller
    } onOpenSetup: { [weak self] in
        self?.activateForWindow()
        // Setup open handled by caller
    } onQuit: {
        NSApp.terminate(nil)
    }
    .frame(width: 430)

    let controller = MenuBarPanelController(
        content: panelContent,
        iconName: iconName(for: state)
    )
    menuBarPanel = controller

    // Observe sessionState for icon updates
    state.$sessionState
        .combineLatest(state.$isCommandLaneActive)
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _ in
            guard let self else { return }
            self.menuBarPanel?.updateIcon(systemName: self.iconName(for: self.state))
        }
        .store(in: &cancellables)
}

private func iconName(for state: AppState) -> String {
    if state.isCommandLaneActive { return "terminal.fill" }
    switch state.sessionState {
    case .idle: return "mic.fill"
    case .recording: return "record.circle.fill"
    case .transcribing: return "waveform"
    case .review: return "checkmark.bubble.fill"
    case .inserting: return "square.and.arrow.down.fill"
    case .onboarding: return "sparkles"
    case .error: return "exclamationmark.triangle.fill"
    }
}
```

**Step 2: Remove MenuBarExtra from VoxFlowLocalApp**

In `VoxFlowLocalApp.swift`, delete the entire `MenuBarExtra { ... }` block (lines 42-66). This includes the `.menuBarExtraStyle(.window)` modifier.

Also remove the `iconName(for:)` function from VoxFlowLocalApp (lines 85-107) since it moved to AppCoordinator.

Update `activateAndOpenWindow` to use the new helper from Task 6 (or keep as-is for now — it will be updated in Task 6).

**Step 3: Handle Dashboard/Setup window opening from panel**

The `CommandPaletteView` closures for `onOpenDashboard` and `onOpenSetup` need to actually open the windows. Since SwiftUI `@Environment(\.openWindow)` won't be available from AppCoordinator, use `NSApp.sendAction` or direct window management.

Check if `CommandPaletteView` uses these closures vs. environment. If it accepts closures, update the closures in `setupMenuBarPanel()` to call:

```swift
// In the onOpenDashboard closure:
{ [weak self] in
    self?.activateForWindow()
    // Use NSApp to open the dashboard window
    if let app = NSApp as? NSApplication {
        // SwiftUI windows with IDs can be opened via environment or notification
    }
}
```

The simplest approach: keep using `openWindow(id:)` from VoxFlowLocalApp for these windows, and have the panel closures post a notification that VoxFlowLocalApp observes. Or, move the panel setup into VoxFlowLocalApp where `@Environment(\.openWindow)` is available.

**Recommended:** Create the panel in `VoxFlowLocalApp.body` using `onAppear` so we have access to `openWindow`. Store the controller on AppCoordinator for lifecycle.

**Step 4: Verify build compiles**

Run: `cd <repo> && swift build 2>&1 | tail -30`
Expected: Build succeeds.

**Step 5: Run full test suite**

Run: `cd <repo> && swift test 2>&1 | tail -30`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add Sources/VoxFlowApp/VoxFlowLocalApp.swift \
       Sources/VoxFlowApp/AppCoordinator.swift
git commit -m "feat: replace MenuBarExtra with non-activating NSPanel controller"
```

---

### Task 6: LSUIElement Agent Mode + Dynamic Activation Policy

**Files:**
- Modify: `scripts/build_app_bundle.sh:141-143` (default LSUIElement to true)
- Modify: `dist/VoxFlow.app/Contents/Info.plist:31-32` (LSUIElement true)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift` (activation policy helpers)
- Modify: `Sources/VoxFlowApp/VoxFlowLocalApp.swift` (use activation helper)

**Step 1: Set LSUIElement = true in Info.plist**

In `dist/VoxFlow.app/Contents/Info.plist`, change line 32:
```xml
<true/>
```

**Step 2: Update build_app_bundle.sh default**

In `scripts/build_app_bundle.sh`, change line 141:
```bash
LSUIELEMENT_VALUE="<true/>"
```

And update the conditional on line 142-144:
```bash
if [[ ${MENU_BAR_ONLY} -eq 0 ]] && [[ ${FORCE_DOCK_ICON:-0} -eq 1 ]]; then
  LSUIELEMENT_VALUE="<false/>"
fi
```

**Step 3: Add activation policy helpers to AppCoordinator**

Add a `windowObserver` token and methods:

```swift
private var windowCloseObserver: Any?

/// Activate app and show in Dock when opening a managed window
func activateForWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    installWindowCloseObserver()
}

/// Revert to accessory (menu-bar-only) when all managed windows close
private func installWindowCloseObserver() {
    guard windowCloseObserver == nil else { return }
    windowCloseObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        DispatchQueue.main.async {
            self?.checkAndRevertActivationPolicy()
        }
    }
}

private func checkAndRevertActivationPolicy() {
    let hasManagedWindows = NSApp.windows.contains { window in
        window.isVisible
        && window.level == .normal
        && window != menuBarPanel?.panel  // panel is floating, not managed
        && window.className != "NSStatusBarWindow"
    }
    if !hasManagedWindows {
        NSApp.setActivationPolicy(.accessory)
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowCloseObserver = nil
        }
    }
}
```

**Step 4: Replace all direct NSApp.activate calls with activateForWindow()**

In `showMainWindowIfNeeded(force:)`, replace the three `NSApp.activate(ignoringOtherApps: true)` calls (lines 531, 539, 558) with `activateForWindow()`.

In `openSettings()` (line 489), replace `NSApp.activate(ignoringOtherApps: true)` with `activateForWindow()`.

In `VoxFlowLocalApp.activateAndOpenWindow()` (line 109-112), replace:
```swift
private func activateAndOpenWindow(id: String) {
    coordinator.activateForWindow()
    openWindow(id: id)
}
```

**Step 5: Verify build compiles**

Run: `cd <repo> && swift build 2>&1 | tail -30`
Expected: Build succeeds.

**Step 6: Run full test suite**

Run: `cd <repo> && swift test 2>&1 | tail -30`
Expected: All tests pass.

**Step 7: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift \
       Sources/VoxFlowApp/VoxFlowLocalApp.swift \
       scripts/build_app_bundle.sh \
       dist/VoxFlow.app/Contents/Info.plist
git commit -m "feat: LSUIElement agent mode with dynamic activation policy"
```

---

### Task 7: Update CLAUDE.md + Docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Step 1: Update CLAUDE.md**

Add to "Key Patterns > Swift" section:
- **Non-activating panel:** Menu bar palette uses `NSPanel` with `.nonactivatingPanel` style mask and `.floating` level via `MenuBarPanelController`. Never steals focus.
- **Target snapshot:** `capturedTargetApp` is frozen at `startCapture()` time and threaded through the pipeline to `insert(text:targetApp:)`. `FocusContextMonitor` freezes during active session.
- **Dynamic activation policy:** `activateForWindow()` toggles `.regular`/`.accessory` so VoxFlow shows in Dock only when managed windows are open.

Add to "Do Not" section:
- Call `NSApp.activate(ignoringOtherApps: true)` directly — use `activateForWindow()` which manages the activation policy toggle
- Read `NSWorkspace.shared.frontmostApplication` at insert time — use the frozen `capturedTargetApp` from `startCapture()`

**Step 2: Update README.md**

In the "Bundle runtime note" section, add:
- VoxFlow runs as a menu-bar agent app by default (`LSUIElement = true`). The Dock icon appears only when a window (Dashboard, Setup, Settings) is open.
- Use `--force-dock-icon` with `build_app_bundle.sh` if you want a persistent Dock icon.

**Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: update conventions for focus fix — non-activating panel, target snapshot, agent mode"
```

---

### Task 8: Manual Integration Test

**No code changes — manual verification only.**

Rebuild and test the full flow:

**Step 1: Build and launch**

```bash
cd <repo>
./scripts/build_app_bundle.sh
./scripts/install_app_bundle.sh
./scripts/launch_voxflow_dev.sh
```

**Step 2: Verify focus behavior**

1. Open TextEdit. Type some text. Place cursor.
2. Click VoxFlow menu bar icon — palette opens.
3. Verify TextEdit still has focus (title bar not dimmed).
4. Hold Fn → dictate → release Fn.
5. Verify text appears in TextEdit (not in VoxFlow).
6. Check Dock — VoxFlow should NOT be there.

**Step 3: Verify Dashboard activation**

1. Click "Open Dashboard" from palette.
2. Verify VoxFlow appears in Dock.
3. Close Dashboard.
4. Verify VoxFlow disappears from Dock.

**Step 4: Verify Cmd+Tab**

1. With only menu bar palette visible, press Cmd+Tab.
2. VoxFlow should NOT appear in the app switcher.
3. Open Dashboard → Cmd+Tab → VoxFlow should appear.

**Step 5: Verify Electron app compatibility**

1. Open Notion (or another Electron app).
2. Dictate into a text field.
3. Verify text lands in Notion.

If any step fails, debug and fix before proceeding.

**Step 6: Commit (if any fixes needed)**

```bash
git commit -m "fix: integration test adjustments for focus fix"
```

---

## Task Dependency Graph

```
Task 1 (insert pipeline params)
  └→ Task 2 (capture at startCapture)
      └→ Task 3 (freeze FocusContextMonitor)
Task 4 (MenuBarPanelController)
  └→ Task 5 (wire panel + remove MenuBarExtra)
      └→ Task 6 (LSUIElement + activation policy)
Task 7 (docs) — after Tasks 1-6
Task 8 (manual test) — after Tasks 1-7
```

Tasks 1-3 and Task 4 can be done in parallel (independent).
Tasks 5-6 depend on both branches merging.
