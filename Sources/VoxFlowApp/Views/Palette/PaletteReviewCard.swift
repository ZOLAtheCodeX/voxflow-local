import SwiftUI

/// The palette's review state: the privacy preview (a consent gate, so it
/// leads with a warning and a warning outline), or the translation, meeting
/// or dictation review, then Insert (return), Copy and Start Over (Cmd-R).
/// Every button calls the coordinator method it called before the refresh.
/// In idle it shows a translate, meeting or prompt result after its insert
/// (ruling R36) with `bindsKeys` false: the same buttons, no return or Cmd-R
/// (ruling R13), so no invisible shortcut re-inserts.
struct PaletteReviewCard: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    var bindsKeys = true

    private let shape = RoundedRectangle(cornerRadius: VF.cornerLarge, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingMedium) {
            if let preview = state.privacyPreview {
                privacyReview(preview: preview)
            } else {
                switch state.workflowMode {
                case .translateEnToDe:
                    translationReview
                case .meeting:
                    meetingReview
                case .dictation, .prompt:
                    // Prompt mode reuses the dictation review surface.
                    dictationReview
                }
            }

            actions
        }
        .padding(VF.spacingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vfSurface(.card, in: shape)
        .overlay {
            if state.privacyPreview != nil {
                shape.strokeBorder(VF.colorWarning, lineWidth: 1)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: VF.spacingSmall) {
            Button("Insert") {
                coordinator.insertCurrentText()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(bindsKeys ? KeyboardShortcut(.return, modifiers: []) : nil)
            .disabled(insertDisabled)

            Button("Copy") {
                coordinator.copyCurrentText()
            }
            .buttonStyle(.bordered)
            .disabled(state.displayText.isEmpty)

            Button("Start Over") {
                coordinator.retryLastCapture()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(bindsKeys ? KeyboardShortcut("r", modifiers: [.command]) : nil)
            .help(bindsKeys ? "Discard this text and start over (\u{2318}R)" : "Discard this text and start over")

            Spacer(minLength: 0)

            if showsConfidence, let candidate = state.transcriptCandidate, candidate.confidence > 0 {
                ConfidenceBadge(confidence: candidate.confidence)
            }
        }
    }

    private var showsConfidence: Bool {
        state.privacyPreview == nil && (state.workflowMode == .dictation || state.workflowMode == .prompt)
    }

    private var insertDisabled: Bool {
        if state.privacyPreview != nil {
            return true
        }

        if state.displayText.isEmpty {
            return true
        }

        if state.workflowMode == .translateEnToDe {
            return state.translationCandidate?.approved != true
        }

        if state.workflowMode == .meeting {
            return state.meetingCandidate?.approved != true
        }

        return false
    }

    // MARK: - Privacy

    private func privacyReview(preview: PrivacyPreview) -> some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            VFBanner(kind: .warning, message: "This text will leave your Mac. Check it before you approve.")

            VFSectionHeader(title: "Original")
            textBlock(preview.originalText, lineLimit: 4)

            VFSectionHeader(title: "Redacted")
            textBlock(preview.redactedText, lineLimit: 4, tint: VF.colorInfo)

            HStack(spacing: VF.spacingSmall) {
                Button("Approve Redacted") {
                    coordinator.approvePrivacyPreview(sendRaw: false)
                }
                .buttonStyle(.borderedProminent)

                Button("Approve Raw") {
                    coordinator.approvePrivacyPreview(sendRaw: true)
                }
                .buttonStyle(.bordered)

                Button("Cancel") {
                    coordinator.cancelPrivacyPreview()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    // MARK: - Dictation

    private var dictationReview: some View {
        Group {
            if state.displayText.isEmpty {
                Text(VFCopy.hotkeyHint(dictation: state.dictationHotkeyPreset, voiceControl: state.commandLaneHotkeyPreset))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(state.displayText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(VF.bodyFont)
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 120, alignment: .topLeading)
        .padding(VF.spacingSmall + 2)
        .vfSurface(.elevated, in: RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous))
    }

    // MARK: - Translation

    private var translationReview: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            if let candidate = state.translationCandidate {
                VFSectionHeader(title: "Captured English")
                textBlock(candidate.sourceEnglish)

                VFSectionHeader(title: "German output")
                textBlock(candidate.targetGerman, tint: VF.colorSuccess)

                if !candidate.approved {
                    Button {
                        coordinator.approveTranslation()
                    } label: {
                        Label("Approve Translation", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VF.colorSuccess)
                }
            } else {
                Text("Hold the hotkey, speak in English, and release to get German text.")
                    .font(VF.bodyFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Meeting

    private var meetingReview: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            if let meeting = state.meetingCandidate {
                VFSectionHeader(title: "Captured transcript")
                textBlock(meeting.transcript, lineLimit: 4)

                VFSectionHeader(title: "Structured notes")
                ScrollView {
                    Text(meeting.formattedNotes)
                        .font(VF.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 100, maxHeight: 150)
                .padding(VF.spacingSmall + 2)
                .background(VF.tintedBackground(VF.colorInfo, opacity: 0.08),
                            in: RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous))
                .vfSurface(.elevated, in: RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous))

                if !meeting.speakerSegments.isEmpty {
                    VFSectionHeader(title: "Speaker segments")
                    listBlock(meeting.speakerSegments.map { "\u{2022} \($0.speaker) (\($0.utteranceCount)): \($0.text)" })
                }

                if !meeting.taskOwners.isEmpty {
                    VFSectionHeader(title: "Task owners")
                    listBlock(meeting.taskOwners.map { owner in
                        let confidence = Int((owner.confidence * 100).rounded())
                        return "\u{2022} \(owner.task) \u{2192} \(owner.owner) (\(confidence)%)"
                    }, tint: VF.colorSuccess)
                }

                HStack(spacing: VF.spacingSmall) {
                    Button("Copy Markdown Template") {
                        coordinator.copyMeetingMarkdownTemplate()
                    }
                    .buttonStyle(.bordered)

                    Button("Copy Notion Template") {
                        coordinator.copyMeetingNotionTemplate()
                    }
                    .buttonStyle(.bordered)
                }

                if !meeting.approved {
                    Button {
                        coordinator.approveMeetingNotes()
                    } label: {
                        Label("Approve Meeting Notes", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VF.colorSuccess)
                }
            } else {
                Text("Meeting mode: hold the hotkey to capture, then review the summary, decisions, actions and follow-ups.")
                    .font(VF.bodyFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Blocks

    /// Read-only text on a raised surface, optionally tinted.
    private func textBlock(_ text: String, lineLimit: Int? = nil, tint: Color? = nil) -> some View {
        Text(text)
            .font(VF.bodyFont)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VF.spacingSmall + 2)
            .background(tint.map { VF.tintedBackground($0, opacity: 0.08) } ?? Color.clear,
                        in: RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous))
            .vfSurface(.elevated, in: RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous))
    }

    private func listBlock(_ lines: [String], tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: VF.spacingXSmall) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(VF.labelFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(VF.spacingSmall + 2)
        .background(tint.map { VF.tintedBackground($0, opacity: 0.08) } ?? Color.clear,
                    in: RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous))
        .vfSurface(.elevated, in: RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous))
    }
}
