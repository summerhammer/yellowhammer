#if DEBUG
import SwiftUI

// The board page in four layouts. Every layout offers the same four choices — an existing Linear
// project, a new Linear project, an existing Jira project, a new Jira project — and only Linear's can
// be picked today. Jira's are drawn, disabled and marked Coming later, so the page is shaped for more
// than one board without pretending to support one.

/// The board page for a `BoardLayout`. Each layout picks the board first, then the Linear workspace,
/// then an existing Linear project (verified) or a team to create one in.
struct VariantBoardBlock: View {
    @Binding var draft: AddProjectDraft
    let layout: BoardLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch layout {
            case .fourCards: fourCards
            case .vendorSwitch: vendorSwitch
            case .vendorCards: vendorCards
            case .groupedList: groupedList
            }
        }
    }

    /// The project part waits for a workspace: the lists and the check are the workspace's.
    @ViewBuilder private func onceWorkspaceChosen(@ViewBuilder _ content: () -> some View) -> some View {
        if draft.selectedWorkspace == nil {
            Text(draft.workspaces.isEmpty ? "Connect a Linear workspace first." : "Choose the Linear workspace first.")
                .foregroundStyle(.secondary)
        } else {
            content()
        }
    }

    // MARK: Four cards

    @ViewBuilder private var fourCards: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                OptionCard(
                    title: "Existing Linear project", // glossary:ignore GL001
                    detail: "Pick a Linear project you already plan in.", // glossary:ignore GL001
                    isSelected: draft.linearChoice == .existing
                ) { draft.linearChoice = .existing }
                OptionCard(
                    title: "New Linear project", // glossary:ignore GL001
                    detail: "Yellowhammer creates \(newProjectName) in a team you choose.",
                    isSelected: draft.linearChoice == .createInTeam
                ) { draft.linearChoice = .createInTeam }
            }
            GridRow {
                unsupportedCard(
                    "Existing Jira project", // glossary:ignore GL001
                    detail: "Pick a Jira project you already plan in." // glossary:ignore GL001
                )
                unsupportedCard(
                    "New Jira project", // glossary:ignore GL001
                    detail: "Yellowhammer creates one in a Jira site."
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        LinearWorkspaceSection(draft: $draft)
        onceWorkspaceChosen { LinearChoiceList(draft: $draft) }
    }

    // MARK: Board switch

    @ViewBuilder private var vendorSwitch: some View {
        WizardBlock(footer: "Linear is the only board Yellowhammer supports today.") {
            WizardBlockRow(label: "Board") { BoardSwitch(selection: $draft.boardVendor) }
        }
        LinearWorkspaceSection(draft: $draft)
        onceWorkspaceChosen {
            OptionCards {
                OptionCard(
                    title: "Use an existing one",
                    detail: "Pick a Linear project you already plan in.", // glossary:ignore GL001
                    isSelected: draft.linearChoice == .existing
                ) { draft.linearChoice = .existing }
                OptionCard(
                    title: "Create a new one",
                    detail: "Yellowhammer creates \(newProjectName) in a team you choose.",
                    isSelected: draft.linearChoice == .createInTeam
                ) { draft.linearChoice = .createInTeam }
            }
            LinearChoiceList(draft: $draft)
        }
    }

    // MARK: Board cards

    @ViewBuilder private var vendorCards: some View {
        OptionCards {
            OptionCard(
                title: "Linear",
                detail: "Features are Linear issues; Cards are their sub-issues.",
                points: ["Use an existing Linear project", "Or create one in a team"], // glossary:ignore GL001
                isSelected: draft.boardVendor == .linear
            ) { draft.boardVendor = .linear }
            unsupportedCard(
                "Jira",
                detail: "Features from a Jira project.", // glossary:ignore GL001
                points: ["Use an existing Jira project", "Or create one in a site"] // glossary:ignore GL001
            )
        }
        LinearWorkspaceSection(draft: $draft)
        onceWorkspaceChosen {
            Picker("Project", selection: $draft.linearChoice) {
                Text("Existing project").tag(LinearProjectChoice.existing) // glossary:ignore GL001
                Text("New project").tag(LinearProjectChoice.createInTeam) // glossary:ignore GL001
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            LinearChoiceList(draft: $draft)
        }
    }

    // MARK: Grouped lists

    @ViewBuilder private var groupedList: some View {
        Text("Linear").font(.headline)
        LinearWorkspaceSection(draft: $draft)
        onceWorkspaceChosen {
            VStack(alignment: .leading, spacing: 6) {
                Text("Linear project in \(draft.selectedWorkspace?.name ?? "")") // glossary:ignore GL001
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                OptionCards {
                    OptionCard(
                        title: "Existing Linear project", // glossary:ignore GL001
                        detail: "Pick a Linear project you already plan in.", // glossary:ignore GL001
                        isSelected: draft.linearChoice == .existing
                    ) { draft.linearChoice = .existing }
                    OptionCard(
                        title: "New Linear project", // glossary:ignore GL001
                        detail: "Yellowhammer creates \(newProjectName) in a team you choose.",
                        isSelected: draft.linearChoice == .createInTeam
                    ) { draft.linearChoice = .createInTeam }
                }
            }
            LinearChoiceList(draft: $draft)
        }
        Divider()
        WizardBlock(title: "Jira", footer: "Coming later. Yellowhammer supports Linear only today.") {
            RadioRow(title: "Use an existing Jira project", isSelected: false) {} // glossary:ignore GL001
            Divider().padding(.leading, 12)
            RadioRow(title: "Create a new Jira project", isSelected: false) {} // glossary:ignore GL001
        }
        .disabled(true)
        .opacity(0.5)
    }

    // MARK: Parts

    private var newProjectName: String {
        draft.displayName.isEmpty ? "one named after the Project" : "\u{201c}\(draft.displayName)\u{201d}"
    }

    private func unsupportedCard(_ title: String, detail: String, points: [String] = []) -> some View {
        OptionCard(title: title, detail: detail, points: points, isSelected: false) {}
            .overlay(alignment: .topTrailing) { ComingLaterBadge().padding(10) }
            .disabled(true)
            .opacity(0.55)
    }
}

/// The selected workspace's Linear projects with the id field and its check, or its teams to create
/// one in.
struct LinearChoiceList: View { // glossary:ignore GL001
    @Binding var draft: AddProjectDraft

    var body: some View {
        switch draft.linearChoice {
        case .existing:
            let projects = AddProjectFixtures.listedProjects(in: draft.linearWorkspace)
            VStack(alignment: .leading, spacing: 12) {
                if !projects.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(projects) { project in
                            RadioRow(
                                title: project.name, note: project.teamName,
                                isSelected: draft.linearProjectID == project.id
                            ) { draft.selectListedProject(project.id) }
                        }
                    }
                    .background(WizardTheme.surface, in: .rect(cornerRadius: 10))
                }
                ProjectIDVerification(draft: $draft, isListEmpty: projects.isEmpty)
            }
        case .createInTeam:
            let teams = AddProjectFixtures.teams(in: draft.linearWorkspace)
            VStack(spacing: 0) {
                if teams.isEmpty {
                    Text("No teams in this workspace that Yellowhammer can see.")
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(teams) { team in
                    RadioRow(title: team.name, note: team.key, isSelected: draft.teamKey == team.key) {
                        draft.teamKey = team.key
                    }
                }
            }
            .background(WizardTheme.surface, in: .rect(cornerRadius: 10))
        }
    }
}

