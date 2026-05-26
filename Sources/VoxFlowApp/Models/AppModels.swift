import Foundation
import Carbon.HIToolbox

enum CleanupMode: String, CaseIterable, Identifiable, Codable {
    case raw
    case light
    case polish

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .raw:
            return "Raw"
        case .light:
            return "Light"
        case .polish:
            return "Polish"
        }
    }
}

enum SessionState: String {
    case idle
    case recording
    case transcribing
    case review
    case inserting
    case onboarding
    case error
}

enum WorkflowMode: String, CaseIterable, Identifiable, Hashable, Codable {
    case dictation
    case translateEnToDe
    case meeting
    case prompt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dictation:
            return "Dictation"
        case .translateEnToDe:
            return "Translate EN→DE"
        case .meeting:
            return "Meeting"
        case .prompt:
            return "Prompt"
        }
    }
}

enum PromptIntent: String, CaseIterable, Identifiable, Codable {
    case email
    case code
    case explain
    case creative
    case data
    case general

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email: return "Email"
        case .code: return "Code"
        case .explain: return "Explain"
        case .creative: return "Creative"
        case .data: return "Data"
        case .general: return "General"
        }
    }
}

struct PromptCandidate {
    let sessionID: String
    let rawText: String
    let cleanedText: String
    let framedPrompt: String
    let detectedIntent: PromptIntent
}

struct PipelineStageTiming {
    let name: String
    let durationMs: Int
    let detail: String?
}

struct CapturePipelineTrace {
    let sessionID: String
    let workflowMode: WorkflowMode
    let sttBackend: STTBackend
    let providerMode: ProviderMode
    let commandLane: Bool
    let audioDurationMs: Int?
    let totalDurationMs: Int
    let sessionState: SessionState
    let statusLine: String
    let recordedAt: Date
    let stageTimings: [PipelineStageTiming]

    var stageSummary: String {
        stageTimings
            .map { stage in
                let detailSuffix: String
                if let detail = stage.detail, !detail.isEmpty {
                    detailSuffix = " (\(detail))"
                } else {
                    detailSuffix = ""
                }
                return "\(stage.name)=\(stage.durationMs)ms\(detailSuffix)"
            }
            .joined(separator: ", ")
    }
}

enum ToneStyle: String, CaseIterable, Identifiable, Codable {
    case neutral
    case concise
    case formal
    case friendly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neutral:
            return "Neutral"
        case .concise:
            return "Concise"
        case .formal:
            return "Formal"
        case .friendly:
            return "Friendly"
        }
    }
}

enum ProviderMode: String, CaseIterable, Identifiable, Codable {
    case localOnly
    case privateAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localOnly:
            return "Local Models"
        case .privateAPI:
            return "Private API"
        }
    }
}

enum STTBackend: String, CaseIterable, Identifiable, Codable {
    case whisper
    case whisperKit
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper:
            return "Whisper (Local)"
        case .whisperKit:
            return "WhisperKit (Local, Neural Engine)"
        case .openAI:
            return "OpenAI STT"
        }
    }
}

enum InsertBehavior: String, CaseIterable, Identifiable, Codable {
    case alwaysReview
    case autoInsertRaw
    case autoInsertLight
    case autoInsertPolish

    var id: String { rawValue }

    var cleanupMode: CleanupMode? {
        switch self {
        case .alwaysReview: return nil
        case .autoInsertRaw: return .raw
        case .autoInsertLight: return .light
        case .autoInsertPolish: return .polish
        }
    }

    var displayName: String {
        switch self {
        case .alwaysReview: return "Always Review"
        case .autoInsertRaw: return "Auto-Insert Raw"
        case .autoInsertLight: return "Auto-Insert Light"
        case .autoInsertPolish: return "Auto-Insert Polish"
        }
    }
}

struct AppProfile: Codable, Equatable {
    var tone: ToneStyle
    var cleanupMode: CleanupMode
    var insertBehavior: InsertBehavior
}

enum PrivacyOperationKind: String, Codable {
    case cleanup
    case translate
    case meeting
}

