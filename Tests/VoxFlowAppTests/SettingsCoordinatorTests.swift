import XCTest
@testable import VoxFlowApp

final class SettingsCoordinatorTests: XCTestCase {

    @MainActor
    private func makeSUT() -> (SettingsCoordinator, AppState, BackendProcessManager) {
        let state = AppState()
        // Fake runner: a real one lets restart/stop paths touch the live
        // system (the idle-restart test was deleting the production PID
        // file on every suite run).
        let backend = BackendProcessManager(runner: BackendProcessRunnerFake())
        let sut = SettingsCoordinator(state: state, backendManager: backend)
        return (sut, state, backend)
    }

    @MainActor
    func testSelectProviderModePersistsAndUpdatesState() {
        let (sut, state, _) = makeSUT()
        sut.selectProviderMode(.privateAPI)
        XCTAssertEqual(state.providerMode, .privateAPI)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "voxflow.provider.mode"), "privateAPI")
        UserDefaults.standard.removeObject(forKey: "voxflow.provider.mode")
    }

    @MainActor
    func testSelectProviderModeClearsPrivacyPreviewWhenLocal() {
        let (sut, state, _) = makeSUT()
        state.privacyPreview = PrivacyPreview(
            operation: .cleanup, token: "tok", originalText: "a", redactedText: "b"
        )
        state.providerMode = .privateAPI

        sut.selectProviderMode(.localOnly)

        XCTAssertNil(state.privacyPreview)
        XCTAssertEqual(state.providerMode, .localOnly)
        UserDefaults.standard.removeObject(forKey: "voxflow.provider.mode")
    }

    @MainActor
    func testSelectSTTBackendPersists() {
        let (sut, state, _) = makeSUT()
        sut.selectSTTBackend(.whisper)
        XCTAssertEqual(state.sttBackend, .whisper)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "voxflow.stt.backend"), "whisper")
        UserDefaults.standard.removeObject(forKey: "voxflow.stt.backend")
    }

    @MainActor
    func testUpdatePrivateAPIConfigSavesToKeychain() {
        let (sut, state, _) = makeSUT()
        sut.updatePrivateAPIConfig(baseURL: "https://api.example.com", model: "gpt-4", apiKey: "sk-test-123")
        XCTAssertEqual(state.privateAPIBaseURL, "https://api.example.com")
        XCTAssertEqual(state.privateAPIModel, "gpt-4")
        XCTAssertTrue(state.privateAPIKeyConfigured)

        let loaded = KeychainService.load(account: SettingsCoordinator.keychainPrivateAPIKeyAccount)
        XCTAssertEqual(loaded, "sk-test-123")

        KeychainService.delete(account: SettingsCoordinator.keychainPrivateAPIKeyAccount)
        UserDefaults.standard.removeObject(forKey: "voxflow.privateapi.baseURL")
        UserDefaults.standard.removeObject(forKey: "voxflow.privateapi.model")
    }

    @MainActor
    func testConfigureInitialStateLoadsDefaults() {
        let defaults = UserDefaults.standard
        defaults.set("whisper", forKey: "voxflow.stt.backend")
        defaults.set("privateAPI", forKey: "voxflow.provider.mode")
        defaults.set("controlShiftSpace", forKey: "voxflow.hotkey.dictationPreset")
        defaults.set("fnOptionSpace", forKey: "voxflow.hotkey.commandLanePreset")
        defaults.set(true, forKey: "voxflow.onboarding.complete")

        let (sut, state, _) = makeSUT()
        sut.configureInitialState()

        XCTAssertEqual(state.sttBackend, .whisper)
        XCTAssertEqual(state.providerMode, .privateAPI)
        XCTAssertEqual(state.dictationHotkeyPreset, .controlShiftSpace)
        XCTAssertEqual(state.commandLaneHotkeyPreset, .fnOptionSpace)
        XCTAssertEqual(state.onboardingPhase, .complete)
        XCTAssertEqual(state.sessionState, .idle)

        defaults.removeObject(forKey: "voxflow.stt.backend")
        defaults.removeObject(forKey: "voxflow.provider.mode")
        defaults.removeObject(forKey: "voxflow.hotkey.dictationPreset")
        defaults.removeObject(forKey: "voxflow.hotkey.commandLanePreset")
        defaults.removeObject(forKey: "voxflow.onboarding.complete")
    }

    @MainActor
    func testSetTranslationModeDisabledDowngradesWorkflowMode() {
        let (sut, state, _) = makeSUT()
        state.workflowMode = .translateEnToDe
        state.translationModeEnabled = true

        sut.setTranslationModeEnabled(false)

        XCTAssertEqual(state.workflowMode, .dictation)
        XCTAssertFalse(state.translationModeEnabled)
        UserDefaults.standard.removeObject(forKey: "voxflow.translation.modeEnabled")
    }

    @MainActor
    func testSetMeetingModeDisabledDowngradesWorkflowMode() {
        let (sut, state, _) = makeSUT()
        state.workflowMode = .meeting
        state.meetingModeEnabled = true

        sut.setMeetingModeEnabled(false)

        XCTAssertEqual(state.workflowMode, .dictation)
        XCTAssertFalse(state.meetingModeEnabled)
        UserDefaults.standard.removeObject(forKey: "voxflow.meeting.modeEnabled")
    }

    @MainActor
    func testSetDictationHotkeyPresetPersists() {
        let (sut, state, _) = makeSUT()

        sut.setDictationHotkeyPreset(.controlShiftSpace)

        XCTAssertEqual(state.dictationHotkeyPreset, .controlShiftSpace)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "voxflow.hotkey.dictationPreset"), "controlShiftSpace")
        UserDefaults.standard.removeObject(forKey: "voxflow.hotkey.dictationPreset")
    }

    @MainActor
    func testSetCommandLaneHotkeyPresetPersists() {
        let (sut, state, _) = makeSUT()

        sut.setCommandLaneHotkeyPreset(.fnOptionSpace)

        XCTAssertEqual(state.commandLaneHotkeyPreset, .fnOptionSpace)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "voxflow.hotkey.commandLanePreset"), "fnOptionSpace")
        UserDefaults.standard.removeObject(forKey: "voxflow.hotkey.commandLanePreset")
    }

    @MainActor
    func testSelectInsertBehaviorPersists() {
        let (sut, state, _) = makeSUT()
        sut.selectInsertBehavior(.autoInsertPolish)
        XCTAssertEqual(state.insertBehavior, .autoInsertPolish)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "voxflow.dictation.insertBehavior"), "autoInsertPolish")
        UserDefaults.standard.removeObject(forKey: "voxflow.dictation.insertBehavior")
    }

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

    @MainActor
    func testCurrentBackendLaunchConfigurationReflectsState() {
        let (sut, state, _) = makeSUT()
        state.sttBackend = .whisperKit
        state.localWhisperModel = "test-whisper-model"
        state.translationProfile = .marianFallback

        let config = sut.currentBackendLaunchConfiguration()

        XCTAssertEqual(config.sttBackend, "whisperKit")
        XCTAssertEqual(config.sttModel, "test-whisper-model")
        XCTAssertEqual(config.translateModel, TranslationProfile.marianFallback.modelID)
        XCTAssertEqual(config.translateBackend, "marian")
    }

    @MainActor
    func testPromptWorkflowWithWhisperKitDoesNotRequireBackend() {
        let (_, state, _) = makeSUT()
        state.workflowMode = .prompt
        state.sttBackend = .whisperKit
        state.providerMode = .localOnly

        XCTAssertFalse(state.workflowNeedsBackend)
        XCTAssertFalse(state.backendShouldRun)
    }

    @MainActor
    func testOpenCockpitRequiresBackendEvenInDictationMode() {
        let (_, state, _) = makeSUT()
        state.workflowMode = .dictation
        state.sttBackend = .whisperKit
        state.providerMode = .localOnly

        state.cockpitVisible = true

        XCTAssertFalse(state.workflowNeedsBackend)
        XCTAssertTrue(state.backendShouldRun)
    }

    @MainActor
    func testClosedCockpitDoesNotRequireBackend() {
        let (_, state, _) = makeSUT()
        state.workflowMode = .dictation
        state.sttBackend = .whisperKit
        state.providerMode = .localOnly
        // Opt fully out of cleanup (global raw AND every shipped profile raw) so
        // the cockpit is the only thing that could keep the backend up — non-raw
        // dictation, including the shipped Chrome polish default, now wants it
        // for local-model cleanup (see localDictationWantsBackendCleanup).
        state.insertBehavior = .autoInsertRaw
        for bundleID in SettingsCoordinator.defaultAppProfiles.keys {
            state.appProfiles[bundleID] = AppProfile(
                tone: .neutral, cleanupMode: .raw, insertBehavior: .autoInsertRaw)
        }

        state.cockpitVisible = false

        XCTAssertFalse(state.backendShouldRun)
    }

    @MainActor
    func testRestartBackendWithRawWhisperKitDictationLeavesBackendIdle() {
        let (sut, state, _) = makeSUT()
        state.workflowMode = .dictation
        state.sttBackend = .whisperKit
        state.providerMode = .localOnly
        // Fully opted out of cleanup (global raw AND every shipped profile raw),
        // so dictation stays in-app and the backend stays idle.
        state.insertBehavior = .autoInsertRaw
        for bundleID in SettingsCoordinator.defaultAppProfiles.keys {
            state.appProfiles[bundleID] = AppProfile(
                tone: .neutral, cleanupMode: .raw, insertBehavior: .autoInsertRaw)
        }

        sut.restartBackendWithCurrentConfiguration(status: "Dictation mode active")

        XCTAssertFalse(state.backendReadiness.processRunning)
        XCTAssertFalse(state.backendReadiness.warmupInProgress)
        XCTAssertFalse(state.backendReadiness.readyForDictation)
        XCTAssertNil(state.backendReadiness.readinessIssue)
        XCTAssertEqual(state.backendReadiness.statusSummary, "Backend idle — current workflow runs in app")
        XCTAssertEqual(state.backendReadiness.activeSTTModel, "whisperkit (in-app)")
        XCTAssertEqual(state.statusLine, "Dictation mode active")
    }

    @MainActor
    func testRestartBackendWithLightWhisperKitDictationMarksBackendWarmup() {
        let (sut, state, _) = makeSUT()
        state.workflowMode = .dictation
        state.sttBackend = .whisperKit
        state.providerMode = .localOnly
        // Non-raw dictation routes cleanup through the local-model backend
        // provider chain, so the backend must warm up even though STT is in-app.
        state.insertBehavior = .autoInsertLight

        sut.restartBackendWithCurrentConfiguration(status: "Dictation mode active")

        XCTAssertTrue(state.backendReadiness.processRunning)
        XCTAssertTrue(state.backendReadiness.warmupInProgress)
        XCTAssertFalse(state.backendReadiness.readyForDictation)
        XCTAssertNil(state.backendReadiness.readinessIssue)
        XCTAssertEqual(state.backendReadiness.statusSummary, "Backend starting — waiting for warmup")
        XCTAssertEqual(state.statusLine, "Dictation mode active")
    }

    @MainActor
    func testRestartBackendWithMeetingWorkflowMarksBackendWarmup() {
        let (sut, state, _) = makeSUT()
        state.workflowMode = .meeting
        state.sttBackend = .whisperKit
        state.providerMode = .localOnly

        sut.restartBackendWithCurrentConfiguration(status: "Meeting mode active")

        XCTAssertTrue(state.backendReadiness.processRunning)
        XCTAssertTrue(state.backendReadiness.warmupInProgress)
        XCTAssertFalse(state.backendReadiness.readyForDictation)
        XCTAssertNil(state.backendReadiness.readinessIssue)
        XCTAssertEqual(state.backendReadiness.statusSummary, "Backend starting — waiting for warmup")
        XCTAssertEqual(state.statusLine, "Meeting mode active")
    }
}
