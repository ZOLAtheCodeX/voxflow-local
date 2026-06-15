import Foundation
import os.log

@MainActor protocol SettingsCoordinating {
    func configureInitialState()
    func selectProviderMode(_ mode: ProviderMode)
    func selectSTTBackend(_ backend: STTBackend)
    func updateLocalWhisperModel(whisperModel: String)
    func updatePrivateAPIConfig(baseURL: String, model: String, apiKey: String)
    func updateOpenAIConfig(baseURL: String, apiKey: String, sttModel: String)
    func selectTranslationProfile(_ profile: TranslationProfile)
    func setTranslationModeEnabled(_ isEnabled: Bool)
    func setMeetingModeEnabled(_ isEnabled: Bool)
    func setPromptModeEnabled(_ isEnabled: Bool)
    func setProtocolCommandsEnabled(_ isEnabled: Bool)
    func setAssistantHandoffEnabled(_ isEnabled: Bool)
    func updateAssistantHandoffCommand(_ command: String)
    func setDictationHotkeyPreset(_ preset: DictationHotkeyPreset)
    func setCommandLaneHotkeyPreset(_ preset: CommandLaneHotkeyPreset)
    func selectInsertBehavior(_ behavior: InsertBehavior)
    func updateAppProfile(bundleID: String, profile: AppProfile?)
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
    private let promptModeEnabledKey = "voxflow.prompt.modeEnabled"
    private let protocolCommandsEnabledKey = "voxflow.protocols.enabled"
    private let handoffEnabledKey = "voxflow.handoff.enabled"
    private let handoffCommandKey = "voxflow.handoff.command"
    private let dictationHotkeyPresetKey = "voxflow.hotkey.dictationPreset"
    private let commandLaneHotkeyPresetKey = "voxflow.hotkey.commandLanePreset"
    private let sttBackendKey = "voxflow.stt.backend"
    private let whisperModelKey = "voxflow.whisper.model"
    private let insertBehaviorKey = "voxflow.dictation.insertBehavior"
    private let appToneOverridesKey = "voxflow.dictation.appToneOverrides"
    private let providerModeKey = "voxflow.provider.mode"
    private let privateAPIBaseURLKey = "voxflow.privateapi.baseURL"
    private let privateAPIModelKey = "voxflow.privateapi.model"
    private let privateAPIKeyKey = "voxflow.privateapi.key"
    private let openAIBaseURLKey = "voxflow.openai.baseURL"
    private let openAIAPIKeyKey = "voxflow.openai.apiKey"
    private let openAISTTModelKey = "voxflow.openai.sttModel"

    static let keychainPrivateAPIKeyAccount = "voxflow.privateapi.key"
    static let keychainOpenAIAPIKeyAccount = "voxflow.openai.apiKey"

    static let defaultAppProfiles: [String: AppProfile] = [
        "com.tinyspeck.slackmacgap": AppProfile(tone: .concise, cleanupMode: .raw, insertBehavior: .autoInsertRaw),
        "com.apple.mail": AppProfile(tone: .formal, cleanupMode: .light, insertBehavior: .alwaysReview),
        "com.microsoft.Outlook": AppProfile(tone: .formal, cleanupMode: .light, insertBehavior: .alwaysReview),
        "com.google.Chrome": AppProfile(tone: .neutral, cleanupMode: .polish, insertBehavior: .autoInsertPolish),
        "com.apple.dt.Xcode": AppProfile(tone: .neutral, cleanupMode: .raw, insertBehavior: .autoInsertRaw),
    ]

