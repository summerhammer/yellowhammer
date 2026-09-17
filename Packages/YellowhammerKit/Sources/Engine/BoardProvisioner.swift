import Domain
import Foundation

/// The declared provisioning scope for a Linear project.
///
/// These constants define the state name and label groups that Yellowhammer provisions
/// at setup time. The three Override label groups (G-17, roadmap P7.6) are provisioned from the
/// merged Routing Table's values when one is given, and refreshed by re-running provisioning after
/// the table changes: a value it no longer names is never removed, because nothing ever clears an
/// Override. The settle workflow-state group (gate G-6, probe owed) is deliberately not provisioned.
public struct BoardProvisioner {
    /// The exact name of the workflow state Yellowhammer depends on, glossary-verbatim.
    static let waitingOnYouState = "Waiting on You"

    /// Object type label group and its children.
    static let objectTypeGroup = "Object Type"
    static let objectTypeChildren = ["Feature", "Card", "Night Card"]

    /// Block Reason label group and its children.
    static let blockReasonGroup = "Block Reason"
    static let blockReasonChildren = BlockReason.allCases.map(\.rawValue)

    /// A label group to be provisioned.
    private struct LabelGroupDeclaration {
        let name: String
        let children: [String]
    }

    /// The label groups provisioned for every Project.
    private static let labelGroups = [
        LabelGroupDeclaration(name: objectTypeGroup, children: objectTypeChildren),
        LabelGroupDeclaration(name: blockReasonGroup, children: blockReasonChildren)
    ]

    /// The Override label groups, with the merged Routing Table's values as their children (G-17).
    private static func overrideGroups(for table: RoutingTable) -> [LabelGroupDeclaration] {
        let values = OverrideLabelValues(table: table)
        return [
            LabelGroupDeclaration(name: overrideCLIGroup, children: values.clis),
            LabelGroupDeclaration(name: overrideModelGroup, children: values.models),
            LabelGroupDeclaration(name: overrideEffortGroup, children: values.efforts)
        ]
    }

    /// Provision the Linear project for one Project.
    ///
    /// The provisioner re-reads presence on each run to ensure idempotency: running
    /// provisioning twice changes nothing on the second run. Reports each subject's outcome:
    /// created, present, collision, blocked, or missing. Board errors propagate; a partial
    /// run is fine and re-running is safe.
    ///
    /// With `routingTable`, the Project's merged Routing Table, the three Override label groups are
    /// provisioned too, one child per distinct value the table names on each axis.
    public static func provision(
        using board: any BoardProvisioning,
        projectName: String,
        createIn team: BoardObjectID?,
        routingTable: RoutingTable? = nil
    ) async throws(BoardError) -> ProvisioningReport {
        var entries: [ProvisioningEntry] = []
        let groups = Self.labelGroups + (routingTable.map(Self.overrideGroups(for:)) ?? [])

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
            _ = try await board.createLinearProject(name: projectName, team: createInTeam)
            entries.append(ProvisioningEntry(
                subject: .linearProject(projectName),
                outcome: .created
            ))
            project = try await board.linearProject()
        }

        // Step 2: For each team, provision workflow state and label groups.
        for team in project.teams {
            try await provisionTeam(board: board, team: team, groups: groups, into: &entries)
        }

