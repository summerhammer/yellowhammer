import Domain
import Foundation

/// The declared provisioning scope for a Linear project.
///
/// Yellowhammer's footprint on a team is exactly two custom `started` workflow states, `Waiting on You` and
/// `Blocked`, and the `Card Type` label group with its three children (Board Simplification Ruling
/// 2026-10-20; board-projection/provision-the-board, roadmap P22.8). Every other state is the team's native
/// state, selected by workflow category and never created (``NativeStateSelection``). Block Reason is a
/// Journal cause rendered into the Card's Managed Block, and the Card override is one description field
/// (routing/resolve-a-route-for-a-card): so no `Block Reason` or `Override` label group is provisioned.
///
/// A same-name state is never adopted by name alone: the two custom states are reused from a persisted id,
/// or a Board Mapping; otherwise the name is a collision (G-6 probe, 2026-09-23; OQ128).
public struct BoardProvisioner {
    /// The exact name of the workflow state Yellowhammer depends on, glossary-verbatim.
    public static let waitingOnYouState = "Waiting on You"

    /// The category every workflow state Yellowhammer provisions is created with.
    static let provisionedStateCategory: BoardWorkflowStateCategory = .started

    /// The workflow state for unstarted work.
    public static let todoState = "Todo"

    /// A Feature returning to contention is mapped to the Todo workflow state.
    public static let contentionState = todoState

    /// The workflow state for blocked work.
    public static let blockedState = "Blocked"

    /// Card type label group and its children.
    public static let cardTypeGroup = "Card Type"
    public static let cardTypeChildren = CardType.allCases.map(\.rawValue)

    /// A label group to be provisioned. Internal, not private: shared with the label-group
    /// provisioning in `BoardProvisioner+Labels.swift`, split out to stay under the file-length limit.
    struct LabelGroupDeclaration {
        let name: String
        let children: [String]
    }

    /// The label groups provisioned for every Project.
    private static let labelGroups = [
        LabelGroupDeclaration(name: cardTypeGroup, children: cardTypeChildren)
    ]

    /// Provision the Linear project for one Project.
    ///
    /// The provisioner re-reads presence on each run to ensure idempotency: running
    /// provisioning twice changes nothing on the second run. Reports each subject's outcome:
    /// created, present, collision, blocked, or missing. Board errors propagate; a partial
    /// run is fine and re-running is safe.
    public static func provision(
        using board: any BoardProvisioning,
        projectName: String,
        createIn team: BoardObjectID?,
        footprint: BoardFootprintInputs = .none
    ) async throws(BoardError) -> ProvisioningReport {
        try await run(
            using: board, projectName: projectName, createIn: team, createsMissing: true, footprint: footprint
        )
    }

    /// Provisioning, or with `createsMissing` false its read-only verification (``verify(using:projectName:)``):
    /// the same presence and collision checks, with every create reported `.missing` instead. Internal, not
    /// private: `verify` lives in `BoardProvisioner+Verify.swift`.
    static func run(
        using board: any BoardProvisioning,
        projectName: String,
        createIn team: BoardObjectID?,
        createsMissing: Bool,
        footprint: BoardFootprintInputs = .none
    ) async throws(BoardError) -> ProvisioningReport {
        var entries: [ProvisioningEntry] = []
        let groups = Self.labelGroups

        // Step 1: Verify or create the Linear project.
        let project: BoardProjectScope
        do {
            project = try await board.linearProject()
            entries.append(ProvisioningEntry(
                subject: .linearProject(project.name),
                outcome: .present
            ))
        } catch .scopeNotFound {
            guard let createInTeam = team else {
                entries.append(ProvisioningEntry(
                    subject: .linearProject(projectName),
                    outcome: .missing("no team specified")
                ))
                return ProvisioningReport(entries: entries)
            }
            project = try await board.createLinearProject(name: projectName, team: createInTeam)
            entries.append(ProvisioningEntry(
                subject: .linearProject(projectName),
                outcome: .created
            ))
        }

        // Step 2: For each team, check membership first (Board Provisioning Ruling, OQ80), then
        // provision workflow state and label groups. A team the app is not a member of — including one
        // the Board Connection never selected, invisible to `teams()` too — gets no create attempt at
        // all; it is reported and setup moves on to the next team.
        let snapshots = try await readMemberTeams(of: project, using: board, into: &entries)
        let persisted = (try? footprint.store?.persistedFootprint()) ?? []
        let verified = verifyMapping(footprint.mapping, against: snapshots)
        entries += verified.entries
        for snapshot in snapshots {
            try await provisionTeam(
                board: Target(
                    board: board, createsMissing: createsMissing, store: footprint.store,
                    mapping: verified.mapping, unusable: verified.unusable, persisted: persisted
                ),
                snapshot: snapshot, groups: groups, into: &entries
            )
        }

        return ProvisioningReport(
            entries: entries, linearProject: project,
            footprint: footprintRecords(
                from: entries, mapping: verified.mapping, persisted: persisted
            )
        )
    }

    /// Reads the states and labels of every team of `project` that Yellowhammer's identity is a member of;
    /// a team it is not a member of is reported and gets nothing else.
    private static func readMemberTeams(
        of project: BoardProjectScope, using board: any BoardProvisioning, into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) -> [TeamSnapshot] {
        let memberTeamIDs = Set(try await board.memberTeams())
        var snapshots: [TeamSnapshot] = []
        for team in project.teams {
            guard memberTeamIDs.contains(team.id) else {
                entries.append(ProvisioningEntry(subject: .team(team), outcome: .notAMember(team.key)))
                continue
            }
            snapshots.append(TeamSnapshot(
                team: team,
                states: try await board.workflowStates(team: team.id),
                labels: try await board.labels(team: team.id)
            ))
        }
        return snapshots
    }

    private static func provisionTeam(
        board: Target,
        snapshot: TeamSnapshot,
        groups: [LabelGroupDeclaration],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        let (team, existingStates) = (snapshot.team, snapshot.states)

        for role in BoardMappingRole.customStates {
            try await provisionCustomState(
                role, board: board, team: team, existingStates: existingStates, into: &entries
            )
        }
        reportNativeCategories(board: board, team: team, states: existingStates, into: &entries)

        for groupSpec in groups {
            try await provisionGroup(board: board, group: groupSpec, snapshot: snapshot, into: &entries)
        }
    }

    /// Internal, not private: shared with `BoardProvisioner+Labels.swift`.
    static func scopeDescription(_ teamId: BoardObjectID?) -> String {
        teamId == nil ? "workspace" : "team"
    }
}
