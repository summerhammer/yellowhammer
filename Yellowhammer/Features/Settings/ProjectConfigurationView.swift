import AppKit
import Config
import Domain
import SwiftUI

/// A Project's configuration, editable end to end: name, Repos, Bounds and its own Routing Table
/// overrides, plus the read-only Spec Source and a way into the machine-wide base Routing Table
/// (P14.3), and the read-only Linear workspace and installation the Project selected. It is the
/// Configuration tab of a Project's entry in the Settings window, a single screen and not a wizard: the
/// Setup wizard runs only when a Project is added.
///
/// The app writes configuration only through ``Config/Configuration/save(_:to:in:replacing:)`` — the
/// loader is the only validator, so a refusal here is always shown in the loader's own words.
struct ProjectConfigurationView: View {
    let model: ProjectConfigurationModel
    /// Called after a save wrote the file, so the window can read its configuration again: the Project's
    /// name is shown in the window's sidebar and title.
    private let onSaved: () -> Void
    /// The label for an installation's local name: its Linear workspace name once `yh doctor` read it, else
    /// the local name. The workspace name is not stored (OQ117).
    private let workspaceLabel: (String) -> String

    /// `model` is owned by the Project's pane, so moving to Recalibrate and back keeps unsaved edits.
    init(
        model: ProjectConfigurationModel, onSaved: @escaping () -> Void = {},
        workspaceLabel: @escaping (String) -> String = { $0 }
    ) {
        self.model = model
        self.onSaved = onSaved
        self.workspaceLabel = workspaceLabel
    }

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.reloadIfClean()
            }
    }

    @ViewBuilder private var content: some View {
        if model.draft != nil {
            ProjectConfigurationFormView(model: model, onSaved: onSaved, workspaceLabel: workspaceLabel)
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        SettingsUnavailable(message: model.loadFailure ?? "This Project could not be loaded.")
    }
}

/// The form itself, split out so it only ever runs with a non-nil draft. The draft binding falls back to
/// the draft this body saw rather than unwrapping `model.draft`: `Binding($model.draft)` traps when a
/// reload clears the draft while a field still reads it, as can happen mid-teardown.
private struct ProjectConfigurationFormView: View {
    @Bindable var model: ProjectConfigurationModel
    let onSaved: () -> Void
    let workspaceLabel: (String) -> String
    @Environment(\.showSettingsSection) private var showSettingsSection
    @Environment(SettingsRequest.self) private var settingsRequest

    var body: some View {
        if let current = model.draft {
            let draft = Binding(get: { model.draft ?? current }, set: { model.draft = $0 })
            SettingsPane {
                projectBlock(draft)
                linearBlock(draft)
                if let specSource = draft.wrappedValue.specSource {
                    specSourceBlock(specSource)
                }
                reposBlock(draft)
                boundsBlock(draft)
                routingBlock(draft)
            } footer: {
                SettingsSaveFooter(
                    note: "Saving rewrites \(model.file.path(percentEncoded: false)); comments and layout in it "
                        + "are not kept. Editing the file directly stays supported.",
                    failure: model.failure,
                    isDirty: model.isDirty,
                    identifierPrefix: "configuration",
                    onRevert: { model.revert() },
                    onSave: { if model.save() { onSaved() } }
                )
            }
        } else {
            SettingsUnavailable(message: "This Project could not be loaded.")
        }
    }

    private func projectBlock(_ draft: Binding<ProjectFileDraft>) -> some View {
        WizardBlock(title: "Project") {
            WizardBlockRow(label: "Name") {
                TextField("Name", text: draft.name)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("project-name") // glossary:ignore GL001
            }
            Divider().padding(.leading, 12)
            WizardBlockRow(label: "Project id", detail: "Names the Project file, its Journal and its LaunchAgents.") {
                HStack(spacing: 8) {
                    IdToken(id: draft.wrappedValue.id.rawValue)
                        .textSelection(.enabled)
                    PermanentBadge()
                }
            }
        }
    }

