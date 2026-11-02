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
/// active stage shows its own symbol in the brand color; later stages stay
/// muted with an empty circle. Nothing animates: the stage is told apart by
/// symbol and color, so Reduce Motion needs no special case.
///
/// VoiceOver: collapses to a single element announcing the active stage
/// (e.g. "Transcribing, step 2 of 4"), so screen-reader users don't have
/// to navigate four separate sibling labels.
struct StagedProgressView: View {
    let activeStage: PipelineStage

    var body: some View {
        HStack(spacing: VF.spacingXSmall) {
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
        return HStack(spacing: 3) {
            Image(systemName: status.symbol(for: stage))
                .imageScale(.small)
                .foregroundStyle(status.foreground)
            Text(stage.label)
                .font(VF.captionEmphasizedFont)
                .foregroundStyle(status.foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(status.background, in: Capsule())
    }

    private func connector(after stage: PipelineStage) -> some View {
        Rectangle()
            .frame(height: 1)
            .frame(minWidth: 3, maxWidth: 12)
            .foregroundStyle(state(for: stage) == .done ? VF.colorSuccess : VF.hairline)
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

        func symbol(for stage: PipelineStage) -> String {
            switch self {
            case .pending: return "circle"
            case .active:  return stage.systemImage
            case .done:    return "checkmark.circle.fill"
            }
        }

        var foreground: Color {
            switch self {
            case .pending: return VF.colorNeutral
            case .active:  return VF.colorBrandInk
            case .done:    return VF.colorSuccess
            }
        }

        var background: AnyShapeStyle {
            switch self {
            case .pending: return AnyShapeStyle(VF.cardBackground)
            case .active:  return AnyShapeStyle(VF.tintedBackground(VF.colorBrandInk))
            case .done:    return AnyShapeStyle(VF.tintedBackground(VF.colorSuccess, opacity: 0.12))
            }
        }
    }
}
