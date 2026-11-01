import SwiftUI

/// The palette while a capture is transcribed and inserted, or while a
/// review is inserted: staged progress, the elapsed time it counts itself,
/// and, past the slow-run threshold, a note that the first run after a pause
/// can take a while.
struct PaletteProgressCard: View {
    let sessionState: SessionState
    @State private var elapsed = 0

    var body: some View {
        VStack(spacing: VF.spacingMedium) {
            // The four-stage strip needs the card's full width; the
            // horizontal padding is kept small for it.
            StagedProgressView(activeStage: Self.stage(sessionState: sessionState, elapsedSeconds: elapsed))

            Text("Processing\u{2026} \(elapsed)s")
                .font(VF.bodyFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if let notice = VFCopy.slowRunNotice(elapsedSeconds: elapsed) {
                VFBanner(kind: .info, message: notice)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(.vertical, VF.spacingLarge)
        .padding(.horizontal, VF.spacingXSmall)
        .vfSurface(.card, in: RoundedRectangle(cornerRadius: VF.cornerLarge, style: .continuous))
        .task {
            elapsed = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    elapsed += 1
                } catch {
                    break
                }
            }
            elapsed = 0
        }
    }

    /// Stage selector for the pipeline progress view.
    ///
    /// `.inserting` is the one stage the session state reports, so it shows
    /// as soon as the session inserts (a review insert goes straight there).
    /// Before that there are no per-stage signals from the backend, so the
    /// stage is a heuristic: transcription dominates the wall-clock time
    /// (~80% of the total) for any non-trivial dictation, and cleanup is
    /// typically sub-100 ms. Once the card mounts the capture is done, so it
    /// starts at `.transcribing` and, after a reasonable transcription
    /// window, promotes to `.cleaning`.
    nonisolated static func stage(sessionState: SessionState, elapsedSeconds elapsed: Int) -> PipelineStage {
        if sessionState == .inserting { return .inserting }
        return elapsed <= 3 ? .transcribing : .cleaning
    }
}
