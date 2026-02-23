# Per-App Profiles — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the tone-only per-app override with a full per-app profile (tone + cleanup mode + insert behavior), add a quick-set UI in the capture panel, and update the Settings view.

**Architecture:** New `AppProfile` struct in AppModels.swift. `AppState.appToneOverrides` becomes `appProfiles: [String: AppProfile]`. `SettingsCoordinator` handles persistence with one-time migration from old format. `resolveEffectiveTone()` becomes `resolveEffectiveProfile()` returning `AppProfile?`. UI in CommandPaletteView adds an inline profile popover; SettingsView updates to show the full profile per row.

**Tech Stack:** Swift 6.2, SwiftUI, UserDefaults (JSON-encoded `[String: AppProfile]`)

---

### Task 1: Add AppProfile struct and update AppState

**Files:**
- Modify: `Sources/VoxFlowApp/Models/AppModels.swift` (after InsertBehavior enum, ~line 134)
- Modify: `Sources/VoxFlowApp/State/AppState.swift:22` (replace appToneOverrides)
- Test: `Tests/VoxFlowAppTests/AppModelTests.swift`

**Step 1: Write the failing test**

Add to `Tests/VoxFlowAppTests/AppModelTests.swift`:

```swift
    func testAppProfileCodableRoundTrip() throws {
        let profile = AppProfile(tone: .formal, cleanupMode: .light, insertBehavior: .alwaysReview)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AppProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testAppProfileDictionaryCodableRoundTrip() throws {
        let profiles: [String: AppProfile] = [
            "com.apple.mail": AppProfile(tone: .formal, cleanupMode: .light, insertBehavior: .alwaysReview),
            "com.tinyspeck.slackmacgap": AppProfile(tone: .concise, cleanupMode: .raw, insertBehavior: .autoInsertRaw),
        ]
        let data = try JSONEncoder().encode(profiles)
        let decoded = try JSONDecoder().decode([String: AppProfile].self, from: data)
        XCTAssertEqual(decoded, profiles)
    }
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppModelTests/testAppProfileCodableRoundTrip`
Expected: FAIL — `AppProfile` type not found.

**Step 3: Add AppProfile struct and update AppState**

In `Sources/VoxFlowApp/Models/AppModels.swift`, after the `InsertBehavior` enum closing brace (after line ~134), add:

```swift
struct AppProfile: Codable, Equatable {
    var tone: ToneStyle
    var cleanupMode: CleanupMode
    var insertBehavior: InsertBehavior
}
```

In `Sources/VoxFlowApp/State/AppState.swift`, change line 22 from:

```swift
    @Published var appToneOverrides: [String: ToneStyle] = [:]
```

to:

```swift
    @Published var appProfiles: [String: AppProfile] = [:]
```

**Step 4: Fix all compilation errors from the rename**

This rename will break references in:
- `AppCoordinator.swift` — `resolveEffectiveTone()` reads `state.appToneOverrides`
- `SettingsCoordinator.swift` — `updateAppToneOverride()` and `configureInitialState()` use `state.appToneOverrides`
- `SettingsView.swift` — references `state.appToneOverrides`
- `CommandPaletteView.swift` — no direct reference (only through coordinator)

For now, do minimal fixes to get it compiling — change all `state.appToneOverrides` → `state.appProfiles` and update types. The full logic rewrites happen in later tasks. Quick fixes:

In `AppCoordinator.swift` line 618, change:
```swift
        return state.appToneOverrides[bundleID]
```
to:
```swift
        return state.appProfiles[bundleID]?.tone
```

In `AppCoordinator.swift` line 480, change:
```swift
    func updateAppToneOverride(bundleID: String, tone: ToneStyle?) { settings.updateAppToneOverride(bundleID: bundleID, tone: tone) }
```
to:
```swift
    func updateAppProfile(bundleID: String, profile: AppProfile?) { settings.updateAppProfile(bundleID: bundleID, profile: profile) }
```

In `SettingsCoordinator.swift`, rename method and update protocol — change `updateAppToneOverride` to `updateAppProfile`:

Protocol (line 18):
```swift
    func updateAppProfile(bundleID: String, profile: AppProfile?)
```

