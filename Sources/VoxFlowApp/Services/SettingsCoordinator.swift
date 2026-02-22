import Foundation
import os.log

@MainActor protocol SettingsCoordinating {
    func configureInitialState()
    func selectProviderMode(_ mode: ProviderMode)
    func selectSTTBackend(_ backend: STTBackend)
    func updateLocalSpeechModels(voxtralModel: String, whisperModel: String)
    func setVoxtralSafeModeEnabled(_ isEnabled: Bool)
    func updatePrivateAPIConfig(baseURL: String, model: String, apiKey: String)
    func updateOpenAIConfig(baseURL: String, apiKey: String, sttModel: String, ttsModel: String, ttsVoice: String)
    func selectTranslationProfile(_ profile: TranslationProfile)
    func setTranslationModeEnabled(_ isEnabled: Bool)
    func setMeetingModeEnabled(_ isEnabled: Bool)
    func setDictationHotkeyPreset(_ preset: DictationHotkeyPreset)
    func setCommandLaneHotkeyPreset(_ preset: CommandLaneHotkeyPreset)
    func selectInsertBehavior(_ behavior: InsertBehavior)
    func updateAppToneOverride(bundleID: String, tone: ToneStyle?)
    func restartBackendWithCurrentConfiguration(status: String)
    func currentBackendLaunchConfiguration() -> BackendLaunchConfiguration
    func backendLaunchConfiguration(for profile: TranslationProfile) -> BackendLaunchConfiguration
}

@MainActor
final class SettingsCoordinator: SettingsCoordinating {
    private let log = Logger(subsystem: "local.voxflow.app", category: "SettingsCoordinator")
    private let state: AppState
    private let backendManager: BackendProcessManager

    let onboardingKey = "voxflow.onboarding.complete"
    private let translationProfileKey = "voxflow.translation.profile"
    private let translationModeEnabledKey = "voxflow.translation.modeEnabled"
    private let meetingModeEnabledKey = "voxflow.meeting.modeEnabled"
    private let dictationHotkeyPresetKey = "voxflow.hotkey.dictationPreset"
    private let commandLaneHotkeyPresetKey = "voxflow.hotkey.commandLanePreset"
    private let sttBackendKey = "voxflow.stt.backend"
    private let sttModelKey = "voxflow.stt.model"
    private let whisperModelKey = "voxflow.whisper.model"
    private let voxtralSafeModeKey = "voxflow.voxtral.safeMode"
    private let insertBehaviorKey = "voxflow.dictation.insertBehavior"
    private let appToneOverridesKey = "voxflow.dictation.appToneOverrides"
    private let providerModeKey = "voxflow.provider.mode"
    private let privateAPIBaseURLKey = "voxflow.privateapi.baseURL"
    private let privateAPIModelKey = "voxflow.privateapi.model"
    private let privateAPIKeyKey = "voxflow.privateapi.key"
    private let openAIBaseURLKey = "voxflow.openai.baseURL"
    private let openAIAPIKeyKey = "voxflow.openai.apiKey"
    private let openAISTTModelKey = "voxflow.openai.sttModel"
    private let openAITTSModelKey = "voxflow.openai.ttsModel"
    private let openAITTSVoiceKey = "voxflow.openai.ttsVoice"

    static let keychainPrivateAPIKeyAccount = "voxflow.privateapi.key"
    static let keychainOpenAIAPIKeyAccount = "voxflow.openai.apiKey"

    static let defaultAppTones: [String: ToneStyle] = [
        "com.tinyspeck.slackmacgap": .concise,
        "com.apple.mail": .formal,
        "com.microsoft.Outlook": .formal,
        "com.google.Chrome": .neutral,
        "com.apple.dt.Xcode": .neutral,
    ]

    init(state: AppState, backendManager: BackendProcessManager) {
        self.state = state
        self.backendManager = backendManager
    }

