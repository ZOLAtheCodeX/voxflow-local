import Foundation

/// Builds the short provenance tag appended to an insertion's status/audit
/// suffix so the JSONL receipt can answer the single most important polish
/// question — "did this dictation actually reach the Gemma/Ollama model, or
/// fall back to the regex floor / in-app cleanup?"
///
/// The backend already returns `served_by`/`model_id` on every `/v1/cleanup`
/// response, but Swift used to drop them (decoding only `outputText`), so a real
/// Gemma run and a silent regex-floor fallback wrote byte-identical audit
/// receipts. This closes that forensic blind spot.
enum PolishProvenance {
    /// Marker for the in-app Swift `TextCleanupService` path, taken when the
    /// backend is cold/absent. Distinct from the backend's own regex floor.
    static let inApp = "in-app cleanup"

    /// A concise human-readable provenance tag from a backend cleanup response.
    /// Returns "" when provenance is unknown (older/lean responses) so callers
    /// can omit the tag rather than print a misleading label.
    static func label(servedBy: String?, modelId: String?) -> String {
        guard let servedBy, !servedBy.isEmpty else { return "" }
        switch servedBy {
        case "regex":
            return "regex fallback"
        case "rules":
            return "rules"
        default:
            // A real provider (e.g. "ollama"); the model id is the most
            // informative label when present, else fall back to the provider id.
            if let modelId, !modelId.isEmpty { return modelId }
            return servedBy
        }
    }
}