Implementation (lines 249-259), replace entire method:
```swift
    func updateAppProfile(bundleID: String, profile: AppProfile?) {
        if let profile {
            state.appProfiles[bundleID] = profile
        } else {
            state.appProfiles.removeValue(forKey: bundleID)
        }
        if let data = try? JSONEncoder().encode(state.appProfiles) {
            UserDefaults.standard.set(data, forKey: appToneOverridesKey)
        }
    }
```

In `SettingsCoordinator.swift` `configureInitialState()` (lines 135-138), replace:
```swift
        if let overridesData = defaults.data(forKey: appToneOverridesKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: overridesData) {
            state.appToneOverrides = decoded.compactMapValues { ToneStyle(rawValue: $0) }
        }
```
with:
```swift
        if let overridesData = defaults.data(forKey: appToneOverridesKey) {
            // Try new AppProfile format first
            if let profiles = try? JSONDecoder().decode([String: AppProfile].self, from: overridesData) {
                state.appProfiles = profiles
            }
            // Migrate from old [String: String] tone-only format
            else if let legacy = try? JSONDecoder().decode([String: String].self, from: overridesData) {
                state.appProfiles = legacy.compactMapValues { rawValue in
                    guard let tone = ToneStyle(rawValue: rawValue) else { return nil }
                    return AppProfile(tone: tone, cleanupMode: .raw, insertBehavior: .autoInsertRaw)
                }
                // Re-save in new format
                if let data = try? JSONEncoder().encode(state.appProfiles) {
                    defaults.set(data, forKey: appToneOverridesKey)
                }
            }
        }
```

In `SettingsView.swift`, update the overrides section (lines 214-242). Replace:
```swift
                if state.appToneOverrides.isEmpty {
                    Text("No custom overrides. Apps use your selected tone or built-in defaults (Slack → Concise, Mail → Formal, etc).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(state.appToneOverrides.keys.sorted()), id: \.self) { bundleID in
                        if let tone = state.appToneOverrides[bundleID] {
                            HStack {
                                Text(bundleID.components(separatedBy: ".").last ?? bundleID)
                                    .font(.system(size: 12))
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { tone },
                                    set: { coordinator.updateAppToneOverride(bundleID: bundleID, tone: $0) }
                                )) {
                                    ForEach(ToneStyle.allCases) { t in
                                        Text(t.displayName).tag(t)
                                    }
                                }
                                .frame(width: 120)
                                Button("Remove") {
                                    coordinator.updateAppToneOverride(bundleID: bundleID, tone: nil)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
```
with:
```swift
                if state.appProfiles.isEmpty {
                    Text("No custom overrides. Apps use your selected tone or built-in defaults (Slack → Concise, Mail → Formal, etc).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(state.appProfiles.keys.sorted()), id: \.self) { bundleID in
                        if let profile = state.appProfiles[bundleID] {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(bundleID.components(separatedBy: ".").last ?? bundleID)
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Button("Remove") {
                                        coordinator.updateAppProfile(bundleID: bundleID, profile: nil)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                HStack(spacing: 12) {
                                    Picker("Tone", selection: Binding(
                                        get: { profile.tone },
                                        set: { coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: $0, cleanupMode: profile.cleanupMode, insertBehavior: profile.insertBehavior)) }
                                    )) {
                                        ForEach(ToneStyle.allCases) { t in Text(t.displayName).tag(t) }
                                    }
                                    .frame(width: 110)
                                    Picker("Mode", selection: Binding(
                                        get: { profile.cleanupMode },
                                        set: { coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: profile.tone, cleanupMode: $0, insertBehavior: profile.insertBehavior)) }
                                    )) {
                                        ForEach(CleanupMode.allCases) { m in Text(m.displayName).tag(m) }
                                    }
                                    .frame(width: 90)
                                    Picker("Insert", selection: Binding(
                                        get: { profile.insertBehavior },
                                        set: { coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: profile.tone, cleanupMode: profile.cleanupMode, insertBehavior: $0)) }
                                    )) {
                                        ForEach(InsertBehavior.allCases) { b in Text(b.displayName).tag(b) }
                                    }
                                    .frame(width: 150)
                                }
                                .font(.system(size: 11))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
```

Also update `SettingsView.swift` section header text from "App Tone Overrides" to "App Profiles".

**Step 5: Build and run tests**

Run: `swift build`
Expected: Build succeeds.

