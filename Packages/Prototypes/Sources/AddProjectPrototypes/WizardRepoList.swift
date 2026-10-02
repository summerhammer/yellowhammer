#if DEBUG
import SwiftUI

// MARK: - Repos

/// A card per Repo with every field laid out, and the button that adds one.
struct RepoStepView: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(draft.repos) { repo in
                    RepoCard(draft: $draft, repo: $draft.repo(repo.id))
                }
                HStack {
                    Button("Add Repo…", systemImage: "plus") { draft.addRepo() }
                    Spacer()
                }
            }
            .padding(20)
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
#endif