    func migrateAPIKeysToKeychain() {
        let defaults = UserDefaults.standard
        if let existingPrivateKey = defaults.string(forKey: privateAPIKeyKey), !existingPrivateKey.isEmpty {
            KeychainService.save(account: Self.keychainPrivateAPIKeyAccount, value: existingPrivateKey)
            defaults.removeObject(forKey: privateAPIKeyKey)
        }
        if let existingOpenAIKey = defaults.string(forKey: openAIAPIKeyKey), !existingOpenAIKey.isEmpty {
            KeychainService.save(account: Self.keychainOpenAIAPIKeyAccount, value: existingOpenAIKey)
            defaults.removeObject(forKey: openAIAPIKeyKey)
        }
    }

    func configureInitialState() {
        let defaults = UserDefaults.standard

        if let profileRawValue = defaults.string(forKey: translationProfileKey),
           let profile = TranslationProfile(rawValue: profileRawValue) {
            state.translationProfile = profile
        }

        if let sttRawValue = defaults.string(forKey: sttBackendKey),
           let sttBackend = STTBackend(rawValue: sttRawValue) {
            state.sttBackend = sttBackend
        } else {
            state.sttBackend = .voxtral
        }

        if let providerRawValue = defaults.string(forKey: providerModeKey),
           let provider = ProviderMode(rawValue: providerRawValue) {
            state.providerMode = provider
        }

        state.localVoxtralModel = defaults.string(forKey: sttModelKey) ?? "mistralai/Voxtral-Mini-3B-2507"
        state.localWhisperModel = defaults.string(forKey: whisperModelKey) ?? "openai/whisper-small"
        if defaults.object(forKey: voxtralSafeModeKey) == nil {
            state.voxtralSafeModeEnabled = true
            defaults.set(true, forKey: voxtralSafeModeKey)
        } else {
            state.voxtralSafeModeEnabled = defaults.bool(forKey: voxtralSafeModeKey)
        }
        state.privateAPIBaseURL = defaults.string(forKey: privateAPIBaseURLKey) ?? ""
        state.privateAPIModel = defaults.string(forKey: privateAPIModelKey) ?? "gpt-4o-mini"
        state.privateAPIKey = KeychainService.load(account: Self.keychainPrivateAPIKeyAccount) ?? ""
        state.openAIBaseURL = defaults.string(forKey: openAIBaseURLKey) ?? "https://api.openai.com"
        state.openAIAPIKey = KeychainService.load(account: Self.keychainOpenAIAPIKeyAccount) ?? ""
        state.openAISTTModel = defaults.string(forKey: openAISTTModelKey) ?? "whisper-1"
        state.openAITTSModel = defaults.string(forKey: openAITTSModelKey) ?? "gpt-4o-mini-tts"
        state.openAITTSVoice = defaults.string(forKey: openAITTSVoiceKey) ?? "alloy"
        state.translationModeEnabled = defaults.bool(forKey: translationModeEnabledKey)
        state.meetingModeEnabled = defaults.bool(forKey: meetingModeEnabledKey)
        if let dictationHotkeyRaw = defaults.string(forKey: dictationHotkeyPresetKey),
           let preset = DictationHotkeyPreset(rawValue: dictationHotkeyRaw) {
            state.dictationHotkeyPreset = preset
        }
        if let commandLaneHotkeyRaw = defaults.string(forKey: commandLaneHotkeyPresetKey),
           let preset = CommandLaneHotkeyPreset(rawValue: commandLaneHotkeyRaw) {
            state.commandLaneHotkeyPreset = preset
        }

        if let insertBehaviorRaw = defaults.string(forKey: insertBehaviorKey),
           let behavior = InsertBehavior(rawValue: insertBehaviorRaw) {
            state.insertBehavior = behavior
        }

        if let overridesData = defaults.data(forKey: appToneOverridesKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: overridesData) {
            state.appToneOverrides = decoded.compactMapValues { ToneStyle(rawValue: $0) }
        }

        let completed = defaults.bool(forKey: onboardingKey)
        if completed {
            state.onboardingPhase = .complete
            state.setIdle()
        } else {
            state.onboardingPhase = .calibrating
            state.sessionState = .onboarding
            state.calibrationItems = defaultCalibrationItems()
            state.activeCalibrationIndex = 0
            state.statusLine = "Calibration mode: hold hotkey, say phrase, release"
        }
    }