    /// Resolves Keychain-backed BYOM provider keys at launch-config build
    /// time. AppCoordinator points this at ProviderConfigStore after
    /// construction (the store is lazy; the coordinator is built in init).
    var providerKeysResolver: @MainActor () -> [String: String] = { [:] }

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
            state.sttBackend = .whisperKit
        }

        if let providerRawValue = defaults.string(forKey: providerModeKey),
           let provider = ProviderMode(rawValue: providerRawValue) {
            state.providerMode = provider
        }

        state.localWhisperModel = defaults.string(forKey: whisperModelKey) ?? "openai/whisper-small"
        state.privateAPIBaseURL = defaults.string(forKey: privateAPIBaseURLKey) ?? ""
        state.privateAPIModel = defaults.string(forKey: privateAPIModelKey) ?? "gpt-4o-mini"
        state.privateAPIKeyConfigured = !(KeychainService.load(account: Self.keychainPrivateAPIKeyAccount) ?? "").isEmpty
        state.openAIBaseURL = defaults.string(forKey: openAIBaseURLKey) ?? "https://api.openai.com"
        state.openAISTTModel = defaults.string(forKey: openAISTTModelKey) ?? "whisper-1"
        state.translationModeEnabled = defaults.bool(forKey: translationModeEnabledKey)
        state.meetingModeEnabled = defaults.bool(forKey: meetingModeEnabledKey)
        state.promptModeEnabled = defaults.bool(forKey: promptModeEnabledKey)
        state.protocolCommandsEnabled = defaults.bool(forKey: protocolCommandsEnabledKey)
        state.assistantHandoffEnabled = defaults.bool(forKey: handoffEnabledKey)
        state.assistantHandoffCommand = defaults.string(forKey: handoffCommandKey) ?? ""
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
        } else {
            state.insertBehavior = .autoInsertRaw
            defaults.set(state.insertBehavior.rawValue, forKey: insertBehaviorKey)
        }

        if let overridesData = defaults.data(forKey: appToneOverridesKey) {
            if let profiles = try? JSONDecoder().decode([String: AppProfile].self, from: overridesData) {
                state.appProfiles = profiles
            } else if let legacy = try? JSONDecoder().decode([String: String].self, from: overridesData) {
                state.appProfiles = legacy.compactMapValues { rawValue in
                    guard let tone = ToneStyle(rawValue: rawValue) else { return nil }
                    return AppProfile(tone: tone, cleanupMode: .raw, insertBehavior: .autoInsertRaw)
                }
                if let data = try? JSONEncoder().encode(state.appProfiles) {
                    defaults.set(data, forKey: appToneOverridesKey)
                }
            }
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

    func updateLocalWhisperModel(whisperModel: String) {
        let trimmed = whisperModel.trimmingCharacters(in: .whitespacesAndNewlines)
        state.localWhisperModel = trimmed.isEmpty ? "openai/whisper-small" : trimmed
        UserDefaults.standard.set(state.localWhisperModel, forKey: whisperModelKey)
        restartBackendWithCurrentConfiguration(status: "Local whisper model updated")
    }

    func updatePrivateAPIConfig(baseURL: String, model: String, apiKey: String) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        state.privateAPIBaseURL = trimmedBaseURL
        state.privateAPIModel = trimmedModel
        state.privateAPIKeyConfigured = !trimmedKey.isEmpty

        UserDefaults.standard.set(trimmedBaseURL, forKey: privateAPIBaseURLKey)
        UserDefaults.standard.set(trimmedModel, forKey: privateAPIModelKey)
        KeychainService.save(account: Self.keychainPrivateAPIKeyAccount, value: trimmedKey)

        restartBackendWithCurrentConfiguration(status: "Private API configuration updated")
    }

    func updateOpenAIConfig(baseURL: String, apiKey: String, sttModel: String) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSTTModel = sttModel.trimmingCharacters(in: .whitespacesAndNewlines)

        state.openAIBaseURL = trimmedBaseURL.isEmpty ? "https://api.openai.com" : trimmedBaseURL
        state.openAISTTModel = trimmedSTTModel.isEmpty ? "whisper-1" : trimmedSTTModel

        UserDefaults.standard.set(state.openAIBaseURL, forKey: openAIBaseURLKey)
        KeychainService.save(account: Self.keychainOpenAIAPIKeyAccount, value: trimmedAPIKey)
        UserDefaults.standard.set(state.openAISTTModel, forKey: openAISTTModelKey)

        restartBackendWithCurrentConfiguration(status: "OpenAI speech configuration updated")
    }

    func selectInsertBehavior(_ behavior: InsertBehavior) {
        guard state.insertBehavior != behavior else { return }
        state.insertBehavior = behavior
        UserDefaults.standard.set(behavior.rawValue, forKey: insertBehaviorKey)
        restartBackendWithCurrentConfiguration(status: "Insert behavior: \(behavior.displayName)")
    }

    func updateAppProfile(bundleID: String, profile: AppProfile?) {
        if let profile {
            state.appProfiles[bundleID] = profile
        } else {
            state.appProfiles.removeValue(forKey: bundleID)
        }
        if let data = try? JSONEncoder().encode(state.appProfiles) {
            UserDefaults.standard.set(data, forKey: appToneOverridesKey)
        }
        restartBackendWithCurrentConfiguration(status: "App profile updated")
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

    func setPromptModeEnabled(_ isEnabled: Bool) {
        state.promptModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: promptModeEnabledKey)

        if !isEnabled, state.workflowMode == .prompt {
            state.workflowMode = .dictation
        }

        state.statusLine = isEnabled
            ? "Prompt experimental mode enabled"
            : "Prompt experimental mode disabled"
    }

    func setProtocolCommandsEnabled(_ isEnabled: Bool) {
        state.protocolCommandsEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: protocolCommandsEnabledKey)
        state.statusLine = isEnabled
            ? "Protocol commands enabled — say 'run <name> protocol' in the command lane"
            : "Protocol commands disabled"
    }

    func setAssistantHandoffEnabled(_ isEnabled: Bool) {
        state.assistantHandoffEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: handoffEnabledKey)
        state.statusLine = isEnabled ? "Assistant handoff enabled" : "Assistant handoff disabled"
    }

    func updateAssistantHandoffCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        state.assistantHandoffCommand = trimmed
        UserDefaults.standard.set(trimmed, forKey: handoffCommandKey)
    }

    func setDictationHotkeyPreset(_ preset: DictationHotkeyPreset) {
        guard state.dictationHotkeyPreset != preset else { return }

        if !preset.usesFlagsMonitor {
            let dictConfig = preset.configuration
            let cmdConfig = state.commandLaneHotkeyPreset.configuration
            if dictConfig.keyCode == cmdConfig.keyCode && dictConfig.modifiers == cmdConfig.modifiers {
                log.warning("Dictation preset '\(preset.displayName)' conflicts with command lane '\(self.state.commandLaneHotkeyPreset.displayName)'")
                state.errorMessage = "'\(preset.displayName)' conflicts with command lane hotkey. Change one to avoid issues."
                return
            }
        }

        state.dictationHotkeyPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: dictationHotkeyPresetKey)
        state.statusLine = "Dictation hotkey: \(preset.displayName)"
    }

    func setCommandLaneHotkeyPreset(_ preset: CommandLaneHotkeyPreset) {
        guard state.commandLaneHotkeyPreset != preset else { return }

        if !state.dictationHotkeyPreset.usesFlagsMonitor {
            let dictConfig = state.dictationHotkeyPreset.configuration
            let cmdConfig = preset.configuration
            if dictConfig.keyCode == cmdConfig.keyCode && dictConfig.modifiers == cmdConfig.modifiers {
                log.warning("Command lane preset '\(preset.displayName)' conflicts with dictation '\(self.state.dictationHotkeyPreset.displayName)'")
                state.errorMessage = "'\(preset.displayName)' conflicts with dictation hotkey. Change one to avoid issues."
                return
            }
        }

        state.commandLaneHotkeyPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: commandLaneHotkeyPresetKey)
        state.statusLine = "Command hotkey: \(preset.displayName)"
    }

    func restartBackendWithCurrentConfiguration(status: String) {
        let launchConfiguration = currentBackendLaunchConfiguration()
        if state.backendShouldRun {
            state.backendReadiness.processRunning = true
            state.backendReadiness.warmupInProgress = true
            state.backendReadiness.readyForDictation = false
            state.backendReadiness.readinessIssue = nil
            state.backendReadiness.statusSummary = backendManager.isRunning
                ? "Backend reloading — applying new configuration"
                : "Backend starting — waiting for warmup"
            state.backendReadiness.activeSTTModel = ""
            backendManager.startIfNeededAsync(configuration: launchConfiguration)
        } else {
            backendManager.stopAsync()
            state.backendReadiness.processRunning = false
            state.backendReadiness.warmupInProgress = false
            state.backendReadiness.readyForDictation = false
            state.backendReadiness.readinessIssue = nil
            state.backendReadiness.statusSummary = "Backend idle — current workflow runs in app"
            state.backendReadiness.activeSTTModel = state.sttBackend == .whisperKit ? "whisperkit (in-app)" : ""
        }

        state.statusLine = status
    }

    func currentBackendLaunchConfiguration() -> BackendLaunchConfiguration {
        backendLaunchConfiguration(for: state.translationProfile)
    }

    func backendLaunchConfiguration(for profile: TranslationProfile) -> BackendLaunchConfiguration {
        BackendLaunchConfiguration(
            sttBackend: state.sttBackend.rawValue,
            sttModel: state.localWhisperModel,
            whisperModel: state.localWhisperModel,
            translateModel: profile.modelID,
            translateBackend: profile.backendKind,
            privateAPIBaseURL: state.privateAPIBaseURL,
            privateAPIModel: state.privateAPIModel,
            // Secrets read from the Keychain at build time — never held in
            // AppState (audit S10).
            privateAPIKey: KeychainService.load(account: Self.keychainPrivateAPIKeyAccount) ?? "",
            openAIBaseURL: state.openAIBaseURL,
            openAIAPIKey: KeychainService.load(account: Self.keychainOpenAIAPIKeyAccount) ?? "",
            openAISTTModel: state.openAISTTModel,
            providerKeys: providerKeysResolver()
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