Run: `swift test`
Expected: All tests pass (some existing SettingsCoordinator tests may need updating — see Task 2).

**Step 6: Commit**

```bash
git add Sources/VoxFlowApp/Models/AppModels.swift Sources/VoxFlowApp/State/AppState.swift Sources/VoxFlowApp/AppCoordinator.swift Sources/VoxFlowApp/Services/SettingsCoordinator.swift Sources/VoxFlowApp/Views/SettingsView.swift Tests/VoxFlowAppTests/AppModelTests.swift
git commit -m "feat: add AppProfile struct, replace appToneOverrides with appProfiles

Full per-app profile: tone + cleanup mode + insert behavior.
One-time migration from old [String:String] format.
Settings view shows all three pickers per profile row.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Update defaultAppProfiles and resolveEffectiveProfile

**Files:**
- Modify: `Sources/VoxFlowApp/Services/SettingsCoordinator.swift:55-61` (defaultAppTones → defaultAppProfiles)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:616-621` (resolveEffectiveTone → resolveEffectiveProfile)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:643-705` (processDictation — wire profile)
- Test: `Tests/VoxFlowAppTests/SettingsCoordinatorTests.swift`

**Step 1: Write the failing test**

Add to `Tests/VoxFlowAppTests/SettingsCoordinatorTests.swift`:

```swift
    @MainActor
    func testUpdateAppProfilePersistsAndRemoves() {
        let (sut, state, _) = makeSUT()
        let profile = AppProfile(tone: .formal, cleanupMode: .light, insertBehavior: .alwaysReview)
        sut.updateAppProfile(bundleID: "com.test.app", profile: profile)
        XCTAssertEqual(state.appProfiles["com.test.app"], profile)

        sut.updateAppProfile(bundleID: "com.test.app", profile: nil)
        XCTAssertNil(state.appProfiles["com.test.app"])
        UserDefaults.standard.removeObject(forKey: "voxflow.dictation.appToneOverrides")
    }

    @MainActor
    func testConfigureInitialStateMigratesLegacyToneOverrides() {
        let defaults = UserDefaults.standard
        // Write old format: [String: String]
        let legacy = ["com.apple.mail": "formal", "com.tinyspeck.slackmacgap": "concise"]
        let data = try! JSONEncoder().encode(legacy)
        defaults.set(data, forKey: "voxflow.dictation.appToneOverrides")
        defaults.set(true, forKey: "voxflow.onboarding.complete")

        let (sut, state, _) = makeSUT()
        sut.configureInitialState()

        XCTAssertEqual(state.appProfiles["com.apple.mail"]?.tone, .formal)
        XCTAssertEqual(state.appProfiles["com.apple.mail"]?.cleanupMode, .raw)
        XCTAssertEqual(state.appProfiles["com.apple.mail"]?.insertBehavior, .autoInsertRaw)
        XCTAssertEqual(state.appProfiles["com.tinyspeck.slackmacgap"]?.tone, .concise)

        defaults.removeObject(forKey: "voxflow.dictation.appToneOverrides")
        defaults.removeObject(forKey: "voxflow.onboarding.complete")
    }
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SettingsCoordinatorTests/testUpdateAppProfilePersistsAndRemoves`
Expected: May pass if Task 1 was done correctly. If not, fix.

Run: `swift test --filter SettingsCoordinatorTests/testConfigureInitialStateMigratesLegacyToneOverrides`
Expected: PASS (migration logic was added in Task 1).

**Step 3: Update defaultAppProfiles**

In `Sources/VoxFlowApp/Services/SettingsCoordinator.swift`, replace lines 55-61:

```swift
    static let defaultAppTones: [String: ToneStyle] = [
        "com.tinyspeck.slackmacgap": .concise,
        "com.apple.mail": .formal,
        "com.microsoft.Outlook": .formal,
        "com.google.Chrome": .neutral,
        "com.apple.dt.Xcode": .neutral,
    ]
