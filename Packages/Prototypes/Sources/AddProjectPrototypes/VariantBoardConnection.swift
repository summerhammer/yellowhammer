#if DEBUG
import SwiftUI

// The two parts of the board page every layout shares: the Linear workspace — which connected App
// Installation the Project uses, with "Connect another Linear workspace…" — and the Linear project id,
// verified against that workspace before the page is ready.

// MARK: - State

extension AddProjectDraft {
    var selectedWorkspace: LinearWorkspaceFixture? { workspaces.first { $0.localName == linearWorkspace } }

    /// Selecting another workspace drops a project or team chosen in the last one.
    mutating func selectWorkspace(_ localName: String) {
        guard localName != linearWorkspace else { return }
        linearWorkspace = localName
        linearProjectID = nil
        teamKey = nil
        pastedProjectID = ""
        verification = .unchecked
    }

    mutating func setOperatorIdentity(_ member: String) {
        guard let index = workspaces.firstIndex(where: { $0.localName == linearWorkspace }) else { return }
        workspaces[index].operatorIdentity = member
    }

    /// The fixture approval: the new installation joins the list and is selected. It would stay in the
    /// registry if the wizard were cancelled — it is machine configuration, not the Project's.
    mutating func finishConnecting() {
        let new = AddProjectFixtures.connectableWorkspace
        if !workspaces.contains(new) { workspaces.append(new) }
        connection = .idle
        selectWorkspace(new.localName)
    }

    /// A listed project is one setup read from the workspace, so it is verified as it is picked.
    mutating func selectListedProject(_ id: String) {
        pastedProjectID = id
        linearProjectID = id
        verification = .verified
    }

    /// Typing or pasting an id un-verifies it until it is checked again.
    mutating func editProjectID(_ text: String) {
        pastedProjectID = text
        linearProjectID = nil
        verification = .unchecked
    }

    /// The fixture check of the pasted id against the selected workspace.
    mutating func verifyProjectID() {
        let id = pastedProjectID.trimmingCharacters(in: .whitespaces)
        guard let project = AddProjectFixtures.allLinearProjects.first(where: { $0.id == id }) else {
            verification = .notFound
            return
        }
        if project.workspace != linearWorkspace {
            let other = workspaces.first { $0.localName == project.workspace }
            verification = other.map { .otherWorkspace($0.localName) } ?? .notFound
        } else if !project.readable {
            verification = .noTeamAccess(project.teamName)
        } else {
            linearProjectID = project.id
            verification = .verified
        }
    }

    /// The board page's problems: a workspace, its Operator identity, then a verified Linear project or
    /// a team to create one in.
    var boardProblems: [String] {
        guard let workspace = selectedWorkspace else {
            return [workspaces.isEmpty ? "Connect a Linear workspace." : "Choose the Linear workspace."]
        }
        var problems: [String] = []
        if workspace.operatorIdentity == nil {
            problems.append("Choose your Operator identity in \(workspace.name).")
        }
        switch linearChoice {
        case .existing:
            if pastedProjectID.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("Choose the Linear project, or paste its id.") // glossary:ignore GL001
            } else if let problem = verificationProblem(in: workspace) {
                problems.append(problem)
            }
        case .createInTeam:
            if !AddProjectFixtures.teams(in: linearWorkspace).contains(where: { $0.key == teamKey }) {
                problems.append("Choose a team to create the Linear project in.") // glossary:ignore GL001
            }
        }
        return problems
    }

    private func verificationProblem(in workspace: LinearWorkspaceFixture) -> String? {
        switch verification {
        case .verified: nil
        case .unchecked, .checking: "Verify the Linear project id." // glossary:ignore GL001
        case .notFound: "No Linear project has that id in \(workspace.name)." // glossary:ignore GL001
        case .otherWorkspace(let other):
            "That Linear project is in \(workspaceName(other)), not \(workspace.name)." // glossary:ignore GL001
        case .noTeamAccess(let team): "Yellowhammer is not a member of the team \(team)."
        }
    }

    func workspaceName(_ localName: String) -> String {
        workspaces.first { $0.localName == localName }?.name ?? localName
    }
}

// MARK: - Linear workspace

