import SwiftUI

/// The palette while a capture is transcribed and inserted: staged progress,
/// the elapsed time it counts itself, and, past the slow-run threshold, a
/// note that the first run after a pause can take a while.
struct PaletteProgressCard: View {
    @State private var elapsed = 0

    var body: some View {
        VStack(spacing: VF.spacingMedium) {
            // The four-stage strip needs the card's full width; the
            // horizontal padding is kept small for it.
            StagedProgressView(activeStage: Self.stage(forElapsedSeconds: elapsed))

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

    /// Heuristic stage selector for the pipeline progress view.
    ///
    /// We don't have per-stage signals from the backend, but the visual
    /// upgrade over a single spinner is real: users see which slice of the
    /// pipeline is running. Transcription dominates the wall-clock time
    /// (~80% of the total) for any non-trivial dictation; cleanup and
    /// insert are typically sub-100ms each. Once the card mounts we know
    /// capture is done, so we start at `.transcribing`. After a reasonable
    /// transcription window we promote to `.cleaning`; the actual swap
    /// to `.inserting` happens implicitly when this card dismisses.
    static func stage(forElapsedSeconds elapsed: Int) -> PipelineStage {
        elapsed <= 3 ? .transcribing : .cleaning
    }
}