```

with:

```swift
    static let defaultAppProfiles: [String: AppProfile] = [
        "com.tinyspeck.slackmacgap": AppProfile(tone: .concise, cleanupMode: .raw, insertBehavior: .autoInsertRaw),
        "com.apple.mail": AppProfile(tone: .formal, cleanupMode: .light, insertBehavior: .alwaysReview),
        "com.microsoft.Outlook": AppProfile(tone: .formal, cleanupMode: .light, insertBehavior: .alwaysReview),
        "com.google.Chrome": AppProfile(tone: .neutral, cleanupMode: .raw, insertBehavior: .autoInsertRaw),
        "com.apple.dt.Xcode": AppProfile(tone: .neutral, cleanupMode: .raw, insertBehavior: .autoInsertRaw),
    ]
```

**Step 4: Replace resolveEffectiveTone with resolveEffectiveProfile**

In `Sources/VoxFlowApp/AppCoordinator.swift`, replace lines 616-621:

```swift
    private func resolveEffectiveTone() -> ToneStyle {
        let bundleID = state.focusTarget.bundleID ?? ""
        return state.appToneOverrides[bundleID]?.tone
            ?? SettingsCoordinator.defaultAppTones[bundleID]
            ?? state.toneStyle
    }
```

with:

```swift
    private func resolveEffectiveProfile() -> AppProfile? {
        let bundleID = state.focusTarget.bundleID ?? ""
        return state.appProfiles[bundleID]
            ?? SettingsCoordinator.defaultAppProfiles[bundleID]
    }
```

**Step 5: Wire profile into processDictation**

In `Sources/VoxFlowApp/AppCoordinator.swift`, in `processDictation()`, replace line 648:

```swift
            let effectiveTone = self.resolveEffectiveTone()
```

with:

```swift
            let profile = self.resolveEffectiveProfile()
            let effectiveTone = profile?.tone ?? self.state.toneStyle
            let effectiveCleanup = profile?.cleanupMode ?? self.state.selectedMode
            let effectiveInsert = profile?.insertBehavior ?? self.state.insertBehavior