enum TranslationProfile: String, CaseIterable, Identifiable, Codable, Hashable {
    case translateGemma4B
    case translateGemma12B
    case marianFallback

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .translateGemma4B:
            return "TranslateGemma 4B"
        case .translateGemma12B:
            return "TranslateGemma 12B"
        case .marianFallback:
            return "Marian Fallback"
        }
    }

    var modelID: String {
        switch self {
        case .translateGemma4B:
            return "google/translategemma-4b-it"
        case .translateGemma12B:
            return "google/translategemma-12b-it"
        case .marianFallback:
            return "Helsinki-NLP/opus-mt-en-de"
        }
    }

    var backendKind: String {
        switch self {
        case .translateGemma4B, .translateGemma12B:
            return "translategemma"
        case .marianFallback:
            return "marian"
        }
    }

    var runtimeNote: String {
        switch self {
        case .translateGemma4B:
            return "Balanced quality/latency on Apple Silicon."
        case .translateGemma12B:
            return "Higher quality, heavier memory usage."
        case .marianFallback:
            return "Fast and memory-light fallback model."
        }
    }

    func runtimeHint(forHostMemoryGB memoryGB: Int) -> TranslationRuntimeHint {
        switch self {
        case .translateGemma4B:
            if memoryGB >= 16 {
                return TranslationRuntimeHint(
                    badge: "Balanced",
                    summary: "~1.2-2.2s latency, good quality on this Mac.",
                    suitability: .recommended
                )
            } else if memoryGB >= 12 {
                return TranslationRuntimeHint(
                    badge: "Caution",
                    summary: "Usable, but likely slower under multitasking.",
                    suitability: .caution
                )
            }
            return TranslationRuntimeHint(
                badge: "Heavy",
                summary: "Likely memory pressure. Prefer Marian fallback.",
                suitability: .heavy
            )
        case .translateGemma12B:
            if memoryGB >= 32 {
                return TranslationRuntimeHint(
                    badge: "High Quality",
                    summary: "Best quality with acceptable latency for local use.",
                    suitability: .recommended
                )
            } else if memoryGB >= 24 {
                return TranslationRuntimeHint(
                    badge: "Caution",
                    summary: "High quality but can be slow and memory-heavy.",
                    suitability: .caution
                )
            }
            return TranslationRuntimeHint(
                badge: "Too Heavy",
                summary: "Not recommended on this RAM tier.",
                suitability: .heavy
            )
        case .marianFallback:
            if memoryGB >= 8 {
                return TranslationRuntimeHint(
                    badge: "Fast",
                    summary: "~0.4-1.0s latency, lower-quality but stable.",
                    suitability: .recommended
                )
            }
            return TranslationRuntimeHint(
                badge: "Light",
                summary: "Best option for constrained memory devices.",
                suitability: .caution
            )
        }
    }
}

enum TranslationSuitability {
    case recommended
    case caution
    case heavy
}

struct TranslationRuntimeHint {
    let badge: String
    let summary: String
    let suitability: TranslationSuitability
}

struct TranslationBenchmarkResult: Identifiable, Hashable {
    let id = UUID()
    let profile: TranslationProfile
    let medianLatencyMs: Int
    let p95LatencyMs: Int
    let runs: Int
    let placeholderDetected: Bool
}

struct WorkflowUsageMetric: Identifiable, Hashable {
    let mode: WorkflowMode
    let captures: Int

    var id: String { mode.rawValue }
}

struct TranslationBenchmarkHistoryStats: Identifiable, Hashable {
    let profile: TranslationProfile
    var benchmarkRuns: Int
    var successfulRuns: Int
    var placeholderRuns: Int
    var totalMedianLatencyMs: Int
    var totalP95LatencyMs: Int
    var lastMedianLatencyMs: Int?
    var lastP95LatencyMs: Int?

    var id: String { profile.rawValue }

    var averageMedianLatencyMs: Int {
        guard successfulRuns > 0 else { return 0 }
        return totalMedianLatencyMs / successfulRuns
    }

    var averageP95LatencyMs: Int {
        guard successfulRuns > 0 else { return 0 }
        return totalP95LatencyMs / successfulRuns
    }

    var recommendationScore: Int {
        guard successfulRuns > 0 else { return Int.max }
        return averageMedianLatencyMs + (averageP95LatencyMs / 4) + (placeholderRuns * 2_000)
    }
}

enum TargetingMode: String, CaseIterable, Identifiable {
    case anyApp
    case cursorAware
    case textFieldOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anyApp:
            return "Any App (clipboard fallback)"
        case .cursorAware:
            return "Follow Active Cursor"
        case .textFieldOnly:
            return "Text Field Only"
        }
    }
}

enum OnboardingPhase: String {
    case notStarted
    case calibrating
    case complete
}

struct TranscriptCandidate: Identifiable {
    let id = UUID()
    var rawText: String
    var lightText: String
    var polishText: String
    var selectedMode: CleanupMode
    var confidence: Double = 0.0
    var timestamp: Date = Date()

    func text(for mode: CleanupMode) -> String {
        switch mode {
        case .raw:
            return rawText
        case .light:
            return lightText
        case .polish:
            return polishText
        }
    }
}