/// The connected Linear workspaces, the Operator identity the selected one still needs, and the way to
/// connect another. With none connected, it goes straight to connecting.
struct LinearWorkspaceSection: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.workspaces.isEmpty {
                WizardBlock(title: "Linear workspace") {
                    Text("Yellowhammer connects to Linear through its own app, approved once by a workspace admin.")
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                ConnectWorkspaceView(draft: $draft, offersCancel: false)
            } else {
                WizardBlock(title: "Linear workspace") {
                    ForEach(draft.workspaces) { workspace in
                        RadioRow(
                            title: workspace.name,
                            subtitle: workspace.name == workspace.localName ? nil : workspace.localName,
                            note: workspace.operatorIdentity ?? "No Operator identity yet",
                            isSelected: draft.linearWorkspace == workspace.localName
                        ) { draft.selectWorkspace(workspace.localName) }
                    }
                }
                if let workspace = draft.selectedWorkspace, workspace.operatorIdentity == nil {
                    operatorIdentity(workspace)
                }
                if draft.connection == .idle {
                    Button("Connect Another Linear Workspace\u{2026}") { draft.connection = .choosing }
                } else {
                    ConnectWorkspaceView(draft: $draft, offersCancel: true)
                }
            }
        }
    }

    private func operatorIdentity(_ workspace: LinearWorkspaceFixture) -> some View {
        WizardBlock(
            title: "Operator identity",
            footer: "Chosen once for \(workspace.name), for every Project in it. Change it later in Settings; "
                + "issues already waiting on you keep their assignee."
        ) {
            OperatorIdentityExplanation()
            Divider().padding(.leading, 12)
            WizardBlockRow(label: "You in Linear", detail: "A member of \(workspace.name), not a bot.") {
                Picker("Operator identity", selection: Binding(
                    get: { workspace.operatorIdentity ?? "" },
                    set: { draft.setOperatorIdentity($0) }
                )) {
                    Text("Choose\u{2026}").tag("")
                    ForEach(AddProjectFixtures.workspaceMembers, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// What the Operator identity is, why Yellowhammer needs it, and how it is used, from the glossary.
private struct OperatorIdentityExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You are the Operator: the person Yellowhammer works for. It writes to Linear as its own "
                + "app, so it needs to know which Linear user is you.")
                .fixedSize(horizontal: false, vertical: true)
            point(
                "person.crop.circle.badge.exclamationmark",
                "When a Card or Feature needs your decision, Yellowhammer moves it to Waiting on You and "
                    + "assigns it to you, so it shows up in your Linear inbox."
            )
            point(
                "hand.raised",
                "It assigns only as the issue enters Waiting on You. If you reassign it by hand, that stands."
            )
            point(
                "person.slash",
                "If that user leaves the workspace, the issue still moves to Waiting on You, just unassigned."
            )
        }
        .font(.callout)
        .padding(12)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}

/// The install: here as an admin, or by asking one; then the wait for approval.
private struct ConnectWorkspaceView: View {
    @Binding var draft: AddProjectDraft
    let offersCancel: Bool

    var body: some View {
        WizardBlock(
            title: "Connect a Linear workspace",
            footer: "A workspace connected here stays connected if you cancel adding the Project."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                switch draft.connection {
                case .idle, .choosing:
                    HStack {
                        Button("Install Here as a Workspace Admin\u{2026}") { // glossary:ignore GL001
                            draft.connection = .awaitingApproval(remote: false)
                        }
                        Button("Request Approval from an Admin\u{2026}") {
                            draft.connection = .awaitingApproval(remote: true)
                        }
                        Spacer()
                        if offersCancel { Button("Cancel") { draft.connection = .idle } }
                    }
                case .awaitingApproval(let remote):
                    if remote {
                        Text("Send this link to a workspace admin. Yellowhammer connects once they approve.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("https://linear.app/oauth/authorize?client_id=yh\u{2026}")
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Copy Link") {}
                        }
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(remote ? "Waiting for the admin to approve\u{2026}" : "Approve in the browser\u{2026}")
                        Spacer()
                        Button("Cancel") { draft.connection = .idle }
                        // The prototype's stand-in for the browser.
                        Button("Simulate Approval") { draft.finishConnecting() }
                    }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Linear project id

/// The id field under the list, and what checking it against the selected workspace found.
struct ProjectIDVerification: View { // glossary:ignore GL001
    @Binding var draft: AddProjectDraft
    let isListEmpty: Bool

    private var trimmedID: String { draft.pastedProjectID.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        WizardBlock(
            footer: isListEmpty
                ? "Copy it from the Linear project\u{2019}s URL or its settings." // glossary:ignore GL001
                : "Not listed? Paste its id from the Linear project\u{2019}s URL or settings." // glossary:ignore GL001
        ) {
            WizardBlockRow(label: "Linear project id") { // glossary:ignore GL001
                HStack(spacing: 6) {
                    TextField(
                        "Linear project id", // glossary:ignore GL001
                        text: Binding(get: { draft.pastedProjectID }, set: { draft.editProjectID($0) }),
                        prompt: Text("Paste the id from Linear")
                    )
                    .labelsHidden()
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220)
                    .onSubmit(verify)
                    Button("Verify", action: verify)
                        .disabled(trimmedID.isEmpty || draft.verification == .verified
                            || draft.verification == .checking)
                }
            }
            if !trimmedID.isEmpty {
                Divider().padding(.leading, 12)
                result.padding(.horizontal, 12).padding(.vertical, 9)
            }
        }
    }

    /// The fixture check, with a moment's wait so "Checking" is seen.
    private func verify() {
        guard !trimmedID.isEmpty else { return }
        draft.verification = .checking
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            draft.verifyProjectID()
        }
    }

    @ViewBuilder private var result: some View {
        let workspace = draft.selectedWorkspace?.name ?? "this workspace"
        switch draft.verification {
        case .unchecked:
            Label("Not verified yet", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking with Linear\u{2026}").foregroundStyle(.secondary)
            }
        case .verified:
            Label(verifiedText, systemImage: "checkmark.seal.fill")
                .foregroundStyle(WizardTheme.success)
        case .notFound:
            Label("No Linear project has this id in \(workspace).", // glossary:ignore GL001
                  systemImage: "xmark.octagon.fill")
                .foregroundStyle(WizardTheme.error)
        case .otherWorkspace(let other):
            HStack(alignment: .firstTextBaseline) {
                let otherName = draft.workspaceName(other)
                Label(
                    "This Linear project is in \(otherName), not \(workspace).", // glossary:ignore GL001
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(WizardTheme.attention)
                Spacer()
                Button("Use \(draft.workspaceName(other))") {
                    let id = draft.pastedProjectID
                    draft.selectWorkspace(other)
                    draft.pastedProjectID = id
                    draft.verifyProjectID()
                }
            }
        case .noTeamAccess(let team):
            Label(
                "It exists, but Yellowhammer is not a member of the team \(team). Ask a team admin to add "
                    + "Yellowhammer in the team\u{2019}s settings, then verify again.",
                systemImage: "lock.fill"
            )
            .foregroundStyle(WizardTheme.error)
        }
    }

    private var verifiedText: String {
        guard let linear = draft.linearProject else { return "Verified" }
        return "\u{201c}\(linear.name)\u{201d} in team \(linear.teamName). Yellowhammer can read it."
    }
}
#endif