        return ProvisioningReport(entries: entries)
    }

    private static func provisionTeam(
        board: any BoardProvisioning,
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
        board: any BoardProvisioning,
        team: BoardTeam,
        existingStates: [BoardWorkflowState],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        let waitingState = existingStates.first { state in
            state.name.lowercased() == Self.waitingOnYouState.lowercased()
        }
        if waitingState != nil {
            entries.append(ProvisioningEntry(
                subject: .workflowState(Self.waitingOnYouState, team: team),
                outcome: .present
            ))
        } else {
            _ = try await board.createWorkflowState(name: Self.waitingOnYouState, team: team.id)
            entries.append(ProvisioningEntry(
                subject: .workflowState(Self.waitingOnYouState, team: team),
                outcome: .created
            ))
        }
    }

    private static func provisionGroup(
        board: any BoardProvisioning,
        group: LabelGroupDeclaration,
        team: BoardTeam,
        existingLabels: [BoardLabel],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        // Check for group collisions: any non-group label with group's name.
        let groupCollision = existingLabels.first { label in
            label.name.lowercased() == group.name.lowercased() && !label.isGroup
        }
        if let collision = groupCollision {
            entries.append(ProvisioningEntry(
                subject: .labelGroup(group.name, team: team),
                outcome: .collision(scopeDescription(collision.team))
            ))
            for child in group.children {
                entries.append(ProvisioningEntry(
                    subject: .label(child, group: group.name, team: team),
                    outcome: .blocked("group name collision")
                ))
            }
            return
        }
        let groupId = try await ensureGroupExists(
            board: board, groupName: group.name, team: team, existingLabels: existingLabels, into: &entries
        )
        for childName in group.children {
            let child = existingLabels.first { $0.name.lowercased() == childName.lowercased() && $0.parent == groupId }
            if child != nil {
                let subject = ProvisioningEntry.Subject.label(childName, group: group.name, team: team)
                entries.append(ProvisioningEntry(subject: subject, outcome: .present))
            } else {
                let collision = existingLabels.first { label in
                    label.name.lowercased() == childName.lowercased() && label.parent != groupId
                }
                if let collision = collision {
                    let subject = ProvisioningEntry.Subject.label(childName, group: group.name, team: team)
                    let outcome = ProvisioningEntry.Outcome.collision(scopeDescription(collision.team))
                    entries.append(ProvisioningEntry(subject: subject, outcome: outcome))
                } else {
                    _ = try await board.createLabel(name: childName, team: team.id, isGroup: false, parent: groupId)
                    let subject = ProvisioningEntry.Subject.label(childName, group: group.name, team: team)
                    entries.append(ProvisioningEntry(subject: subject, outcome: .created))
                }
            }
        }
    }

    private static func ensureGroupExists(
        board: any BoardProvisioning,
        groupName: String,
        team: BoardTeam,
        existingLabels: [BoardLabel],
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) -> BoardObjectID {
        let existingGroup = existingLabels.first { label in
            label.name.lowercased() == groupName.lowercased() && label.isGroup
        }
        if let existing = existingGroup {
            entries.append(ProvisioningEntry(
                subject: .labelGroup(groupName, team: team),
                outcome: .present
            ))
            return existing.id
        }
        let created = try await board.createLabel(
            name: groupName,
            team: team.id,
            isGroup: true,
            parent: nil
        )
        entries.append(ProvisioningEntry(
            subject: .labelGroup(groupName, team: team),
            outcome: .created
        ))
        return created.id
    }

    private static func scopeDescription(_ teamId: BoardObjectID?) -> String {
        teamId == nil ? "workspace" : "team"
    }
}

/// One entry in a provisioning report.
public struct ProvisioningEntry: Sendable {
    public enum Subject: Hashable, Sendable {
        case linearProject(String)
        case workflowState(String, team: BoardTeam)
        case labelGroup(String, team: BoardTeam)
        case label(String, group: String, team: BoardTeam)
    }

    public enum Outcome: Equatable, Sendable {
        case present
        case created
        case collision(String)
        case blocked(String)
        case missing(String)
    }

    public var subject: Subject
    public var outcome: Outcome

    public init(subject: Subject, outcome: Outcome) {
        self.subject = subject
        self.outcome = outcome
    }
}

/// The result of a provisioning run.
public struct ProvisioningReport: Sendable {
    public var entries: [ProvisioningEntry]

    public init(entries: [ProvisioningEntry]) {
        self.entries = entries
    }

    /// The entries where outcome is created.
    public var changes: [ProvisioningEntry] {
        entries.filter { entry in
            if case .created = entry.outcome {
                return true
            }
            return false
        }
    }

    /// The entries where outcome is collision.
    public var collisions: [ProvisioningEntry] {
        entries.filter { entry in
            if case .collision = entry.outcome {
                return true
            }
            return false
        }
    }

    /// True if any changes (created) were made.
    public var isChanged: Bool {
        !changes.isEmpty
    }
}

extension ProvisioningReport: CustomStringConvertible {
    public var description: String {
        entries.map { entry in
            let subjectStr = subjectString(entry.subject)
            let outcomeStr = outcomeString(entry.outcome)
            return "\(outcomeStr)  \(subjectStr)"
        }.joined(separator: "\n")
    }

    private func subjectString(_ subject: ProvisioningEntry.Subject) -> String {
        switch subject {
        case .linearProject(let name):
            "linear project `\(name)`" // glossary:ignore GL001
        case .workflowState(let name, let team):
            "workflow state `\(name)` (team \(team.key))"
        case .labelGroup(let name, let team):
            "group label `\(name)` (team \(team.key))"
        case .label(let name, let group, let team):
            "label `\(name)` in group `\(group)` (team \(team.key))"
        }
    }

    private func outcomeString(_ outcome: ProvisioningEntry.Outcome) -> String {
        switch outcome {
        case .present:
            "present "
        case .created:
            "created "
        case .collision(let scope):
            "collision (\(scope)-level)"
        case .blocked(let reason):
            "blocked  (\(reason))"
        case .missing(let reason):
            "missing  (\(reason))"
        }
    }
}