/// A segmented choice of board, with the unsupported ones drawn but disabled.
private struct BoardSwitch: View {
    @Binding var selection: BoardVendor

    var body: some View {
        HStack(spacing: 2) {
            ForEach(BoardVendor.allCases) { vendor in
                Button { selection = vendor } label: {
                    HStack(spacing: 4) {
                        Text(vendor.rawValue)
                        if !vendor.isSupported {
                            Text("later").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        selection == vendor ? AnyShapeStyle(.background) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 5)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!vendor.isSupported)
                .accessibilityAddTraits(selection == vendor ? .isSelected : [])
            }
        }
        .padding(2)
        .background(WizardTheme.surface, in: .rect(cornerRadius: 7))
    }
}

struct ComingLaterBadge: View {
    var body: some View {
        Text("Coming later")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(WizardTheme.surface, in: .capsule)
    }
}

extension AddProjectDraft {
    /// "“Acme Platform” · Acme Corp", for the board page's sidebar row.
    var boardSummary: String {
        guard let workspace = selectedWorkspace else { return "No Linear workspace" }
        return switch linearChoice {
        case .existing:
            linearProject.map { "\u{201c}\($0.name)\u{201d} · \(workspace.name)" } ?? "Linear · \(workspace.name)"
        case .createInTeam:
            team.map { "New in \($0.name) · \(workspace.name)" } ?? "Linear · \(workspace.name)"
        }
    }
}

#Preview("Board layouts") {
    @Previewable @State var draft: AddProjectDraft = {
        var draft = AddProjectDraft()
        draft.setName("Acme")
        draft.selectWorkspace("summerhammer")
        draft.pastedProjectID = "5ec2e700"
        return draft
    }()
    let layouts: [(String, BoardLayout)] = [
        ("Four cards — A, F", .fourCards), ("Board switch — B", .vendorSwitch),
        ("Board cards — D, E", .vendorCards), ("Grouped lists — C, G", .groupedList)
    ]
    Grid(horizontalSpacing: 24, verticalSpacing: 24) {
        GridRow {
            ForEach(layouts.prefix(2), id: \.0) { layout in
                VStack(alignment: .leading) {
                    Text(layout.0).font(.headline)
                    VariantBoardBlock(draft: $draft, layout: layout.1)
                }
                .frame(width: 600, alignment: .topLeading)
            }
        }
        GridRow {
            ForEach(layouts.suffix(2), id: \.0) { layout in
                VStack(alignment: .leading) {
                    Text(layout.0).font(.headline)
                    VariantBoardBlock(draft: $draft, layout: layout.1)
                }
                .frame(width: 600, alignment: .topLeading)
            }
        }
    }
    .padding(24)
}
#endif
