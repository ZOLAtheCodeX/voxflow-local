import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SkillProfileMenu: View {
    @ObservedObject var store: SkillProfileStore
    var body: some View {
        Menu("Skills: \(store.activeProfile?.name ?? "Off")") {
            Button { store.activate(nil) } label: {
                if store.activeProfileID == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            ForEach(store.profiles) { profile in
                Button { store.activate(profile.id) } label: {
                    if store.activeProfileID == profile.id { Label(profile.name, systemImage: "checkmark") }
                    else { Text(profile.name) }
                }
            }
            if store.profiles.isEmpty { Text("Add profiles in Settings → Dictation Tools") }
        }
        .accessibilityLabel("Active skill profile: \(store.activeProfile?.name ?? "Off")")
    }
}

struct SkillProfileSettingsSection: View {
    @ObservedObject var store: SkillProfileStore
    @State private var editing: SkillProfile?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = ConfigurationDocument()
    @State private var pending: PendingImport?
    @State private var message: String?

    private struct PendingImport: Identifiable {
        let id = UUID()
        let profiles: [SkillProfile]
        let summary: SkillImportSummary
        let details: [String]
    }

    var body: some View {
        Section("Voice Action Prompts") {
            HStack {
                SkillProfileMenu(store: store)
                Spacer()
                Button("New profile") { editing = SkillProfile(name: "", applications: [], skills: []) }
                Button("Import…") { importing = true }
                Button("Export…") {
                    do { exportDocument = ConfigurationDocument(data: try store.exportData()); exporting = true }
                    catch { message = error.localizedDescription }
                }
            }
            Text("Choose a profile for your CLI. Say a configured name or ‘use the research skill’ to insert its command. The Automatic Enter setting controls submission.")
                .font(VF.captionFont).foregroundStyle(.secondary)
            ForEach(store.profiles) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(VF.bodyEmphasizedFont)
                        Text("\(profile.skills.count) skills · \(profile.applications.map(Self.applicationName).joined(separator: ", "))")
                            .font(VF.captionFont).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit & try") { editing = profile }
                    Button(role: .destructive) { store.remove(profile.id) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Remove profile \(profile.name)")
                }.buttonStyle(.borderless)
            }
            if let error = store.lastError ?? message { Text(error).font(VF.captionFont).foregroundStyle(VF.colorError) }
        }
        .sheet(item: $editing) { profile in
            SkillProfileEditor(profile: profile) { edited in
                store.save(edited) ? nil : (store.lastError ?? "The profile could not be saved.")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let profiles = try SkillProfileFile.decode(ConfigurationFileAccess.read(url)).profiles
                let summary = try store.previewImport(profiles)
                let details = profiles.map { profile in
                    let existing = store.profiles.first { $0.name.lowercased() == profile.name.lowercased() }
                    let incoming = profile.skills.map { "\($0.name) → \($0.command)" }.joined(separator: "\n")
                    let old = existing.map { "\nExisting:\n" + $0.skills.map { "\($0.name) → \($0.command)" }.joined(separator: "\n") } ?? ""
                    return "\(profile.name)\nApplications: \(profile.applications.joined(separator: ", "))\nIncoming:\n\(incoming)\(old)"
                }
                pending = PendingImport(profiles: profiles, summary: summary, details: details)
                message = nil
            } catch { message = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "voxflow-skill-profiles") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .sheet(item: $pending) { item in
            ConfigurationImportReview(title: "Import skill profiles", additions: item.summary.additions,
                duplicates: item.summary.duplicates, conflicts: item.summary.conflicts, details: item.details) { replace in
                store.importProfiles(item.profiles, replaceConflicts: replace) ? nil : (store.lastError ?? "Import failed.")
            }
        }
    }

    static func applicationName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct SkillProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: SkillProfile
    let save: (SkillProfile) -> String?
    @State private var editingSkill: SpokenSkill?
    @State private var choosingApplication = false
    @State private var phrase = ""
    @State private var previewApplication = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingMedium) {
            Text("Skill profile").font(VF.titleFont)
            TextField("Profile name, for example My Claude Code", text: $profile.name)
            ScrollView {
                VStack(alignment: .leading, spacing: VF.spacingMedium) {
                    HStack {
                        Text("Allowed applications").font(VF.headingFont)
                        Spacer()
                        Button("Add application…") { choosingApplication = true }
                    }
                    Text("Select the terminal or editor where you use this CLI. Place the cursor in its prompt before dictating.")
                        .font(VF.captionFont).foregroundStyle(.secondary)
                    ForEach(profile.applications, id: \.self) { bundleID in
                        HStack {
                            Text(SkillProfileSettingsSection.applicationName(bundleID)).font(VF.bodyFont)
                            Spacer()
                            Button(role: .destructive) {
                                profile.applications.removeAll { $0 == bundleID }
                                if previewApplication == bundleID { previewApplication = profile.applications.first ?? "" }
                            } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Remove application \(SkillProfileSettingsSection.applicationName(bundleID))")
                        }
                    }
                    Divider()
                    HStack {
                        Text("Skills").font(VF.headingFont)
                        Spacer()
                        Button("Add skill") { editingSkill = SpokenSkill(name: "", command: "") }
                    }
                    ForEach(profile.skills) { skill in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name).font(VF.bodyEmphasizedFont)
                                Text(skill.command).font(VF.monoCaptionFont).textSelection(.enabled)
                                if !skill.aliases.isEmpty { Text("Also: \(skill.aliases.joined(separator: ", "))").font(VF.captionFont).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Edit") { editingSkill = skill }
                            Button(role: .destructive) { profile.skills.removeAll { $0.id == skill.id } } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Remove skill \(skill.name)")
                        }
                    }
                    Divider()
                    Text("Try a phrase").font(VF.headingFont)
                    TextField("Hey, use the research skill", text: $phrase)
                    Picker("In application", selection: $previewApplication) {
                        Text("Choose an application").tag("")
                        ForEach(profile.applications, id: \.self) { id in Text(SkillProfileSettingsSection.applicationName(id)).tag(id) }
                    }
                    if let skill = SpokenSkillRouter.resolve(phrase, profile: profile, targetBundleID: previewApplication) {
                        Text("Would insert: \(skill.command)").font(VF.monoCaptionFont).textSelection(.enabled)
                    } else {
                        Text("Would remain ordinary dictation.").font(VF.captionFont).foregroundStyle(.secondary)
                    }
                    Text("This preview does not insert text, install skills, or run commands.").font(VF.captionFont).foregroundStyle(.secondary)
                }.padding(.trailing, VF.spacingSmall)
            }.frame(maxHeight: 450)
            if let error { Text(error).font(VF.captionFont).foregroundStyle(VF.colorError) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save profile") {
                    if let message = save(profile) { error = message } else { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(VF.spacingLarge).frame(width: 560)
        .onAppear { previewApplication = profile.applications.first ?? "" }
        .fileImporter(isPresented: $choosingApplication, allowedContentTypes: [.applicationBundle]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let id = Bundle(url: url)?.bundleIdentifier else { throw SkillProfileError.invalid("This application has no bundle identifier.") }
                if !profile.applications.contains(id) { profile.applications.append(id) }
                if previewApplication.isEmpty { previewApplication = id }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $editingSkill) { skill in
            SpokenSkillEditor(skill: skill) { edited in
                var next = profile.skills
                if let index = next.firstIndex(where: { $0.id == edited.id }) { next[index] = edited } else { next.append(edited) }
                do {
                    // Validate skill content even while the surrounding profile is a draft.
                    profile.skills = try SkillProfile(name: "Draft", applications: ["validation.local"], skills: next).validated().skills
                    return nil
                } catch { return error.localizedDescription }
            }
        }
    }
}

private struct SpokenSkillEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var skill: SpokenSkill
    @State private var aliases: String
    @State private var error: String?
    let save: (SpokenSkill) -> String?

    init(skill: SpokenSkill, save: @escaping (SpokenSkill) -> String?) {
        _skill = State(initialValue: skill)
        _aliases = State(initialValue: skill.aliases.joined(separator: "\n"))
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingMedium) {
            Text("Spoken skill").font(VF.titleFont)
            TextField("Spoken name, for example research", text: $skill.name)
            TextField("Exact CLI command, for example /research", text: $skill.command)
            Text("Other spoken names, one per line (optional)").font(VF.labelFont)
            TextEditor(text: $aliases).font(VF.bodyFont).frame(height: 90)
                .border(VF.colorNeutral.opacity(0.3))
            Text("Use the invocation supported by your CLI. The skill must already be installed there.")
                .font(VF.captionFont).foregroundStyle(.secondary)
            if let error { Text(error).font(VF.captionFont).foregroundStyle(VF.colorError) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save skill") {
                    skill.aliases = aliases.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if let message = save(skill) { error = message } else { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(VF.spacingLarge).frame(width: 480)
    }
}
