#if DEBUG
import SwiftUI

// MARK: - Repos

struct RepoStepView: View {
    @Binding var draft: AddProjectDraft
    let style: RepoListStyle

    var body: some View {
        switch style {
        case .rows:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Working Repos").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(draft.repos) { repo in
                            RepoRow(draft: $draft, repo: $draft.repo(repo.id))
                            Divider()
                        }
                    }
                    addButton
                    WizardFootnote()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .table:
            VStack(alignment: .leading, spacing: 10) {
                RepoTable(draft: $draft)
                HStack {
                    addButton
                    Spacer()
                    WizardProblemList(problems: draft.problems(in: .repos), limit: 1)
                }
            }
            .padding(20)
        case .cards:
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(draft.repos) { repo in
                        RepoCard(draft: $draft, repo: $draft.repo(repo.id))
                    }
                    HStack {
                        addButton
                        Spacer()
                    }
                }
                .padding(20)
            }
        }
    }

    private var addButton: some View {
        Button("Add Repo…", systemImage: "plus") { draft.addRepo() }
    }
}

/// The wireframe's row: path, role chip, Check pill; a conflict replaces the controls with its reason.
private struct RepoRow: View {
    @Binding var draft: AddProjectDraft
    @Binding var repo: RepoDraft

    var body: some View {
        HStack(spacing: 10) {
            if let conflict = draft.conflict(for: repo) {
                Text(repo.displayPath)
                    .font(.body.monospaced())
                    .foregroundStyle(WizardTheme.error)
                Spacer()
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(WizardTheme.error)
            } else {
                Text(repo.displayPath).font(.body.monospaced())
                RoleChip(role: $repo.role)
                Spacer()
                CheckPill(check: $repo.check)
            }
            Button("Remove", systemImage: "minus.circle") { draft.repos.removeAll { $0.id == repo.id } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
    }
}

private struct RepoTable: View {
    @Binding var draft: AddProjectDraft
    @State private var selection: RepoDraft.ID?

    var body: some View {
        Table(draft.repos, selection: $selection) {
            TableColumn("Path") { repo in
                HStack(spacing: 4) {
                    if draft.conflict(for: repo) != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WizardTheme.error)
                    }
                    Text(repo.displayPath)
                        .font(.body.monospaced())
                        .foregroundStyle(
                            draft.conflict(for: repo) == nil
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(WizardTheme.error)
                        )
                        .help(draft.conflict(for: repo) ?? repo.path)
                }
            }
            .width(min: 130, ideal: 170)
            TableColumn("Name") { repo in
                TextField("Name", text: $draft.repo(repo.id).name).labelsHidden()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Role") { repo in
                Picker("Role", selection: $draft.repo(repo.id).role) {
                    Text("—").tag("")
                    ForEach(AddProjectFixtures.roles, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            .width(90)
            TableColumn("Check") { repo in
                TextField("Check", text: $draft.repo(repo.id).check, prompt: Text("required"))
                    .labelsHidden()
                    .font(.body.monospaced())
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: RepoDraft.ID.self) { ids in
            Button("Remove") { draft.repos.removeAll { ids.contains($0.id) } }
        }
    }
}

private struct RepoCard: View {
    @Binding var draft: AddProjectDraft
    @Binding var repo: RepoDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(WizardTheme.accent)
                TextField("Name", text: $repo.name).font(.headline).textFieldStyle(.plain)
                Spacer()
                Button("Remove", systemImage: "trash") { draft.repos.removeAll { $0.id == repo.id } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            Text(repo.displayPath).font(.callout.monospaced()).foregroundStyle(.secondary)
            if let conflict = draft.conflict(for: repo) {
                Label(
                    conflict.prefix(1).capitalized + conflict.dropFirst(),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.callout)
                    .foregroundStyle(WizardTheme.error)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Repo Role").foregroundStyle(.secondary)
                        Picker("Repo Role", selection: $repo.role) {
                            Text("Choose…").tag("")
                            ForEach(AddProjectFixtures.roles, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("Check").foregroundStyle(.secondary)
                        CheckField(check: $repo.check)
                    }
                }
            }
        }
        .padding(14)
        .background(cardTint.opacity(0.07), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(cardTint.opacity(0.22)))
    }

    private var cardTint: Color {
        draft.conflict(for: repo) == nil ? WizardTheme.neutral : WizardTheme.error
    }
}

/// The role as a capsule that opens a menu.
struct RoleChip: View {
    @Binding var role: String

    var body: some View {
        Menu {
            Picker("Repo Role", selection: $role) {
                ForEach(AddProjectFixtures.roles, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(role.isEmpty ? "role?" : role)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(role.isEmpty ? WizardTheme.attention : nil)
        .fixedSize()
    }
}

/// The Check as a pill: a tick when declared, an orange "add Check" when not; edits in a popover.
struct CheckPill: View {
    @Binding var check: String
    @State private var isEditing = false

    var body: some View {
        Button {
            isEditing = true
        } label: {
            if check.isEmpty {
                Label("add Check", systemImage: "plus")
            } else {
                Label("Check", systemImage: "checkmark")
                    .labelStyle(TrailingIconLabelStyle())
                    .help(check)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(check.isEmpty ? WizardTheme.attention : nil)
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Check").font(.headline)
                CheckField(check: $check)
                Text("Runs before every push. \u{201c}none\u{201d} declares that nothing runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(width: 280)
        }
    }
}

/// A Check command field with the common commands one click away.
struct CheckField: View {
    @Binding var check: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("Check", text: $check, prompt: Text("make test, or none"))
                .labelsHidden()
                .font(.body.monospaced())
            Menu {
                ForEach(AddProjectFixtures.checkSuggestions, id: \.self) { suggestion in
                    Button(suggestion) { check = suggestion }
                }
            } label: {
                Label("Suggestions", systemImage: "list.bullet")
            }
            .menuStyle(.button)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("Suggestions")
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
#endif