    func selectProviderMode(_ mode: ProviderMode) {
        guard state.providerMode != mode else { return }
        state.providerMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: providerModeKey)

        if mode == .localOnly {
            state.privacyPreview = nil
        }

        restartBackendWithCurrentConfiguration(status: "Provider: \(mode.displayName)")
    }

    func selectSTTBackend(_ backend: STTBackend) {
        guard state.sttBackend != backend else { return }
        state.sttBackend = backend
        UserDefaults.standard.set(backend.rawValue, forKey: sttBackendKey)

        restartBackendWithCurrentConfiguration(status: "STT backend: \(backend.displayName)")
    }

    func updateLocalSpeechModels(voxtralModel: String, whisperModel: String) {
        let trimmedVoxtral = voxtralModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWhisper = whisperModel.trimmingCharacters(in: .whitespacesAndNewlines)

        state.localVoxtralModel = trimmedVoxtral.isEmpty ? "mistralai/Voxtral-Mini-3B-2507" : trimmedVoxtral
        state.localWhisperModel = trimmedWhisper.isEmpty ? "openai/whisper-small" : trimmedWhisper

        UserDefaults.standard.set(state.localVoxtralModel, forKey: sttModelKey)
        UserDefaults.standard.set(state.localWhisperModel, forKey: whisperModelKey)

        restartBackendWithCurrentConfiguration(status: "Local speech models updated")
    }

    func setVoxtralSafeModeEnabled(_ isEnabled: Bool) {
        guard state.voxtralSafeModeEnabled != isEnabled else { return }

        state.voxtralSafeModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: voxtralSafeModeKey)

        let status = isEnabled
            ? "Voxtral safe mode enabled (fallback-first)"
            : "Pure Voxtral primary enabled (may fail under memory pressure)"
        restartBackendWithCurrentConfiguration(status: status)
    }

    func updatePrivateAPIConfig(baseURL: String, model: String, apiKey: String) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        state.privateAPIBaseURL = trimmedBaseURL
        state.privateAPIModel = trimmedModel
        state.privateAPIKey = trimmedKey

        UserDefaults.standard.set(trimmedBaseURL, forKey: privateAPIBaseURLKey)
        UserDefaults.standard.set(trimmedModel, forKey: privateAPIModelKey)
        KeychainService.save(account: Self.keychainPrivateAPIKeyAccount, value: trimmedKey)

        restartBackendWithCurrentConfiguration(status: "Private API configuration updated")
    }

    func updateOpenAIConfig(
        baseURL: String,
        apiKey: String,
        sttModel: String,
        ttsModel: String,
        ttsVoice: String
    ) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSTTModel = sttModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTTSModel = ttsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTTSVoice = ttsVoice.trimmingCharacters(in: .whitespacesAndNewlines)

        state.openAIBaseURL = trimmedBaseURL.isEmpty ? "https://api.openai.com" : trimmedBaseURL
        state.openAIAPIKey = trimmedAPIKey
        state.openAISTTModel = trimmedSTTModel.isEmpty ? "whisper-1" : trimmedSTTModel
        state.openAITTSModel = trimmedTTSModel.isEmpty ? "gpt-4o-mini-tts" : trimmedTTSModel
        state.openAITTSVoice = trimmedTTSVoice.isEmpty ? "alloy" : trimmedTTSVoice

        UserDefaults.standard.set(state.openAIBaseURL, forKey: openAIBaseURLKey)
        KeychainService.save(account: Self.keychainOpenAIAPIKeyAccount, value: state.openAIAPIKey)
        UserDefaults.standard.set(state.openAISTTModel, forKey: openAISTTModelKey)
        UserDefaults.standard.set(state.openAITTSModel, forKey: openAITTSModelKey)
        UserDefaults.standard.set(state.openAITTSVoice, forKey: openAITTSVoiceKey)

        restartBackendWithCurrentConfiguration(status: "OpenAI speech configuration updated")
    }

    func selectInsertBehavior(_ behavior: InsertBehavior) {
        guard state.insertBehavior != behavior else { return }
        state.insertBehavior = behavior
        UserDefaults.standard.set(behavior.rawValue, forKey: insertBehaviorKey)
        state.statusLine = "Insert behavior: \(behavior.displayName)"
    }

    func updateAppToneOverride(bundleID: String, tone: ToneStyle?) {
        if let tone {
            state.appToneOverrides[bundleID] = tone
        } else {
            state.appToneOverrides.removeValue(forKey: bundleID)
        }
        let encoded = state.appToneOverrides.mapValues { $0.rawValue }
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: appToneOverridesKey)
        }
    }

    func selectTranslationProfile(_ profile: TranslationProfile) {
        guard state.translationProfile != profile else { return }

        state.translationProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: translationProfileKey)

        restartBackendWithCurrentConfiguration(status: "Translate model: \(profile.displayName)")
    }

    func setTranslationModeEnabled(_ isEnabled: Bool) {
        state.translationModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: translationModeEnabledKey)

        if !isEnabled, state.workflowMode == .translateEnToDe {
            state.workflowMode = .dictation
        }

        state.statusLine = isEnabled
            ? "Translate experimental mode enabled"
            : "Translate experimental mode disabled"
    }

    func setMeetingModeEnabled(_ isEnabled: Bool) {
        state.meetingModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: meetingModeEnabledKey)

        if !isEnabled, state.workflowMode == .meeting {
            state.workflowMode = .dictation
        }

        state.statusLine = isEnabled
            ? "Meeting experimental mode enabled"
            : "Meeting experimental mode disabled"
    }

    func setDictationHotkeyPreset(_ preset: DictationHotkeyPreset) {
        guard state.dictationHotkeyPreset != preset else { return }
        state.dictationHotkeyPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: dictationHotkeyPresetKey)
        state.statusLine = "Dictation hotkey: \(preset.displayName)"
    }

    func setCommandLaneHotkeyPreset(_ preset: CommandLaneHotkeyPreset) {
        guard state.commandLaneHotkeyPreset != preset else { return }
        state.commandLaneHotkeyPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: commandLaneHotkeyPresetKey)
        state.statusLine = "Command hotkey: \(preset.displayName)"
    }

    func restartBackendWithCurrentConfiguration(status: String) {
        let launchConfiguration = currentBackendLaunchConfiguration()
        if backendManager.isRunning {
            backendManager.restartAsync(configuration: launchConfiguration)
        } else {
            backendManager.startIfNeededAsync(configuration: launchConfiguration)
        }

        state.statusLine = status
    }

    func currentBackendLaunchConfiguration() -> BackendLaunchConfiguration {
        backendLaunchConfiguration(for: state.translationProfile)
    }

    func backendLaunchConfiguration(for profile: TranslationProfile) -> BackendLaunchConfiguration {
        BackendLaunchConfiguration(
            sttBackend: state.sttBackend.rawValue,
            sttModel: state.localVoxtralModel,
            whisperModel: state.localWhisperModel,
            voxtralSafeModeEnabled: state.voxtralSafeModeEnabled,
            translateModel: profile.modelID,
            translateBackend: profile.backendKind,
            privateAPIBaseURL: state.privateAPIBaseURL,
            privateAPIModel: state.privateAPIModel,
            privateAPIKey: state.privateAPIKey,
            openAIBaseURL: state.openAIBaseURL,
            openAIAPIKey: state.openAIAPIKey,
            openAISTTModel: state.openAISTTModel,
            openAITTSModel: state.openAITTSModel,
            openAITTSVoice: state.openAITTSVoice
        )
    }

    private func defaultCalibrationItems() -> [CalibrationItem] {
        [
            CalibrationItem(expectedPhrase: "Schedule a team sync for Thursday at 2 PM."),
            CalibrationItem(expectedPhrase: "Please summarize today's project updates in three bullets."),
            CalibrationItem(expectedPhrase: "Draft a follow-up email and keep it concise.")
        ]
    }
}
