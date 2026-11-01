import SwiftUI

extension CommandPaletteView {
    var transcribingStateCard: some View {
        VStack(spacing: VF.spacingMedium) {
            StagedProgressView(activeStage: currentPipelineStage)
                .padding(.horizontal, 4)

            Text("Processing… \(transcribingElapsed)s")
                .font(VF.bodyFont)
                .foregroundStyle(.secondary)

            if transcribingElapsed > 90 {
                Text("Taking longer than expected…")
                    .font(VF.captionFont)
                    .foregroundStyle(VF.colorWarning)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(VF.spacingLarge)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
        .task {
            transcribingElapsed = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    transcribingElapsed += 1
                } catch {
                    break
                }
            }
            transcribingElapsed = 0
        }
    }

    /// Heuristic stage selector for the pipeline progress view.
    ///
    /// We don't have per-stage signals from the backend, but the visual
    /// upgrade over a single spinner is real: users see which slice of the
    /// pipeline is running. Transcription dominates the wall-clock time
    /// (~80% of the total) for any non-trivial dictation; cleanup and
    /// insert are typically sub-100ms each. Once the card mounts we know
    /// capture is done, so we start at `.transcribing`. After a reasonable
    /// transcription window we promote to `.cleaning` — the actual swap
    /// to `.inserting` happens implicitly when this card dismisses.
    private var currentPipelineStage: PipelineStage {
        if transcribingElapsed <= 3 {
            return .transcribing
        }
        return .cleaning
    }
}
