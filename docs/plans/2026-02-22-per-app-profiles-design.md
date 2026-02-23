# Per-App Profiles — Design Document

**Date:** 2026-02-22
**Priority:** 5 (from next-session roadmap, sub-feature: Per-App Profiles)

## Problem

VoxFlow has global-only settings for tone, cleanup mode, and insert behavior. Users dictating into different apps want different profiles — formal + light cleanup for email, concise + raw for Slack, etc. The tone override infrastructure exists but is incomplete (no "add" UI, tone-only, no cleanup/insert overrides).

## Design

### Section 1: Per-App Profile Data Model

Replace the tone-only `appToneOverrides: [String: ToneStyle]` with a full profile:

```swift
struct AppProfile: Codable, Equatable {
    var tone: ToneStyle
    var cleanupMode: CleanupMode
    var insertBehavior: InsertBehavior
}
```

- `AppState.appToneOverrides` → `AppState.appProfiles: [String: AppProfile]`
- UserDefaults key unchanged: `voxflow.dictation.appToneOverrides`
- Encode/decode `AppProfile` instead of raw `ToneStyle`
- Migration: on launch, detect old `[String: String]` format and convert to `AppProfile` with defaults (cleanupMode: .raw, insertBehavior: .autoInsertRaw)

### Section 2: Profile Resolution

Replace `resolveEffectiveTone()` with `resolveEffectiveProfile()`:

```swift
private func resolveEffectiveProfile() -> AppProfile? {
    let bundleID = state.focusTarget.bundleID ?? ""
    return state.appProfiles[bundleID]
        ?? SettingsCoordinator.defaultAppProfiles[bundleID]
}
```

Returns `nil` when no profile configured — callers fall back to global settings:

```swift
let profile = resolveEffectiveProfile()
let effectiveTone = profile?.tone ?? state.toneStyle
let effectiveCleanup = profile?.cleanupMode ?? state.selectedMode
let effectiveInsert = profile?.insertBehavior ?? state.insertBehavior
```

Static defaults (replaces `defaultAppTones`):

| App | Tone | Cleanup | Insert |
|-----|------|---------|--------|
| Slack | concise | raw | autoInsertRaw |
| Mail | formal | light | alwaysReview |
| Outlook | formal | light | alwaysReview |
| Chrome | neutral | raw | autoInsertRaw |
| Xcode | neutral | raw | autoInsertRaw |

### Section 3: UI

**Capture panel quick-set:** Below the tone selector in the capture panel, a "Profile: [AppName]" button with gear icon. Opens inline popover with Tone, Cleanup Mode, and Insert Behavior pickers. Changes persist immediately via `coordinator.updateAppProfile(bundleID:profile:)`. "Reset to Default" removes the override.

**Settings view:** Existing override list updated to show full profile (tone + cleanup + insert) per row. Edit/remove only — adding happens through the capture panel quick-set.

### Section 4: Migration + Testing

- One-time migration from `[String: String]` → `[String: AppProfile]` on launch
- Tests: AppProfile Codable round-trip, migration, resolution priority chain, persistence CRUD
- Update existing SettingsCoordinatorTests

## Files Touched

| File | Change |
|------|--------|
| `Sources/VoxFlowApp/Models/AppModels.swift` | Add `AppProfile` struct |
| `Sources/VoxFlowApp/State/AppState.swift` | Replace `appToneOverrides` with `appProfiles` |
| `Sources/VoxFlowApp/Services/SettingsCoordinator.swift` | `defaultAppProfiles`, persistence, migration |
| `Sources/VoxFlowApp/AppCoordinator.swift` | `resolveEffectiveProfile()`, wire into processDictation |
| `Sources/VoxFlowApp/Views/CommandPaletteView.swift` | Quick-set profile popover |
| `Sources/VoxFlowApp/Views/SettingsView.swift` | Update override list to full profile |
| `Tests/VoxFlowAppTests/SettingsCoordinatorTests.swift` | Update for new data model |
| `Tests/VoxFlowAppTests/AppModelTests.swift` | AppProfile Codable + migration tests |
