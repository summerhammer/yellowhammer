import AppKit
import Config
import Domain
import SwiftUI

/// A Project's configuration, editable end to end: name, Repos, Bounds and its own Routing Table
/// overrides, plus the read-only Spec Source and a way into the machine-wide base Routing Table
/// (P14.3). It is the Configuration tab of a Project's entry in the Settings window, a single screen
/// and not a wizard: the Setup wizard runs only when a Project is added.
///
/// The app writes configuration only through ``Config/Configuration/save(_:to:in:replacing:)`` — the
/// loader is the only validator, so a refusal here is always shown in the loader's own words.
struct ProjectConfigurationView: View {
    @State private var model: ProjectConfigurationModel
    /// Called after a save wrote the file, so the window can read its configuration again: the Project's
    /// name is shown in the window's sidebar and title.
    private let onSaved: () -> Void

    init(project: ProjectID, onSaved: @escaping () -> Void = {}) {
        _model = State(initialValue: ProjectConfigurationModel(project: project))
        self.onSaved = onSaved
    }

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.reloadIfClean()
            }
    }

    @ViewBuilder private var content: some View {
        if model.draft != nil {
            ProjectConfigurationFormView(model: model, onSaved: onSaved)
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Text(model.loadFailure ?? "This Project could not be loaded.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}

/// The form itself, split out so it only ever runs with a non-nil draft. The draft binding falls back to
/// the draft this body saw rather than unwrapping `model.draft`: `Binding($model.draft)` traps when a
/// reload clears the draft while a field still reads it, as can happen mid-teardown.
private struct ProjectConfigurationFormView: View {
    @Bindable var model: ProjectConfigurationModel
    let onSaved: () -> Void
    @Environment(\.showSettingsSection) private var showSettingsSection

    var body: some View {
        if let current = model.draft {
            let draft = Binding(get: { model.draft ?? current }, set: { model.draft = $0 })
            VStack(spacing: 0) {
                Form {
                    projectSection(draft)
                    if let specSource = draft.wrappedValue.specSource {
                        specSourceSection(specSource)
                    }
                    reposSection(draft)
                    boundsSection(draft)
                    routingSection(draft)
                }
                .formStyle(.grouped)
                Divider()
                footer
            }
        } else {
            Text("This Project could not be loaded.")
        }
    }

    private func projectSection(_ draft: Binding<ProjectFileDraft>) -> some View {
        Section("Project") {
            LabeledContent("Id") {
                Text(draft.wrappedValue.id.rawValue)
                    .textSelection(.enabled)
            }
            TextField("Name", text: draft.name)
                .accessibilityIdentifier("project-name") // glossary:ignore GL001
            TextField("Linear project", text: draft.linearProject) // glossary:ignore GL001
                .accessibilityIdentifier("project-linear-project") // glossary:ignore GL001
        }
    }

    private func specSourceSection(_ specSource: String) -> some View {
        Section("Spec Source") {
            Text(specSource)
                .textSelection(.enabled)
                .accessibilityIdentifier("project-spec-source") // glossary:ignore GL001
            Text("read \u{2014} this Project never writes it")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("project-spec-source-caption") // glossary:ignore GL001
        }
    }

    private func reposSection(_ draft: Binding<ProjectFileDraft>) -> some View {
        Section("Repos") {
            ForEach(draft.wrappedValue.repos.indices, id: \.self) { index in
                repoRow(draft, index: index)
            }
            Button("Add Repo") {
                draft.wrappedValue.repos.append(RepoDraft(name: "", path: "", role: "", check: ""))
            }
        }
    }

    @ViewBuilder
    private func repoRow(_ draft: Binding<ProjectFileDraft>, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Name", text: draft.repos[index].name)
                .accessibilityIdentifier("repo-name")
            TextField("Path", text: draft.repos[index].path)
                .accessibilityIdentifier("repo-path")
            TextField("Role", text: draft.repos[index].role)
                .accessibilityIdentifier("repo-role")
            TextField("Check (\u{201c}none\u{201d} declares no Check)", text: draft.repos[index].check)
                .accessibilityIdentifier("repo-check")
            TextField("Protected paths (comma-separated)", text: protectedPathsBinding(draft, index: index))
                .accessibilityIdentifier("repo-protected-paths")
            Button("Remove Repo", role: .destructive) {
                draft.wrappedValue.repos.remove(at: index)
            }
        }
        .padding(.vertical, 4)
    }

    /// Joins ``RepoDraft/protectedPaths`` for display and, on edit, splits on `,`, trims each piece and
    /// drops empties, so a trailing or doubled comma never becomes a stray empty path.
    private func protectedPathsBinding(_ draft: Binding<ProjectFileDraft>, index: Int) -> Binding<String> {
        Binding(
            get: { draft.wrappedValue.repos[index].protectedPaths.joined(separator: ", ") },
            set: { newValue in
                draft.wrappedValue.repos[index].protectedPaths = newValue
                    .split(separator: ",")
                    .map(\.trimmed)
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func boundsSection(_ draft: Binding<ProjectFileDraft>) -> some View {
        Section("Bounds") {
            boundField("review_rounds_max", draft.bounds.reviewRoundsMax)
            boundField("attempts_per_card", draft.bounds.attemptsPerCard)
            boundField("unanswered_nights_max", draft.bounds.unansweredNightsMax)
            boundField("reselections_max", draft.bounds.reselectionsMax)
            boundField("consecutive_refusals_max", draft.bounds.consecutiveRefusalsMax)
            boundField("failed_adoptions_max", draft.bounds.failedAdoptionsMax)
        }
    }

    private func boundField(_ key: String, _ value: Binding<String>) -> some View {
        TextField(key, text: value)
            .accessibilityIdentifier("bound-\(key)")
    }

    private func routingSection(_ draft: Binding<ProjectFileDraft>) -> some View {
        Section("Routing overrides") {
            RoutingEntriesEditor(entries: draft.routingOverrides)
            Button("Base Routing Table\u{2026}") {
                showSettingsSection(.baseRoutingTable)
            }
            .accessibilityIdentifier("open-base-routing-table")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("configuration-save-failure")
            }
            Text(
                "Saving rewrites \(model.file.path(percentEncoded: false)); comments and layout in it "
                    + "are not kept. Editing the file directly stays supported."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty)
                    .accessibilityIdentifier("configuration-revert")
                Button("Save") {
                    if model.save() { onSaved() }
                }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty)
                    .accessibilityIdentifier("configuration-save")
            }
        }
        .padding()
    }
}
