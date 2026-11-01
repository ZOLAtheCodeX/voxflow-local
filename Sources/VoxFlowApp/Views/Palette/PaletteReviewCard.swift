import SwiftUI

extension CommandPaletteView {
    var capturePanel: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            Picker("Provider", selection: Binding(
                get: { state.providerMode },
                set: { coordinator.selectProviderMode($0) }
            )) {
                ForEach(ProviderMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if state.providerMode == .privateAPI && (state.privateAPIBaseURL.isEmpty || state.privateAPIModel.isEmpty || !state.privateAPIKeyConfigured) {
                Text("Private API mode needs Base URL, Model, and API key in Settings.")
                    .font(VF.captionFont.weight(.semibold))
                    .foregroundStyle(VF.colorExternal)
            }

            Picker("Mode", selection: Binding(
                get: { state.workflowMode },
                set: { coordinator.selectWorkflowMode($0) }
            )) {
                ForEach(state.availableWorkflowModes) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if let privacyPreview = state.privacyPreview {
                privacyReview(preview: privacyPreview)
            } else {
                switch state.workflowMode {
                case .translateEnToDe:
                    translationReview
                case .meeting:
                    meetingReview
                case .dictation:
                    dictationReview
                case .prompt:
                    dictationReview // prompt mode reuses the dictation review surface for now
                }
            }

            HStack(spacing: 10) {
                Button("Insert") {
                    coordinator.insertCurrentText()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(insertDisabled)

                Button("Copy") {
                    coordinator.copyCurrentText()
                }
                .buttonStyle(.bordered)
                .disabled(state.displayText.isEmpty)

                Button("Retry") {
                    coordinator.retryLastCapture()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: [.command])

                Spacer()
            }
        }
    }

    private func privacyReview(preview: PrivacyPreview) -> some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            Text("Privacy Review")
                .font(VF.labelFont.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Original")
                .font(VF.captionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(preview.originalText)
                .font(VF.bodyFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VF.cornerMedium))
                .lineLimit(4)

            Text("Redacted")
                .font(VF.captionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(preview.redactedText)
                .font(VF.bodyFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: VF.cornerMedium)
                        .fill(.regularMaterial)
                        .overlay(VF.colorInfo.opacity(0.08))
                }
                .lineLimit(4)

            HStack(spacing: 8) {
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

    private var dictationReview: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            Group {
                if state.displayText.isEmpty {
                    Text("Hold \(state.dictationHotkeyPreset.displayName) to dictate. Use \(state.commandLaneHotkeyPreset.displayName) for command lane.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(state.displayText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(VF.bodyFont)
            .frame(minHeight: 92, maxHeight: 120)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))

            HStack(spacing: 8) {
                ForEach(CleanupMode.allCases) { mode in
                    ModeChip(mode: mode, selected: state.selectedMode == mode) {
                        coordinator.selectCleanupMode(mode)
                    }
                }
                Spacer()
                if let candidate = state.transcriptCandidate, candidate.confidence > 0 {
                    ConfidenceBadge(confidence: candidate.confidence)
                }
            }

            HStack(spacing: 8) {
                Text("Tone")
                    .font(VF.labelFont.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(ToneStyle.allCases) { tone in
                    Button(tone.displayName) {
                        coordinator.selectToneStyle(tone)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(state.toneStyle == tone ? .accentColor : VF.colorNeutral)
                    .accessibilityLabel("\(tone.displayName) tone")
                    .accessibilityAddTraits(state.toneStyle == tone ? .isSelected : [])
                }
            }

            if let bundleID = state.focusTarget.bundleID, let appName = state.focusTarget.appName {
                Divider()
                HStack(spacing: 6) {
                    Button {
                        showProfilePopover.toggle()
                    } label: {
                        Label("Profile: \(appName)", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $showProfilePopover) {
                        appProfilePopover(bundleID: bundleID, appName: appName)
                    }

                    if state.appProfiles[bundleID] != nil {
                        Text("Custom")
                            .font(VF.captionFont.weight(.medium))
                            .foregroundStyle(VF.colorInfo)
                    }
                }
            }
        }
    }

    private var translationReview: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            if let candidate = state.translationCandidate {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Captured English")
                        .font(VF.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(candidate.sourceEnglish)
                        .font(VF.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: VF.cornerMedium))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("German Output")
                        .font(VF.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(candidate.targetGerman)
                        .font(VF.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: VF.cornerMedium)
                                .fill(.regularMaterial)
                                .overlay(VF.tintedBackground(VF.colorSuccess, opacity: 0.08))
                        }
                }

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
                Text("Hold hotkey, speak in English, release to produce German text.")
                    .font(VF.bodyFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
            }
        }
    }

    private var meetingReview: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            if let meeting = state.meetingCandidate {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Captured Transcript")
                        .font(VF.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(meeting.transcript)
                        .font(VF.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: VF.cornerMedium))
                        .lineLimit(4)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Structured Notes")
                        .font(VF.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(meeting.formattedNotes)
                            .font(VF.bodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 100, maxHeight: 150)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: VF.cornerMedium)
                            .fill(.regularMaterial)
                            .overlay(VF.colorInfo.opacity(0.08))
                    }
                }

                if !meeting.speakerSegments.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Speaker Segments")
                            .font(VF.captionFont.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(meeting.speakerSegments) { segment in
                                Text("• \(segment.speaker) (\(segment.utteranceCount)): \(segment.text)")
                                    .font(VF.labelFont)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: VF.cornerMedium))
                    }
                }

                if !meeting.taskOwners.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Task Owners")
                            .font(VF.captionFont.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(meeting.taskOwners) { owner in
                                let confidence = Int((owner.confidence * 100).rounded())
                                Text("• \(owner.task) -> \(owner.owner) (\(confidence)%)")
                                    .font(VF.labelFont)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: VF.cornerMedium)
                                .fill(.regularMaterial)
                                .overlay(VF.tintedBackground(VF.colorSuccess, opacity: 0.08))
                        }
                    }
                }

                HStack(spacing: 8) {
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
                Text("Meeting mode: hold hotkey to capture, then review summary, decisions, actions, and follow-ups.")
                    .font(VF.bodyFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
            }
        }
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
}
