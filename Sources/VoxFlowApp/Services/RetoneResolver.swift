import Foundation

/// Resolves the (light, polish) candidate pair for a review-mode tone change.
///
/// Mirrors the dictation path's resilience: try the backend LLM when it's warm,
/// degrade to the in-app `TextCleanupService` on a genuine backend failure so
/// the tone still applies, and propagate cancellation so a superseded retone
/// aborts instead of overwriting a newer selection with stale tone.
enum RetoneResolver {
    @MainActor
    static func resolve(
        rawText: String,
        tone: ToneStyle,
        useBackend: Bool,
        backendCleanup: (CleanupMode) async throws -> String
    ) async throws -> (light: String, polish: String) {
        func local() -> (light: String, polish: String) {
            (TextCleanupService.cleanup(rawText, mode: .light, tone: tone),
             TextCleanupService.cleanup(rawText, mode: .polish, tone: tone))
        }

        guard useBackend else { return local() }

        do {
            let light = try await backendCleanup(.light)
            let polish = try await backendCleanup(.polish)
            return (light, polish)
        } catch {
            // Cancellation (a newer retone superseded this one) must abort, not
            // fall back — applying stale tone over a newer selection would be
            // wrong. Normalize URLError.cancelled to CancellationError so the
            // caller's cancellation handling is uniform.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // A genuine backend failure (Ollama down / timeout): degrade to the
            // in-app cleanup pipeline so the tone still applies.
            return local()
        }
    }
}
