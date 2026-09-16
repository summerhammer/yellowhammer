import Domain
import Foundation

/// The declared provisioning scope for a Linear project.
///
/// These constants define the state name and label groups that Yellowhammer provisions
/// at setup time. The settle workflow-state group (gate G-6, probe owed) and Override label
/// groups (gate G-17, roadmap P7.6) are deliberately not provisioned here.
public struct BoardProvisioner {
    /// The exact name of the workflow state Yellowhammer depends on, glossary-verbatim.
    static let waitingOnYouState = "Waiting on You"

    /// Object type label group and its children.
    static let objectTypeGroup = "Object Type"
    static let objectTypeChildren = ["Feature", "Card", "Night Card"]

    /// Block Reason label group and its children.
    static let blockReasonGroup = "Block Reason"
    static let blockReasonChildren = [
        "blocked by reviewer",
        "blocked by check",
        "hard failure",
        "unanswered",
        "undecided"
    ]

    /// A label group to be provisioned.
    private struct LabelGroupDeclaration {
        let name: String
        let children: [String]
    }

    /// All label groups to provision.
    private static let labelGroups = [
        LabelGroupDeclaration(name: objectTypeGroup, children: objectTypeChildren),
        LabelGroupDeclaration(name: blockReasonGroup, children: blockReasonChildren)
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
        var entries: [ProvisioningEntry] = []

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
            try await provisionTeam(board: board, team: team, into: &entries)
        }

        return ProvisioningReport(entries: entries)
    }

    private static func provisionTeam(
        board: any BoardProvisioning,
        team: BoardTeam,
        into entries: inout [ProvisioningEntry]
    ) async throws(BoardError) {
        let existingStates = try await board.workflowStates(team: team.id)
        let existingLabels = try await board.labels(team: team.id)

        try await provisionWorkflowState(
            board: board, team: team, existingStates: existingStates, into: &entries
        )

        for groupSpec in Self.labelGroups {
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