    private func linearBlock(_ draft: Binding<ProjectFileDraft>) -> some View {
        let installation = draft.wrappedValue.linearInstallationName
        return WizardBlock(
            title: "Linear",
            footer: "The workspace is fixed for this Project\u{2019}s life \u{2014} to move it to another workspace, "
                + "remove the Project and add it again.",
            footerIdentifier: "project-linear-workspace-caption" // glossary:ignore GL001
        ) {
            WizardBlockRow(label: "Linear workspace") {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Button {
                        settingsRequest.request(draft.wrappedValue.id, section: .boards, boardConnection: installation)
                    } label: {
                        Text(workspaceLabel(installation))
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("project-linear-workspace") // glossary:ignore GL001
                    .accessibilityValue(workspaceLabel(installation))
                }
            }
            Divider().padding(.leading, 12)
            WizardBlockRow(label: "Board Connection") {
                SettingsValueText(value: installation, monospaced: true)
                    .accessibilityIdentifier("project-linear-installation") // glossary:ignore GL001
            }
            Divider().padding(.leading, 12)
            WizardBlockRow(label: "Linear project") { // glossary:ignore GL001
                TextField("Linear project", text: draft.linearProject, prompt: Text("Paste the id from Linear"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("project-linear-project") // glossary:ignore GL001
            }
        }
    }

    private func specSourceBlock(_ specSource: String) -> some View {
        WizardBlock(
            title: "Spec Source",
            footer: "read \u{2014} this Project never writes it",
            footerIdentifier: "project-spec-source-caption" // glossary:ignore GL001
        ) {
            WizardBlockRow(label: "Folder") {
                SettingsValueText(value: specSource, monospaced: true)
                    .accessibilityIdentifier("project-spec-source") // glossary:ignore GL001
            }
        }
    }

    private func reposBlock(_ draft: Binding<ProjectFileDraft>) -> some View {
        WizardBlock(title: "Repos", boxed: false) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(draft.wrappedValue.repos.indices, id: \.self) { index in
                    repoCard(draft, index: index)
                }
                Button("Add Repo", systemImage: "plus") {
                    draft.wrappedValue.repos.append(RepoDraft(name: "", path: "", role: "", check: ""))
                }
            }
        }
    }

    private func repoCard(_ draft: Binding<ProjectFileDraft>, index: Int) -> some View {
        SettingsCard {
            HStack {
                Image(systemName: DomainSymbol.repo).foregroundStyle(.accent)
                    .accessibilityHidden(true)
                TextField("Name", text: draft.repos[index].name, prompt: Text("Repo name"))
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("repo-name")
                Spacer()
                Button("Remove Repo", systemImage: "trash", role: .destructive) {
                    draft.wrappedValue.repos.remove(at: index)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove Repo")
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    fieldLabel("Path")
                    TextField("Path", text: draft.repos[index].path)
                        .font(.body.monospaced())
                        .accessibilityIdentifier("repo-path")
                }
                GridRow {
                    fieldLabel("Repo Role")
                    TextField("Repo Role", text: draft.repos[index].role)
                        .accessibilityIdentifier("repo-role")
                }
                GridRow {
                    fieldLabel("Check")
                    TextField("Check", text: draft.repos[index].check, prompt: Text("make test, or none"))
                        .font(.body.monospaced())
                        .accessibilityIdentifier("repo-check")
                }
                GridRow {
                    fieldLabel("Protected paths")
                    TextField(
                        "Protected paths", text: protectedPathsBinding(draft, index: index),
                        prompt: Text("Comma-separated")
                    )
                    .font(.body.monospaced())
                    .accessibilityIdentifier("repo-protected-paths")
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
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

    @ViewBuilder
    private func boundsBlock(_ draft: Binding<ProjectFileDraft>) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Bounds").font(.headline)
            BoundsDraftBlocks(bounds: draft.bounds)
        }
    }

    private func routingBlock(_ draft: Binding<ProjectFileDraft>) -> some View {
        WizardBlock(
            title: "Routing overrides",
            footer: "An entry here replaces the base Routing Table\u{2019}s entry for the same Kind and Repo Role.",
            boxed: false
        ) {
            VStack(alignment: .leading, spacing: 12) {
                RoutingEntriesEditor(
                    entries: draft.routingOverrides,
                    emptyText: "No override: this Project uses the base Routing Table."
                )
                Button("Base Routing Table\u{2026}") {
                    showSettingsSection(.baseRoutingTable)
                }
                .accessibilityIdentifier("open-base-routing-table")
            }
        }
    }
}
