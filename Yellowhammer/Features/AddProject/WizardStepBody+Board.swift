import Config
import Domain
import SwiftUI

// MARK: - Board

/// The Board step: a section per board. Linear's picks the Linear workspace (an App Installation in the
/// registry), then an existing Linear project or a team to create one in. Jira's is drawn, disabled and
/// marked Coming later: the step is shaped for more than one board without pretending to support one.
struct BoardBlock: View {
    @Binding var draft: AddProjectDraft
    let workspaces: LinearWorkspacesModel
    let onSelect: (String) -> Void
    var onVerify: () -> Void = {}
    @State private var isConnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Linear").font(.headline)
            workspaceBlock
            if draft.selectedLinearInstallation == nil {
                Text("Choose the Linear workspace first.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup-linear-choose-workspace-first")
            } else {
                projectChoice
            }
            Divider()
            jiraBlock
        }
    }

    /// Jira, not yet supported: its two choices, disabled.
    private var jiraBlock: some View {
        WizardBlock(title: "Jira", footer: "Coming later. Yellowhammer supports Linear only today.") {
            RadioRow(title: "Use an existing Jira project", isSelected: false) {} // glossary:ignore GL001
            Divider().padding(.leading, 12)
            RadioRow(title: "Create a new Jira project", isSelected: false) {} // glossary:ignore GL001
        }
        .disabled(true)
        .opacity(0.5)
        .accessibilityIdentifier("setup-board-jira")
    }

    // MARK: Linear workspace

    @ViewBuilder private var workspaceBlock: some View {
        if workspaces.workspaces.isEmpty {
            WizardBlock(title: "Linear workspace", boxed: false) {
                Text("Yellowhammer connects to Linear through its own app, approved once by a workspace admin.")
                    .foregroundStyle(.secondary)
            }
            connectView(offersCancel: false)
        } else {
            WizardBlock(title: "Linear workspace") {
                ForEach(workspaces.workspaces) { workspace in
                    let label = workspaces.label(for: workspace)
                    RadioRow(
                        title: label,
                        subtitle: label == workspace.name ? nil : workspace.name,
                        note: workspace.operatorIdentity?.rawValue ?? "No Operator identity yet",
                        isSelected: draft.linearInstallationName == workspace.name,
                        identifier: "setup-linear-installation-\(workspace.name)"
                    ) {
                        onSelect(workspace.name)
                    }
                }
            }
            if let name = draft.linearInstallationName,
               let workspace = workspaces.workspaces.first(where: { $0.name == name }),
               workspace.operatorIdentity == nil,
               let operatorModel = workspaces.operatorModel(for: name) {
                WizardOperatorIdentityBlock(model: operatorModel, workspaceLabel: workspaceLabel)
            }
            if isConnecting {
                connectView(offersCancel: true)
            } else {
                Button("Connect Another Linear Workspace\u{2026}") { isConnecting = true }
                    .accessibilityIdentifier("setup-linear-connect-another")
            }
        }
    }

    /// The install, boxed under its own heading. `offersCancel` closes it again before an install starts;
    /// once one runs, its own Cancel stops it.
    private func connectView(offersCancel: Bool) -> some View {
        WizardBlock(
            title: "Connect a Linear workspace",
            footer: "A workspace connected here stays connected if you cancel adding the Project."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                LinearInstallationView(
                    model: workspaces.connectAnother,
                    offersReinstall: workspaces.connectAnother.phase.isInstalled,
                    arrangesInstallButtonsInRow: true,
                    onDismiss: offersCancel ? { isConnecting = false } : nil
                )
            }
            .padding(12)
        }
    }

    // MARK: Linear project

    /// The selected workspace's label, as its row in the workspace list names it.
    private var workspaceLabel: String {
        guard let name = draft.linearInstallationName else { return "" }
        return workspaces.workspaces.first { $0.name == name }.map(workspaces.label(for:)) ?? name
    }

    @ViewBuilder private var projectChoice: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Linear project in \(workspaceLabel)") // glossary:ignore GL001
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                OptionCards {
                    OptionCard(
                        title: "Existing Linear project", // glossary:ignore GL001
                        detail: "Pick a Linear project you already plan in.", // glossary:ignore GL001
                        isSelected: draft.linearChoice == .existing,
                        identifier: "setup-linear-choice-existing"
                    ) {
                        draft.linearChoice = .existing
                    }
                    OptionCard(
                        title: "New Linear project", // glossary:ignore GL001
                        detail: draft.displayName.isEmpty
                            ? "Yellowhammer creates one in a team you choose, named after the Project."
                            : "Yellowhammer creates \u{201c}\(draft.displayName)\u{201d} in a team you choose.",
                        isSelected: draft.linearChoice == .createInTeam,
                        identifier: "setup-linear-choice-create"
                    ) {
                        draft.linearChoice = .createInTeam
                    }
                }
            }
            switch draft.linearChoice {
            case .existing:
                if !draft.context.linearProjects.isEmpty {
                    WizardBlock(boxed: true) {
                        ForEach(draft.context.linearProjects, id: \.id) { project in
                            RadioRow(
                                title: project.name,
                                note: project.teamNames.joined(separator: ", "),
                                isSelected: draft.linearProjectID == project.id,
                                identifier: "setup-linear-project-\(project.id)"
                            ) {
                                draft.linearProjectID = project.id
                            }
                        }
                    }
                }
                let trimmedID = draft.linearProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
                WizardBlock(
                    footer: draft.context.linearProjects.isEmpty
                        ? "Copy it from the Linear project\u{2019}s URL or its settings." // glossary:ignore GL001
                        // glossary:ignore GL001
                        : "Not listed? Paste its id from the Linear project\u{2019}s URL or settings."
                ) {
                    WizardBlockRow(label: "Linear project id") { // glossary:ignore GL001
                        HStack(spacing: 6) {
                            TextField(
                                "Linear project id",
                                text: $draft.linearProjectID,
                                prompt: Text("Paste the id from Linear")
                            )
                            .labelsHidden()
                            .font(.body.monospaced())
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 220)
                            .accessibilityIdentifier("setup-linear-project-id")
                            .onSubmit { onVerify() }
                            Button("Verify", action: onVerify)
                                .accessibilityIdentifier("setup-linear-verify")
                                .disabled(
                                    trimmedID.isEmpty || draft.effectiveLinearVerification == .checking
                                        || draft.isLinearProjectVerified
                                )
                        }
                    }
                    if !trimmedID.isEmpty {
                        Divider().padding(.leading, 12)
                        linearVerificationResult(workspace: draft.selectedLinearInstallation?.name ?? "this workspace")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    }
                }
            case .createInTeam:
                WizardBlock(boxed: true) {
                    if draft.context.teams.isEmpty {
                        Text(
                            "No teams yet. Yellowhammer reads them from Linear once it is installed."
                        )
                        .foregroundStyle(.secondary)
                        .padding(12)
                    } else {
                        ForEach(draft.context.teams, id: \.id) { team in
                            RadioRow(
                                title: team.name,
                                note: team.key,
                                isSelected: draft.teamKey == team.key,
                                identifier: "setup-team-\(team.key)"
                            ) {
                                draft.teamKey = team.key
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linearVerificationResult(workspace: String) -> some View {
        switch draft.effectiveLinearVerification {
        case .unchecked:
            Label("Not verified yet", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("setup-linear-result-unchecked")
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking with Linear\u{2026}").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("setup-linear-result-checking")
        case .verified(let name, let teamNames):
            Label(verifiedText(name: name, teamNames: teamNames), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.success)
                .accessibilityIdentifier("setup-linear-result-verified")
        case .notFound:
            Label(
                "No Linear project has this id in \(workspace).", // glossary:ignore GL001
                systemImage: "xmark.octagon.fill"
            )
            .foregroundStyle(.error)
            .accessibilityIdentifier("setup-linear-result-not-found")
        case .noTeamAccess(let teamNames):
            let team = teamNames.first ?? "its team"
            Label(
                "It exists, but Yellowhammer is not a member of the team \(team). Ask a team admin to add "
                    + "Yellowhammer in the team\u{2019}s settings, then verify again.",
                systemImage: "lock.fill"
            )
            .foregroundStyle(.error)
            .accessibilityIdentifier("setup-linear-result-no-team-access")
        }
    }

    private func verifiedText(name: String, teamNames: [String]) -> String {
        let teamPhrase = teamNames.isEmpty ? "" : " in team \(teamNames.joined(separator: ", "))"
        if name.isEmpty {
            return "Verified\(teamPhrase). Yellowhammer can read it."
        }
        return "\u{201c}\(name)\u{201d}\(teamPhrase). Yellowhammer can read it."
    }
}
