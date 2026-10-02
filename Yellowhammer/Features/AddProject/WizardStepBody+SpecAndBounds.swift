import Config
import SwiftUI

// MARK: - Spec Source

/// The choice between a shared Spec Source folder or a Repo in this Project.
struct SpecBlock: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OptionCards {
                OptionCard(
                    title: "A shared spec folder",
                    detail: "A checkout of the specification, kept outside this Project.",
                    points: ["Several Projects can read it", "No Repo Role, Check or Worktree"],
                    isSelected: draft.specChoice == .path,
                    identifier: "setup-spec-choice-path"
                ) {
                    draft.specChoice = .path
                }
                OptionCard(
                    title: "A Repo in this Project",
                    detail: "One of this Project\u{2019}s Repos, with Repo Role \u{201c}spec\u{201d}.",
                    points: ["Belongs to this Project only", "Declared with the other Repos"],
                    isSelected: draft.specChoice == .repo,
                    identifier: "setup-spec-choice-repo"
                ) {
                    draft.specChoice = .repo
                }
            }
            VStack(spacing: 0) {
                switch draft.specChoice {
                case .path:
                    folderRows
                case .repo:
                    repoRows
                }
            }
            .background(.surface, in: .rect(cornerRadius: 10))

            if draft.visited.contains(.specSource) {
                let problems = draft.problems(in: .specSource)
                if !problems.isEmpty {
                    WizardProblemList(problems: problems)
                }
            }
        }
    }

    private var folderRows: some View {
        VStack(spacing: 0) {
            ForEach(draft.context.specSourceReaders.keys.sorted(), id: \.self) { path in
                let readers = draft.context.specSourceReaders[path] ?? []
                RadioRow(
                    title: (path as NSString).abbreviatingWithTildeInPath,
                    note: "read by \(readers.formatted(.list(type: .and)))",
                    monospaced: true,
                    isSelected: draft.specChoice == .path
                        && AddProjectContext.normalizedPath(draft.specSourcePath)
                        == AddProjectContext.normalizedPath(path)
                ) {
                    draft.useSpecSource((path as NSString).abbreviatingWithTildeInPath)
                }
            }
            if draft.specChoice == .path, !draft.specSourcePath.isEmpty,
               !draft.context.specSourceReaders.keys.contains(where: {
                   AddProjectContext.normalizedPath($0) == AddProjectContext.normalizedPath(draft.specSourcePath)
               }) {
                RadioRow(
                    title: (draft.specSourcePath as NSString).abbreviatingWithTildeInPath,
                    note: "chosen",
                    monospaced: true,
                    isSelected: true
                ) {}
            }
            AddRow(title: "Choose Another Folder…", identifier: "setup-spec-choose-folder") {
                guard let url = SetupWizardModel.chooseFolder() else { return }
                draft.useSpecSource(SetupWizardModel.abbreviatingPath(url))
            }
        }
    }

    private var repoRows: some View {
        VStack(spacing: 0) {
            ForEach(draft.repos) { repo in
                let specRepo = draft.repos.first(where: { $0.role == "spec" })
                RadioRow(
                    title: repo.name,
                    subtitle: repo.displayPath,
                    note: repo.role.isEmpty ? nil : repo.role,
                    isSelected: draft.specChoice == .repo && specRepo?.id == repo.id,
                    identifier: "setup-spec-repo-\(repo.name)"
                ) {
                    draft.useSpecRepo(repo.id)
                }
            }
            AddRow(title: "Add the Spec as a Repo…", identifier: "setup-spec-add-repo") {
                guard let url = SetupWizardModel.chooseFolder() else { return }
                draft.addSpecRepo(path: SetupWizardModel.abbreviatingPath(url))
            }
        }
    }
}

// MARK: - Bounds

/// The six per-Project Bounds, grouped by their consequence and presented as sentences.
struct BoundsBlock: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(Bounds.evidenceNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Bounds.Consequence.allCases, id: \.self) { consequence in
                WizardBlock(title: consequence.title, footer: consequence.footer) {
                    let fields = Bounds.fields(consequence)
                    ForEach(fields, id: \.key) { field in
                        sentenceRow(field)
                        if field.key != fields.last?.key {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Restore Defaults") {
                    draft.bounds = Bounds()
                }
                .disabled(draft.bounds.isDefault)
            }
        }
    }

    private func sentenceRow(_ field: Bounds.Field) -> some View {
        let current = draft.bounds[keyPath: field.keyPath]
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    "\(field.sentence.before) \(Text(field.valueText(current)).bold()) \(field.sentence.after)"
                )
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(field.key).font(.caption.monospaced())
                    defaultMark(field, current: current)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Stepper(field.title, value: Binding {
                draft.bounds[keyPath: field.keyPath]
            } set: { newValue in
                draft.bounds[keyPath: field.keyPath] = newValue
            }, in: 1...20).labelsHidden()
        }
        .padding(12)
    }

    @ViewBuilder
    private func defaultMark(_ field: Bounds.Field, current: Int) -> some View {
        if current == field.defaultValue {
            Text("Default").font(.caption).foregroundStyle(.secondary)
        } else {
            Button("Reset to \(field.defaultValue)") {
                draft.bounds[keyPath: field.keyPath] = field.defaultValue
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}
