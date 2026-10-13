import AppKit
import SwiftUI

/// The Repo Roles pane of the Settings window. Not Project-scoped: the Repo Roles an Operator declares are
/// machine-wide, in `config.toml`'s `repo_roles`. Lists the four built-in Repo Roles, which are always offered,
/// and each declared one, with the Projects that use it, and declares a new one or removes a declared one. A
/// declared Repo Role joins every Repo Role picker; the registry never validates a Repo or a Routing Entry.
struct RepoRolesPane: View {
    @State private var model = RepoRolesModel()

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.reloadIfIdle()
            }
    }

    @ViewBuilder private var content: some View {
        if let failure = model.loadFailure {
            SettingsUnavailable(message: failure)
                .accessibilityIdentifier("repo-role-load-failure")
        } else if let rows = model.rows {
            RepoRoleListView(model: model, rows: rows)
        } else {
            SettingsUnavailable(message: "Repo Roles could not be loaded.")
        }
    }
}

/// The list of Repo Roles plus the declare block, split out so it only ever runs with a non-nil row array.
private struct RepoRoleListView: View {
    @Bindable var model: RepoRolesModel
    let rows: [RepoRolesModel.Row]
    @State private var name = ""

    var body: some View {
        SettingsPane(
            title: "Repo Roles",
            explanation: "A Repo Role names what a Repo is in the product, and is what the Routing Table keys on. "
                + "The four built-in Repo Roles are always offered; the ones you declare join every Repo Role picker."
        ) {
            ForEach(rows) { row in
                RepoRoleCard(model: model, row: row)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("repo-role-row-\(row.name)")
            }
            declareBlock
        }
    }

    /// Declaring a Repo Role, as a dashed card like the Agent CLIs pane's, so it reads as the next item
    /// rather than a form.
    private var declareBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Declare").fontWeight(.medium)
                TextField("Repo Role", text: $name, prompt: Text("infra"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .frame(maxWidth: 260)
                    .onSubmit(declare)
                    .accessibilityIdentifier("repo-role-declare-name")
                Spacer(minLength: 8)
                Button("Declare", systemImage: "plus", action: declare)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("repo-role-declare")
            }
            Text(
                "Lowercase letters, digits, \u{201C}_\u{201D} and \u{201C}-\u{201D}, starting with a letter or a "
                    + "digit. " + savingNote
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let failure = model.declareFailure {
                SettingsFailureText(text: failure, identifier: "repo-role-declare-failure")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.neutral.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5]))
        )
    }

    /// Declares the typed name, and clears the field once the declaration is written.
    private func declare() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.declare(name: name)
        if model.declareFailure == nil { name = "" }
    }

    private var savingNote: String {
        let path = model.file.path(percentEncoded: false)
        if model.configMissing {
            return "Declaring creates \(path), the configuration this Mac\u{2019}s Projects share. "
                + "Editing the file directly stays supported."
        }
        return "Saving rewrites \(path); comments and layout in it are not kept. "
            + "Editing the file directly stays supported."
    }
}

/// One Repo Role as a card: its name, whether it is built in or can be removed, and where it is used.
private struct RepoRoleCard: View {
    @Bindable var model: RepoRolesModel
    let row: RepoRolesModel.Row
    @State private var confirmsRemoval = false

    var body: some View {
        SettingsCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.name).font(.headline.monospaced())
                Spacer()
                if row.isStandard {
                    Text("Built-in")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("repo-role-builtin-\(row.name)")
                } else {
                    removeButton
                }
            }
            if !row.usedBy.isEmpty {
                Text("Used by \(row.usedBy.formatted(.list(type: .and)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("repo-role-used-by-\(row.name)")
            }
            if row.namedInBaseTable {
                Text("Named in the base Routing Table")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure = model.removeFailures[row.name] {
                SettingsFailureText(text: failure, identifier: "repo-role-remove-failure-\(row.name)")
            }
        }
        .confirmationDialog(
            "Remove \(row.name)?", isPresented: $confirmsRemoval, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { model.remove(name: row.name) }
                .accessibilityIdentifier("repo-role-remove-confirm-\(row.name)")
        } message: {
            Text(
                "\(row.name) leaves the Repo Role pickers. A Repo or Routing Entry that still names it keeps "
                    + "working."
            )
        }
    }

    private var removeButton: some View {
        Button("Remove \(row.name)", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove \(row.name) from config.toml")
            .accessibilityIdentifier("repo-role-remove-\(row.name)")
    }
}
