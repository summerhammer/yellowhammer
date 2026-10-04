import Config
import SwiftUI

// MARK: - Repos

/// The repos in a card layout: a card per Repo with every field laid out, plus an "Add Repo…" button.
struct RepoStepView: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
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

    private var addButton: some View {
        Button("Add Repo…", systemImage: "plus") {
            guard let url = SetupWizardModel.chooseFolder() else { return }
            draft.addRepo(path: SetupWizardModel.abbreviatingPath(url))
        }
        .accessibilityIdentifier("setup-add-repo")
    }
}

private struct RepoCard: View {
    @Binding var draft: AddProjectDraft
    @Binding var repo: AddProjectDraft.Repo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.accent)
                TextField("Name", text: $repo.name).font(.headline).textFieldStyle(.plain)
                    .accessibilityIdentifier("setup-repo-name")
                Spacer()
                Button("Remove", systemImage: "trash") {
                    draft.removeRepo(repo.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("setup-repo-remove")
            }
            HStack {
                Text(repo.displayPath.isEmpty ? "No folder chosen" : repo.displayPath)
                    .font(.callout.monospaced())
                    .foregroundStyle(repo.displayPath.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Choose…") {
                    guard let url = SetupWizardModel.chooseFolder() else { return }
                    repo.path = SetupWizardModel.abbreviatingPath(url)
                    if repo.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        repo.name = url.lastPathComponent
                    }
                    if repo.role.isEmpty {
                        repo.role = AddProjectDraft.guessedRole(for: repo.path)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let conflict = draft.conflict(for: repo) {
                Label(
                    conflict.prefix(1).uppercased() + conflict.dropFirst(),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.error)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Repo Role").foregroundStyle(.secondary)
                        Picker("Repo Role", selection: $repo.role) {
                            Text("Choose…").tag("")
                            ForEach(AddProjectDraft.suggestedRoles, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("setup-repo-role")
                    }
                    GridRow {
                        Text("Check").foregroundStyle(.secondary)
                        CheckField(check: $repo.check)
                    }
                }
                if let missing = missingFieldsText {
                    Label {
                        Text(missing).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.warning)
                    }
                    .font(.callout)
                    .accessibilityIdentifier("setup-repo-missing")
                }
            }
        }
        .padding(14)
        .background(cardTint.opacity(0.07), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(cardTint.opacity(0.22)))
    }

    /// What this card still needs, named as its own fields are labelled. The step's problem count is otherwise
    /// the only sign, and an empty Check shows only its prompt, which reads as a value.
    private var missingFieldsText: String? {
        let missing = draft.missingFields(of: repo).map { field in
            switch field {
            case "role": "a Repo Role"
            case "Check": "a Check (\u{201c}none\u{201d} declares no Check)"
            default: "a \(field)"
            }
        }
        guard !missing.isEmpty else { return nil }
        return "Still needs " + missing.formatted(.list(type: .and)) + "."
    }

    private var cardTint: AnyShapeStyle {
        draft.conflict(for: repo) == nil ? AnyShapeStyle(.neutral) : AnyShapeStyle(.error)
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
                .accessibilityIdentifier("setup-repo-check")
            Menu {
                ForEach(AddProjectDraft.suggestedChecks, id: \.self) { suggestion in
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

extension Binding where Value == AddProjectDraft {
    /// A binding to one Repo by id, safe against the Repo being removed mid-render.
    func repo(_ id: AddProjectDraft.Repo.ID) -> Binding<AddProjectDraft.Repo> {
        Binding<AddProjectDraft.Repo> {
            wrappedValue.repos.first { $0.id == id } ?? AddProjectDraft.Repo(path: "")
        } set: { newValue in
            guard let index = wrappedValue.repos.firstIndex(where: { $0.id == id }) else { return }
            wrappedValue.repos[index] = newValue
        }
    }
}
