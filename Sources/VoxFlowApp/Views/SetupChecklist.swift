import Foundation

/// The decisions behind the Setup checklist, kept pure so they are tested and
/// the view stays a thin layout over them.
enum SetupChecklist {

    // MARK: - Progress

    /// Calibration counts as done only when it ran or was skipped on purpose
    /// (`.complete`); "not calibrating" is not "calibrated".
    static func progress(
        microphone: Bool,
        accessibility: Bool,
        engineReady: Bool,
        onboardingPhase: OnboardingPhase
    ) -> SetupProgress {
        SetupProgress(
            microphone: microphone,
            accessibility: accessibility,
            engine: engineReady,
            calibration: onboardingPhase == .complete
        )
    }

    /// The speech engine is ready when the app's own readiness poll says so
    /// (the same predicate as the Welcome badge) or the last health check did.
    static func engineReady(readiness: BackendReadinessState, healthCheckReady: Bool) -> Bool {
        readiness.whisperKitReady || readiness.readyForDictation || healthCheckReady
    }

    static func summary(_ progress: SetupProgress) -> String {
        switch progress.remainingRequired {
        case 0: return "Required steps are done."
        case 1: return "1 required step left."
        case let n: return "\(n) required steps left."
        }
    }

    // MARK: - Row statuses

    static func permissionStatus(_ granted: Bool) -> VFStatus {
        granted ? VFStatus(.ready, "Granted") : VFStatus(.attention, "Needed")
    }

    static func engineStatus(ready: Bool, starting: Bool) -> VFStatus {
        if ready { return VFStatus(.ready, "Ready") }
        if starting { return VFStatus(.starting, "Starting") }
        return VFStatus(.attention, "Not ready")
    }

    static func calibrationStatus(_ phase: OnboardingPhase) -> VFStatus {
        switch phase {
        case .complete: return VFStatus(.ready, "Done")
        case .calibrating: return VFStatus(.working, "In progress")
        case .notStarted: return VFStatus(.inactive, "Not done")
        }
    }

    /// The "Try it" line's badge.
    static func tryIt(remainingRequired: Int, canStartCapture: Bool, appName: String?) -> VFStatus {
        if remainingRequired > 0 {
            return VFStatus(.inactive, "Finish the required steps first")
        }
        guard canStartCapture else {
            return VFStatus(.attention, "No text field detected")
        }
        let name = (appName?.isEmpty ?? true) ? "The active app" : appName!
        return VFStatus(.ready, "\(name) is ready")
    }

    // MARK: - Health details

    struct DetailRow: Equatable {
        let label: String
        let value: String
    }

    /// The engine's health keys as labeled rows. Yes/no flags read as words;
    /// a missing check reads "Unknown"; Issues appears only when there are some.
    static func detailRows(_ health: [String: String]) -> [DetailRow] {
        func value(_ key: String) -> String {
            let text = VFCopy.yesNo(health[key])
            return text == "ok" ? "OK" : text
        }
        var rows = [
            DetailRow(label: "Engine status", value: value("service_status")),
            DetailRow(label: "Ready for dictation", value: value("ready_for_dictation")),
            DetailRow(label: "Speech model loaded", value: value("model_loaded")),
            DetailRow(label: "Speech engine", value: value("stt_backend")),
            DetailRow(label: "Active model", value: value("active_stt_model")),
            DetailRow(label: "Cloud fallback in use", value: value("stt_fallback_active")),
            DetailRow(label: "Offline mode", value: value("offline_mode")),
        ]
        if let issues = health["issues"], !issues.isEmpty {
            rows.append(DetailRow(label: "Issues", value: issues))
        }
        return rows
    }

    /// The one-line result of a health check.
    static func healthMessage(reachable: Bool, ready: Bool, firstIssue: String?) -> String {
        guard reachable else {
            return "Engine unreachable. Choose Start Engine, then Check Again."
        }
        if ready {
            return "Engine ready: the speech model is loaded."
        }
        return "Engine reachable but not ready: \(firstIssue ?? "the speech model is not loaded.")"
    }
}