struct InsertResult {
    let method: InsertMethod
    let success: Bool
    let fallbackUsed: Bool
    let errorCode: String?

    enum InsertMethod: String {
        case accessibilityDirect
        case simulatedPaste
        case failed
    }
}

struct AppInsertStats: Identifiable, Hashable {
    let appName: String
    var successCount: Int
    var fallbackCount: Int
    var failedCount: Int

    var id: String { appName }

    var totalAttempts: Int {
        successCount + failedCount
    }

    var successRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(successCount) / Double(totalAttempts)
    }
}

struct HotkeyConfiguration {
    var keyCode: UInt32
    var modifiers: UInt32
    static let fnModifierMask: UInt32 = 0x0080_0000

    static let `default` = HotkeyConfiguration(
        keyCode: spaceKeyCode,
        modifiers: UInt32(controlKey) | UInt32(optionKey)
    )

    static let commandLane = HotkeyConfiguration(
        keyCode: spaceKeyCode,
        modifiers: UInt32(cmdKey) | fnModifierMask
    )

    static let spaceKeyCode: UInt32 = 49
}

enum DictationHotkeyPreset: String, CaseIterable, Identifiable, Codable {
    case fnOnly
    case fnCommandSpace
    case controlOptionSpace
    case controlShiftSpace
    case optionShiftSpace

    var id: String { rawValue }

    var usesFlagsMonitor: Bool {
        self == .fnOnly
    }

    var displayName: String {
        switch self {
        case .fnOnly:
            return "Fn"
        case .fnCommandSpace:
            return "Fn + Command + Space"
        case .controlOptionSpace:
            return "Control + Option + Space"
        case .controlShiftSpace:
            return "Control + Shift + Space"
        case .optionShiftSpace:
            return "Option + Shift + Space"
        }
    }

    var configuration: HotkeyConfiguration {
        let modifiers: UInt32
        switch self {
        case .fnOnly:
            // Fn-only is handled by FnHoldHotkeyService; this fallback is never registered.
            modifiers = UInt32(controlKey) | UInt32(optionKey)
        case .fnCommandSpace:
            modifiers = UInt32(cmdKey) | HotkeyConfiguration.fnModifierMask
        case .controlOptionSpace:
            modifiers = UInt32(controlKey) | UInt32(optionKey)
        case .controlShiftSpace:
            modifiers = UInt32(controlKey) | UInt32(shiftKey)
        case .optionShiftSpace:
            modifiers = UInt32(optionKey) | UInt32(shiftKey)
        }
        return HotkeyConfiguration(keyCode: HotkeyConfiguration.spaceKeyCode, modifiers: modifiers)
    }
}

enum CommandLaneHotkeyPreset: String, CaseIterable, Identifiable, Codable {
    case fnCommandSpace
    case fnOptionSpace
    case fnControlSpace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fnCommandSpace:
            return "Fn + Command + Space"
        case .fnOptionSpace:
            return "Fn + Option + Space"
        case .fnControlSpace:
            return "Fn + Control + Space"
        }
    }

    var configuration: HotkeyConfiguration {
        let modifiers: UInt32
        switch self {
        case .fnCommandSpace:
            modifiers = UInt32(cmdKey) | HotkeyConfiguration.fnModifierMask
        case .fnOptionSpace:
            modifiers = UInt32(optionKey) | HotkeyConfiguration.fnModifierMask
        case .fnControlSpace:
            modifiers = UInt32(controlKey) | HotkeyConfiguration.fnModifierMask
        }
        return HotkeyConfiguration(keyCode: HotkeyConfiguration.spaceKeyCode, modifiers: modifiers)
    }
}

struct FocusTargetSnapshot: Codable, Sendable, Equatable {
    let hasFocusedTextInput: Bool
    let hasInsertionCursor: Bool
    let appName: String?
    let bundleID: String?
    let role: String?

    static let unavailable = FocusTargetSnapshot(
        hasFocusedTextInput: false,
        hasInsertionCursor: false,
        appName: nil,
        bundleID: nil,
        role: nil
    )
}

struct CalibrationItem: Identifiable, Hashable {
    let id = UUID()
    let expectedPhrase: String
    var heardPhrase: String?
    var score: Double?
}

struct TranslationCandidate {
    let sourceEnglish: String
    let targetGerman: String
    var approved: Bool
}

struct MeetingSpeakerSegment: Identifiable, Hashable {
    let speaker: String
    let text: String
    let utteranceCount: Int

    var id: String { "\(speaker)-\(utteranceCount)-\(text.prefix(24))" }
}