```

Then update the auto-insert raw check (line 651) from:

```swift
            if self.state.insertBehavior == .autoInsertRaw && providerMode == .localOnly {
```

to:

```swift
            if effectiveInsert == .autoInsertRaw && providerMode == .localOnly {
```

And update the auto-insert light/polish check (line 688) from:

```swift
            if let autoMode = self.state.insertBehavior.cleanupMode, providerMode == .localOnly {
```

to:

```swift
            if let autoMode = effectiveInsert.cleanupMode, providerMode == .localOnly {
```

**Step 6: Update existing test**

In `Tests/VoxFlowAppTests/SettingsCoordinatorTests.swift`, replace `testUpdateAppToneOverridePersistsAndRemoves` (lines 147-155) — it references the old method. Either delete it (replaced by the new test above) or update it.

Replace:
```swift
    @MainActor
    func testUpdateAppToneOverridePersistsAndRemoves() {
        let (sut, state, _) = makeSUT()
        sut.updateAppToneOverride(bundleID: "com.test.app", tone: .formal)
        XCTAssertEqual(state.appToneOverrides["com.test.app"], .formal)

        sut.updateAppToneOverride(bundleID: "com.test.app", tone: nil)
        XCTAssertNil(state.appToneOverrides["com.test.app"])
        UserDefaults.standard.removeObject(forKey: "voxflow.dictation.appToneOverrides")
    }
```

with the `testUpdateAppProfilePersistsAndRemoves` test from Step 1 (delete the old test, keep the new one).

**Step 7: Build and run tests**

Run: `swift build`
Expected: Build succeeds.

Run: `swift test`
Expected: All tests pass.

**Step 8: Commit**

```bash
git add Sources/VoxFlowApp/Services/SettingsCoordinator.swift Sources/VoxFlowApp/AppCoordinator.swift Tests/VoxFlowAppTests/SettingsCoordinatorTests.swift
git commit -m "feat: replace resolveEffectiveTone with resolveEffectiveProfile

Three-tier resolution: user profile > static defaults > global settings.
processDictation reads tone + cleanup + insert from resolved profile.
Static defaultAppProfiles replaces defaultAppTones.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Add quick-set profile UI in capture panel

**Files:**
- Modify: `Sources/VoxFlowApp/Views/CommandPaletteView.swift` (capturePanel, ~line 174-238)

**Step 1: Add profile popover state and view**

In `Sources/VoxFlowApp/Views/CommandPaletteView.swift`, add a new `@State` after `showClearHistoryAlert`:

```swift
    @State private var showProfilePopover = false
```

In the `capturePanel` computed property, after the tone `HStack` (after line ~329, before the closing `}` of `dictationReview`), add:

```swift
            if let bundleID = state.focusTarget.bundleID, let appName = state.focusTarget.appName {
                Divider()
                HStack(spacing: 6) {
                    Button {
                        showProfilePopover.toggle()
                    } label: {
                        Label("Profile: \(appName)", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $showProfilePopover) {
                        appProfilePopover(bundleID: bundleID, appName: appName)
                    }

                    if state.appProfiles[bundleID] != nil {
                        Text("Custom")
                            .font(VF.captionFont.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                }
            }
```

Then add the popover view method (before the `relativeTime` function):

```swift
    private func appProfilePopover(bundleID: String, appName: String) -> some View {
        let current = state.appProfiles[bundleID]
            ?? SettingsCoordinator.defaultAppProfiles[bundleID]
            ?? AppProfile(tone: state.toneStyle, cleanupMode: state.selectedMode, insertBehavior: state.insertBehavior)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Profile for \(appName)")
                .font(VF.labelFont.weight(.semibold))

            Picker("Tone", selection: Binding(
                get: { current.tone },
                set: { newTone in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: newTone, cleanupMode: current.cleanupMode, insertBehavior: current.insertBehavior))
                }
            )) {
                ForEach(ToneStyle.allCases) { t in Text(t.displayName).tag(t) }
            }

            Picker("Cleanup", selection: Binding(
                get: { current.cleanupMode },
                set: { newMode in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: current.tone, cleanupMode: newMode, insertBehavior: current.insertBehavior))
                }
            )) {
                ForEach(CleanupMode.allCases) { m in Text(m.displayName).tag(m) }
            }

            Picker("Insert", selection: Binding(
                get: { current.insertBehavior },
                set: { newBehavior in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: current.tone, cleanupMode: current.cleanupMode, insertBehavior: newBehavior))
                }
            )) {
                ForEach(InsertBehavior.allCases) { b in Text(b.displayName).tag(b) }
            }

            if state.appProfiles[bundleID] != nil {
                Button("Reset to Default") {
                    coordinator.updateAppProfile(bundleID: bundleID, profile: nil)
                    showProfilePopover = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Build succeeds.

**Step 3: Run Swift tests**

Run: `swift test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add Sources/VoxFlowApp/Views/CommandPaletteView.swift
git commit -m "feat: add quick-set profile popover in capture panel

Profile: [AppName] button with gear icon opens popover with
Tone, Cleanup, and Insert pickers. Shows 'Custom' badge when
a per-app override exists. Reset to Default removes override.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Update docs and run full test suite

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Step 1: Run full test suite**

Run: `swift test`
Expected: All tests pass.

Run: `./.venv/bin/python -m pytest backend/tests/ -v`
Expected: All tests pass.

**Step 2: Update CLAUDE.md**

In `CLAUDE.md`, in the Swift "Key Patterns" section, replace the `resolveEffectiveTone()` bullet:

```
- **App-context tone resolution**: `resolveEffectiveTone()` checks user overrides → `SettingsCoordinator.defaultAppTones` → global `toneStyle`, keyed by `FocusTargetSnapshot.bundleID`. Overrides persisted as JSON in UserDefaults.
```

with:

```
- **Per-app profile resolution**: `resolveEffectiveProfile()` checks `state.appProfiles[bundleID]` → `SettingsCoordinator.defaultAppProfiles[bundleID]` → `nil` (callers fall back to global settings). Profiles include tone, cleanup mode, and insert behavior. Persisted as JSON `[String: AppProfile]` in UserDefaults.
```

In `CLAUDE.md` "Do Not" section, replace:

```
- Store app tone overrides as anything other than `[String: String]` JSON in UserDefaults (keyed by bundleID, values are `ToneStyle.rawValue`)
```

with:

```
- Store app profiles as anything other than `[String: AppProfile]` JSON in UserDefaults (keyed by bundleID)
```

**Step 3: Update README.md**

In `README.md` under "Implemented", after the tone/style controls bullet, add:

```
- Per-app profiles (tone + cleanup mode + insert behavior per target app bundleID)
```

**Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: update conventions for per-app profiles

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```
