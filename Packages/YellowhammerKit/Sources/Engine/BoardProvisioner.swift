import Domain
import Foundation

/// The declared provisioning scope for a Linear project.
///
/// These constants define the state name and label groups that Yellowhammer provisions
/// at setup time. Only the `Card Type` group is provisioned for every Project: Block Reason is a
/// Journal cause rendered into the Card's Managed Block, not a label (Board Simplification Ruling
/// 2026-10-20), so a board that still has the legacy `Block Reason` group is neither verified nor
/// edited here, and none of its labels is deleted. The Card override is one editable description field on
/// each Work Card, not a label (routing/resolve-a-route-for-a-card, roadmap P22.7), so no `Override` label
/// group is provisioned or required: a board that still carries one, or the older per-axis `Override CLI`,
/// `Override Model` and `Override Effort` groups, is neither read, verified nor edited, and none of its
/// labels is deleted (converting them is P22.8). The settle workflow-state group (`Kept in Flight`, `Abandoned`) is provisioned alongside
/// `Waiting on You` and `Blocked`; a same-name state of another type is a collision, never reused
/// (G-6 probe, 2026-09-23; OQ128).
public struct BoardProvisioner {
    /// The exact name of the workflow state Yellowhammer depends on, glossary-verbatim.
    public static let waitingOnYouState = "Waiting on You"

    /// The category every workflow state Yellowhammer provisions is created with.
    private static let provisionedStateCategory: BoardWorkflowStateCategory = .started

    /// The workflow states provisioned once per team, in this order: Waiting on You, Blocked, then
    /// the legacy settle pair (`FeatureDisposition/legacySettleStateNames`), still provisioned until P22.8.
    private static var declaredWorkflowStates: [String] {
        [waitingOnYouState, blockedState] + FeatureDisposition.legacySettleStateNames
    }

    /// The workflow state for unstarted work.
    public static let todoState = "Todo"

    /// A Feature returning to contention is mapped to the Todo workflow state.
    public static let contentionState = todoState

    /// The workflow state for blocked work.
    public static let blockedState = "Blocked"

    /// Card type label group and its children.
    public static let cardTypeGroup = "Card Type"
    public static let cardTypeChildren = CardType.allCases.map(\.rawValue)

    /// The legacy Block Reason label group's name. No longer provisioned or verified; read only so
    /// ``DispositionLabels`` can remove its labels from a Card on a board that still has them.
    public static let blockReasonGroup = "Block Reason"

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
        createIn team: BoardObjectID?
    ) async throws(BoardError) -> ProvisioningReport {
        try await run(
            using: board, projectName: projectName, createIn: team, createsMissing: true
        )
    }

    /// Provisioning, or with `createsMissing` false its read-only verification (``verify(using:projectName:)``):
    /// the same presence and collision checks, with every create reported `.missing` instead. Internal, not
    /// private: `verify` lives in `BoardProvisioner+Verify.swift`.
    static func run(
        using board: any BoardProvisioning,
        projectName: String,
        createIn team: BoardObjectID?,
        createsMissing: Bool
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
        let memberTeamIDs = Set(try await board.memberTeams())
        for team in project.teams {
            guard memberTeamIDs.contains(team.id) else {
                entries.append(ProvisioningEntry(subject: .team(team), outcome: .notAMember(team.key)))
                continue
            }
            try await provisionTeam(
                board: Target(board: board, createsMissing: createsMissing), team: team, groups: groups,
                into: &entries
            )
        }

        return ProvisioningReport(entries: entries, linearProject: project)
    }

    private static func provisionTeam(
        board: Target,
        team: BoardTeam,
        groups: [LabelGroupDeclaration],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        let existingStates = try await board.workflowStates(team: team.id)
        let existingLabels = try await board.labels(team: team.id)

        try await provisionWorkflowState(
            board: board, team: team, existingStates: existingStates, into: &entries
        )

        for groupSpec in groups {
            try await provisionGroup(
                board: board, group: groupSpec, team: team, existingLabels: existingLabels, into: &entries
            )
        }
    }

    private static func provisionWorkflowState(
        board: Target,
        team: BoardTeam,
        existingStates: [BoardWorkflowState],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        for stateName in Self.declaredWorkflowStates {
            try await provisionWorkflowState(
                named: stateName, board: board, team: team, existingStates: existingStates, into: &entries
            )
        }
    }

    /// Provisions one declared workflow state. Linear's uniqueness is scoped to (name, type), not
    /// name alone (G-6 probe): a same-name state of a different category — including one this build
    /// cannot categorize — is a collision, and is never overwritten or reused.
    private static func provisionWorkflowState(
        named stateName: String,
        board: Target,
        team: BoardTeam,
        existingStates: [BoardWorkflowState],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        let sameName = existingStates.filter { $0.name.lowercased() == stateName.lowercased() }
        if let foreign = sameName.first(where: { $0.category != Self.provisionedStateCategory }) {
            let category = foreign.category.map { "category \($0.rawValue)" } ?? "an unknown category"
            entries.append(ProvisioningEntry(
                subject: .workflowState(stateName, team: team),
                outcome: .collision("team"),
                collidesWith: "workflow state `\(foreign.name)` of \(category)"
            ))
            return
        }
        if sameName.contains(where: { $0.category == Self.provisionedStateCategory }) {
            entries.append(ProvisioningEntry(
                subject: .workflowState(stateName, team: team),
                outcome: .present
            ))
            return
        }
        guard board.createsMissing else {
            entries.append(ProvisioningEntry(
                subject: .workflowState(stateName, team: team), outcome: .missing(notProvisioned)
            ))
            return
        }
        do {
            _ = try await board.createWorkflowState(
                name: stateName, category: Self.provisionedStateCategory, team: team.id
            )
            entries.append(ProvisioningEntry(
                subject: .workflowState(stateName, team: team),
                outcome: .created
            ))
        } catch .forbidden(let reason) {
            // A permission refusal is reported by name — never as the Project's Linear project being
            // invisible — and setup moves on to the next workflow state (Refusals Ruling).
            entries.append(ProvisioningEntry(
                subject: .workflowState(stateName, team: team),
                outcome: .permissionRefused(reason)
            ))
        }
    }

    /// Internal, not private: shared with `BoardProvisioner+Labels.swift`.
    static func scopeDescription(_ teamId: BoardObjectID?) -> String {
        teamId == nil ? "workspace" : "team"
    }
}