struct MeetingTaskOwner: Identifiable, Hashable {
    let task: String
    let owner: String
    let confidence: Double

    var id: String { "\(task)-\(owner)" }
}

struct MeetingCandidate {
    let transcript: String
    let summary: String
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let speakerSegments: [MeetingSpeakerSegment]
    let taskOwners: [MeetingTaskOwner]
    let markdownExport: String
    let notionExport: String
    var approved: Bool

    var formattedNotes: String {
        var lines: [String] = []
        lines.append("Summary")
        lines.append(summary)
        lines.append("")
        lines.append("Decisions")
        if decisions.isEmpty {
            lines.append("- None captured")
        } else {
            lines.append(contentsOf: decisions.map { "- \($0)" })
        }
        lines.append("")
        lines.append("Action Items")
        if actionItems.isEmpty {
            lines.append("- None captured")
        } else {
            lines.append(contentsOf: actionItems.map { "- \($0)" })
        }
        lines.append("")
        lines.append("Follow Ups")
        if followUps.isEmpty {
            lines.append("- None captured")
        } else {
            lines.append(contentsOf: followUps.map { "- \($0)" })
        }

        lines.append("")
        lines.append("Task Owners")
        if taskOwners.isEmpty {
            lines.append("- None inferred")
        } else {
            lines.append(contentsOf: taskOwners.map {
                let confidence = Int(($0.confidence * 100).rounded())
                return "- \($0.task) -> \($0.owner) (\(confidence)%)"
            })
        }

        lines.append("")
        lines.append("Speaker Segments")
        if speakerSegments.isEmpty {
            lines.append("- None inferred")
        } else {
            lines.append(contentsOf: speakerSegments.map {
                "- \($0.speaker) (\($0.utteranceCount)): \($0.text)"
            })
        }
        return lines.joined(separator: "\n")
    }

    var markdownTemplate: String {
        if !markdownExport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return markdownExport
        }
        return formattedNotes
    }

    var notionTemplate: String {
        if !notionExport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return notionExport
        }
        return formattedNotes
    }
}

extension MeetingCandidate {
    init(from response: MeetingSummaryResponse) {
        self.init(
            transcript: response.transcript,
            summary: response.summary,
            decisions: response.decisions,
            actionItems: response.actionItems,
            followUps: response.followUps,
            speakerSegments: response.speakerSegments.map {
                MeetingSpeakerSegment(speaker: $0.speaker, text: $0.text, utteranceCount: max(1, $0.utteranceCount))
            },
            taskOwners: response.taskOwners.map {
                MeetingTaskOwner(task: $0.task, owner: $0.owner, confidence: min(1.0, max(0.0, $0.confidence)))
            },
            markdownExport: response.markdownExport,
            notionExport: response.notionExport,
            approved: false
        )
    }
}

struct PrivacyPreview {
    let operation: PrivacyOperationKind
    let token: String
    let originalText: String
    let redactedText: String
}

// MARK: - Cockpit Layer 0 (Smart Actions)

enum SmartActionId: String, Codable, CaseIterable, Sendable {
    case memo
    case mece
    case items
    case steel
    case pyramid
    case disclaimer

    var label: String {
        switch self {
        case .memo: return "memo"
        case .mece: return "MECE"
        case .items: return "action items"
        case .steel: return "steel-man"
        case .pyramid: return "Pyramid"
        case .disclaimer: return "disclaimer"
        }
    }

    var shortDescription: String {
        switch self {
        case .memo: return "Issue / Analysis / Recommendation"
        case .mece: return "Mutually exclusive bullet groups"
        case .items: return "Extract action items"
        case .steel: return "Steel-man the position"
        case .pyramid: return "Pyramid Principle structure"
        case .disclaimer: return "Append your disclaimer"
        }
    }
}

struct SmartActionResult: Sendable, Equatable {
    let actionId: SmartActionId
    let output: String
    let guardrailTriggered: Bool
    let error: String?
}

struct AppliedAction: Codable, Sendable, Equatable {
    let actionId: SmartActionId
    let appliedAt: Date
    let beforeText: String
    let afterText: String
}

struct LongFormSession: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    var transcript: String
    var targetApp: FocusTargetSnapshot?
    var appliedActions: [AppliedAction]
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcript: String = "",
        targetApp: FocusTargetSnapshot? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcript = transcript
        self.targetApp = targetApp
        self.appliedActions = []
        self.updatedAt = createdAt
    }
}

enum LongFormState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date)
    case reviewing
}

extension ContinuousClock.Instant {
    func elapsedMilliseconds() -> Int {
        let duration = self.duration(to: .now)
        return Int(duration.components.seconds) * 1000
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
