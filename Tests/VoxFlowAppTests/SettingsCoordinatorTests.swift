import XCTest
@testable import VoxFlowApp

final class SettingsCoordinatorTests: XCTestCase {

    @MainActor
    private func makeSUT() -> (SettingsCoordinator, AppState, BackendProcessManager) {
        let state = AppState()
        let backend = BackendProcessManager()
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
        XCTAssertEqual(state.privateAPIKey, "sk-test-123")

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
    func testUpdateAppToneOverridePersistsAndRemoves() {
        let (sut, state, _) = makeSUT()
        sut.updateAppToneOverride(bundleID: "com.test.app", tone: .formal)
        XCTAssertEqual(state.appToneOverrides["com.test.app"], .formal)

        sut.updateAppToneOverride(bundleID: "com.test.app", tone: nil)
        XCTAssertNil(state.appToneOverrides["com.test.app"])
        UserDefaults.standard.removeObject(forKey: "voxflow.dictation.appToneOverrides")
    }

    @MainActor
    func testCurrentBackendLaunchConfigurationReflectsState() {
        let (sut, state, _) = makeSUT()
        state.sttBackend = .voxtral
        state.localVoxtralModel = "test-model"
        state.translationProfile = .marianFallback

        let config = sut.currentBackendLaunchConfiguration()

        XCTAssertEqual(config.sttBackend, "voxtral")
        XCTAssertEqual(config.sttModel, "test-model")
        XCTAssertEqual(config.translateModel, TranslationProfile.marianFallback.modelID)
        XCTAssertEqual(config.translateBackend, "marian")
    }
}
