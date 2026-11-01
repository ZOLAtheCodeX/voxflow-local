import Foundation

/// User-facing strings that more than one surface shows, kept in one place so
/// the palette, Settings and the Dashboard say the same thing. Pure functions;
/// no state, no side effects.
enum VFCopy {

    /// How long a smart action runs before the slow-run notice appears.
    static let slowRunThresholdSeconds = 15

    /// The one-line description of what cleans up dictated text.
    /// An empty provider means the configured chain fell through to the
    /// built-in rules (degraded); the `rules` sentinel is a deliberate choice.
    static func cleanupProviderLabel(provider: String, model: String) -> String {
        if provider.isEmpty {
            return "Cleanup: local rules, fallback"
        }
        if provider == ProviderConfigStore.rulesSentinel {
            return "Cleanup: local rules"
        }
        if model.isEmpty {
            return "Cleanup: \(provider)"
        }
        return "Cleanup: \(provider) · \(model)"
    }

    /// True when cleanup fell back to the built-in rules without the user
    /// having chosen them.
    static func isCleanupDegraded(provider: String) -> Bool {
        provider.isEmpty
    }

    static func hotkeyHint(dictation: DictationHotkeyPreset, voiceControl: CommandLaneHotkeyPreset) -> String {
        "Hold \(dictation.displayName) to dictate · \(voiceControl.displayName) for voice control"
    }

    /// The palette header's lines under the status badge (ruling R28).
    ///
    /// The status line shows in every state, ready included, as it did before
    /// the UI refresh: after an insert the coordinator appends lost-text
    /// warnings to it ("may be incomplete (last ~N s not transcribed)", a
    /// capture length limit) that no receipt records, so the palette is the
    /// only place they appear. The hotkey hint is a third line only until the
    /// first capture is receipted (first run); after that it is not shown.
    static func paletteHeaderLines(statusLine: String, hint: String, hasReceipt: Bool) -> PaletteHeaderLines {
        PaletteHeaderLines(statusLine: statusLine, hint: hasReceipt ? nil : hint)
    }

    /// Shown while a smart action is still running after the threshold.
    static func slowRunNotice(elapsedSeconds: Int) -> String? {
        guard elapsedSeconds >= slowRunThresholdSeconds else { return nil }
        return "Still working. The first run after a pause can take up to a minute while the model loads."
    }

    /// A receipt's reject reason code in plain words. Unknown codes are
    /// shown with underscores as spaces rather than hidden.
    static func rejectReasonText(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "No reason recorded" }
        switch code {
        case "silence": return "No speech detected"
        case "empty", "placeholder": return "Nothing was transcribed"
        case "hallucination_filter": return "Filtered out as likely not speech"
        case "low_confidence": return "Recognition confidence too low"
        case "transcription_error": return "Transcription failed"
        case "interrupted_tail": return "Recording was interrupted"
        case "capture_stalled": return "The microphone delivered no audio"
        case "device_changed": return "The audio device changed"
        default:
            let words = code.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// Maps a raw "true" / "false" flag to words. Anything else is returned
    /// unchanged; nil reads as unknown.
    static func yesNo(_ raw: String?) -> String {
        switch raw {
        case "true": return "Yes"
        case "false": return "No"
        case nil: return "Unknown"
        case let other?: return other
        }
    }
}

/// What `VFCopy.paletteHeaderLines` returns: the status line, always, and
/// the hotkey hint while there is no receipt yet.
struct PaletteHeaderLines: Equatable {
    let statusLine: String
    let hint: String?
}
