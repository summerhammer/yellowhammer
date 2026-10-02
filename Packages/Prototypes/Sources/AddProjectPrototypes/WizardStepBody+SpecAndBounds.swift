#if DEBUG
import SwiftUI

// MARK: - Spec Source

/// Two option cards — a shared folder or one of this Project's Repos — then the candidates.
struct SpecBlock: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            optionCards
            let problems = draft.problems(in: .specSource)
            if !problems.isEmpty, draft.visited.contains(.specSource) {
                WizardProblemList(problems: problems)
            }
        }
    }

    private var specRepos: [RepoDraft] { draft.repos.filter { $0.role == "spec" } }

    private var optionCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            OptionCards {
                OptionCard(
                    title: "A shared spec folder",
                    detail: "A checkout of the specification, kept outside this Project.",
                    points: ["Several Projects can read it", "No Repo Role, Check or Worktree"],
                    isSelected: draft.specChoice == .path
                ) { draft.specChoice = .path }
                OptionCard(
                    title: "A Repo in this Project",
                    detail: "One of this Project\u{2019}s Repos, with Repo Role \u{201c}spec\u{201d}.",
                    points: ["Belongs to this Project only", "Declared with the other Repos"],
                    isSelected: draft.specChoice == .repo
                ) { draft.specChoice = .repo }
            }
            VStack(spacing: 0) {
                switch draft.specChoice {
                case .path: folderRows
                case .repo: repoRows
                }
            }
            .background(WizardTheme.surface, in: .rect(cornerRadius: 10))
        }
    }

    @ViewBuilder private var folderRows: some View {
        ForEach(AddProjectFixtures.sharedSpecSources, id: \.path) { source in
            RadioRow(
                title: source.path.replacingOccurrences(of: AddProjectFixtures.home, with: "~"),
                note: "read by \(source.readBy.formatted(.list(type: .and)))",
                monospaced: true,
                isSelected: draft.specChoice == .path && draft.specSourcePath == source.path
            ) { draft.useSpecSource(source.path) }
        }
        if draft.specChoice == .path, !draft.specSourcePath.isEmpty,
           !AddProjectFixtures.sharedSpecSources.contains(where: { $0.path == draft.specSourcePath }) {
            RadioRow(
                title: draft.specSourcePath.replacingOccurrences(of: AddProjectFixtures.home, with: "~"),
                note: "chosen", monospaced: true, isSelected: true
            ) {}
        }
        AddRow(title: "Choose Another Folder…") {
            draft.useSpecSource("\(AddProjectFixtures.home)/dev/acme/acme-spec-shared")
        }
    }

    @ViewBuilder private var repoRows: some View {
        ForEach(draft.repos) { repo in
            RadioRow(
                title: repo.name,
                subtitle: repo.displayPath,
                note: repo.role.isEmpty ? nil : repo.role,
                isSelected: draft.specChoice == .repo && specRepos.first?.id == repo.id
            ) { draft.useSpecRepo(repo.id) }
        }
        AddRow(title: "Add the Spec as a Repo…") { draft.addSpecRepo() }
    }
}

// MARK: - Bounds

/// Grouped by what happens when one fires; one sentence per Bound with the value in bold and a stepper
/// beside it.
struct BoundsBlock: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(BoundsDraft.evidenceNote).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(BoundsDraft.Consequence.allCases, id: \.self) { consequence in
                WizardBlock(title: consequence.title, footer: consequence.footer) {
                    let fields = BoundsDraft.fields(consequence)
                    ForEach(fields, id: \.key) { field in
                        sentenceRow(field)
                        if field.key != fields.last?.key { Divider().padding(.leading, 12) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { draft.bounds = BoundsDraft() }
                    .disabled(draft.bounds.isDefault)
            }
        }
    }

    private func value(_ field: BoundsDraft.Field) -> Binding<Int> {
        $draft.bounds[dynamicMember: field.keyPath]
    }

    private func sentenceRow(_ field: BoundsDraft.Field) -> some View {
        let current = draft.bounds[keyPath: field.keyPath]
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(field.sentence.before) \(Text(field.valueText(current)).bold()) \(field.sentence.after)")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(field.key).font(.caption.monospaced())
                    defaultMark(field, current: current)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Stepper(field.title, value: value(field), in: 1...20).labelsHidden()
        }
        .padding(12)
    }

    @ViewBuilder
    private func defaultMark(_ field: BoundsDraft.Field, current: Int) -> some View {
        if current == field.defaultValue {
            Text("Default").font(.caption).foregroundStyle(.secondary)
        } else {
            Button("Reset to \(field.defaultValue)") { value(field).wrappedValue = field.defaultValue }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
#endif
