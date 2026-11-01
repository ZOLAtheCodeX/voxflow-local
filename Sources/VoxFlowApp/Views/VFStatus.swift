import SwiftUI

/// One status vocabulary for every surface: a symbol, a word and a color.
/// Color is never the only signal, so every kind carries a symbol and every
/// status carries a label. The mapping functions are pure so the pill, the
/// palette, the cockpit, Settings and the Dashboard all say the same thing
/// about the same state.
struct VFStatus: Equatable {

    enum Kind: CaseIterable {
        case ready
        case starting
        case listening
        case voiceControl
        case working
        case review
        case attention
        case error
        case inactive
        /// Neutral information: a capture that ended without inserting by
        /// design (a voice action, a voice-control command) or a reject. It
        /// makes no success or failure claim.
        case info
    }

    let kind: Kind
    let label: String

    init(_ kind: Kind, _ label: String) {
        self.kind = kind
        self.label = label
    }

    // MARK: - Presentation

    var symbol: String {
        switch kind {
        case .ready: return "checkmark.circle.fill"
        case .starting: return "hourglass"
        case .listening: return "waveform"
        case .voiceControl: return "command"
        case .working: return "ellipsis.circle"
        case .review: return "text.cursor"
        case .attention: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .inactive: return "minus.circle"
        case .info: return "info.circle"
        }
    }

    var color: Color {
        switch kind {
        case .ready: return VF.colorSuccess
        case .starting: return VF.colorNeutral
        case .listening: return VF.colorListening
        case .voiceControl: return VF.colorVoiceControl
        case .working: return VF.colorInfo
        case .review: return VF.colorInfo
        case .attention: return VF.colorWarning
        case .error: return VF.colorError
        case .inactive: return VF.colorNeutral
        case .info: return VF.colorNeutral
        }
    }

    /// True while the microphone is open. Later surfaces use it to decide
    /// where a (Reduce Motion aware) live cue is allowed.
    var isLive: Bool {
        switch kind {
        case .listening, .voiceControl: return true
        default: return false
        }
    }

    // MARK: - Defaults

    static let ready = VFStatus(.ready, "Ready")
    static let starting = VFStatus(.starting, "Starting")
    static let listening = VFStatus(.listening, "Listening")
    static let voiceControl = VFStatus(.voiceControl, "Voice control")
    static let review = VFStatus(.review, "Review")

    // MARK: - Mappings

    /// The command palette's status line.
    static func palette(
        sessionState: SessionState,
        isCommandLaneActive: Bool,
        dictationReady: Bool,
        isWarmingUp: Bool,
        hasTextTarget: Bool
    ) -> VFStatus {
        switch sessionState {
        case .recording:
            return isCommandLaneActive ? .voiceControl : .listening
        case .transcribing:
            return VFStatus(.working, "Transcribing")
        case .inserting:
            return VFStatus(.working, "Inserting")
        case .review:
            return .review
        case .onboarding:
            return VFStatus(.working, "Calibrating")
        case .error:
            return VFStatus(.error, "Failed")
        case .idle:
            if !dictationReady {
                return isWarmingUp ? .starting : VFStatus(.attention, "Not ready")
            }
            if !hasTextTarget {
                return VFStatus(.attention, "No text field")
            }
            return .ready
        }
    }

    /// The floating pill. Visible only while a capture is in flight.
    static func pill(sessionState: SessionState, isCommandLaneActive: Bool) -> VFStatus? {
        switch sessionState {
        case .recording:
            return isCommandLaneActive ? .voiceControl : .listening
        case .transcribing:
            return VFStatus(.working, "Transcribing")
        case .inserting:
            return VFStatus(.working, "Inserting")
        case .idle, .review, .onboarding, .error:
            return nil
        }
    }

    static func cockpit(_ state: LongFormState) -> VFStatus {
        switch state {
        case .idle: return .ready
        case .recording: return .listening
        case .reviewing: return .review
        }
    }

    /// The engine (local backend). "Not needed" is the predicate the
    /// Dashboard uses today: nothing wants it and nothing is running.
    static func engine(_ readiness: BackendReadinessState, backendShouldRun: Bool) -> VFStatus {
        if !backendShouldRun && !readiness.processRunning && !readiness.warmupInProgress {
            return VFStatus(.inactive, "Engine not needed")
        }
        if readiness.readyForDictation {
            return VFStatus(.ready, "Engine ready")
        }
        if readiness.warmupInProgress {
            return VFStatus(.starting, "Engine starting")
        }
        return VFStatus(.error, "Engine not ready")
    }

    static func speechModel(_ readiness: BackendReadinessState) -> VFStatus {
        if readiness.whisperKitReady || readiness.readyForDictation {
            return VFStatus(.ready, "Speech model ready")
        }
        return VFStatus(.starting, "Speech model loading")
    }
}
