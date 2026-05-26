import SwiftUI

/// One stage of the dictation → insert pipeline.
///
/// Stages are linear: ``capture`` → ``transcribing`` → ``cleaning`` →
/// ``inserting``. Each stage has a system-symbol icon and a short label
/// used by both the visual progress strip and the VoiceOver announcement.
enum PipelineStage: Int, CaseIterable, Identifiable {
    case capture
    case transcribing
    case cleaning
    case inserting

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .capture:      return "Capture"
        case .transcribing: return "Transcribe"
        case .cleaning:     return "Cleanup"
        case .inserting:    return "Insert"
        }
    }

    var systemImage: String {
        switch self {
        case .capture:      return "waveform"
        case .transcribing: return "text.bubble"
        case .cleaning:     return "sparkles"
        case .inserting:    return "arrow.down.to.line"
        }
    }
}

/// Four-pill horizontal progress strip showing the pipeline stages.
///
/// Replaces the plain `ProgressView()` + elapsed-time counter in
/// `CommandPaletteView.transcribingStateCard`. Stages strictly before
/// the active one render as completed (checkmark, success color); the
/// active stage gets a pulsing accent fill; later stages stay muted.
///
/// VoiceOver: collapses to a single element announcing the active stage
/// (e.g. "Transcribing, step 2 of 4"), so screen-reader users don't have
/// to navigate four separate sibling labels.
struct StagedProgressView: View {
    let activeStage: PipelineStage

    var body: some View {
        HStack(spacing: VF.spacingSmall) {
            ForEach(PipelineStage.allCases) { stage in
                pill(for: stage)
                if stage != PipelineStage.allCases.last {
                    connector(after: stage)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityAnnouncement)
    }

    private func pill(for stage: PipelineStage) -> some View {
        let status = state(for: stage)
        return HStack(spacing: 4) {
            Image(systemName: status == .done ? "checkmark.circle.fill" : stage.systemImage)
                .imageScale(.small)
                .foregroundStyle(status.foreground)
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: status == .active
                )
            Text(stage.label)
                .font(VF.captionEmphasizedFont)
                .foregroundStyle(status.foreground)
        }
        .padding(.horizontal, VF.spacingSmall)
        .padding(.vertical, 4)
        .background(status.background, in: Capsule())
    }

    private func connector(after stage: PipelineStage) -> some View {
        Rectangle()
            .frame(height: 1)
            .frame(maxWidth: 16)
            .foregroundStyle(state(for: stage) == .done ? VF.colorSuccess : .secondary.opacity(0.3))
    }

    private func state(for stage: PipelineStage) -> StageState {
        if stage.rawValue < activeStage.rawValue {
            return .done
        }
        if stage.rawValue == activeStage.rawValue {
            return .active
        }
        return .pending
    }

    private var accessibilityAnnouncement: String {
        let index = activeStage.rawValue + 1
        return "\(activeStage.label), step \(index) of \(PipelineStage.allCases.count)"
    }

    private enum StageState {
        case pending
        case active
        case done

        var foreground: Color {
            switch self {
            case .pending: return .secondary
            case .active:  return .primary
            case .done:    return VF.colorSuccess
            }
        }

        var background: AnyShapeStyle {
            switch self {
            case .pending: return AnyShapeStyle(VF.cardBackground)
            case .active:  return AnyShapeStyle(.tint.opacity(0.15))
            case .done:    return AnyShapeStyle(VF.tintedBackground(VF.colorSuccess, opacity: 0.12))
            }
        }
    }
}
