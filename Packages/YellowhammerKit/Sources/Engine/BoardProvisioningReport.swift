import Domain

/// One entry in a provisioning report.
public struct ProvisioningEntry: Sendable {
    public enum Subject: Hashable, Sendable {
        case linearProject(String)
        /// A whole team, not one of its items — reported when Yellowhammer's identity is not a member
        /// of it (Board Provisioning Ruling, OQ80), before any item in it is attempted.
        case team(BoardTeam)
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
        /// Yellowhammer's identity is not a member of the team named (its key), so no create was
        /// attempted in it (Board Provisioning Ruling, OQ80).
        case notAMember(String)
        /// The board answered `FORBIDDEN` (or an HTTP 403) while creating this item, though the
        /// identity is a member of the team — a permission refusal, named by the vendor's own reason,
        /// never reported as the Project's Linear project being invisible. Also used for a label whose
        /// own group's create was refused: it was never attempted, since nothing can be created under
        /// a group that does not exist.
        case permissionRefused(String)
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
    /// The Linear project that was found or created, or nil when missing. Setup needs the created
    /// project's id to write into the Project file.
    public var linearProject: BoardProjectScope?

    public init(entries: [ProvisioningEntry], linearProject: BoardProjectScope? = nil) {
        self.entries = entries
        self.linearProject = linearProject
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

    /// The entries setup could not finish: not a member, or a permission refusal. Every other step
    /// still ran (Refusals Ruling) — these are reported individually, and the create-by-hand guideline
    /// follows for the missing items only. `.blocked` is excluded on purpose: it also covers an
    /// ordinary name collision (rename the colliding label — not a create-by-hand item).
    public var unfinished: [ProvisioningEntry] {
        entries.filter { entry in
            switch entry.outcome {
            case .notAMember, .permissionRefused:
                true
            case .present, .created, .collision, .missing, .blocked:
                false
            }
        }
    }

    /// True once any team is unfinished: not a member, or a lingering permission refusal / block.
    public var hasUnfinishedSteps: Bool { !unfinished.isEmpty }

    /// ``unfinished``, rendered the same way ``description`` renders every entry — for the
    /// consolidated list setup prints once at the end of its output.
    public var unfinishedDescription: String {
        ProvisioningReport(entries: unfinished).description
    }

    /// The create-by-hand guideline (Refusals Ruling): each unfinished workflow state with its
    /// category, each unfinished label group with its children, and the statement that setup
    /// re-verifies afterwards. Empty when nothing is unfinished.
    public var createByHandGuideline: String? {
        guard hasUnfinishedSteps else { return nil }
        var lines = ["To finish by hand in Linear, then re-run setup (it re-verifies afterwards):"]
        for entry in unfinished {
            switch entry.subject {
            case .team(let team):
                lines.append("- add Yellowhammer as a member in team \(team.key)'s Settings → Members")
            case .workflowState(let name, let team):
                lines.append("- workflow state `\(name)` (category started) in team \(team.key)")
            case .labelGroup(let name, let team):
                lines.append("- label group `\(name)` in team \(team.key)")
            case .label(let name, let group, let team):
                lines.append("- label `\(name)` in group `\(group)` in team \(team.key)")
            case .linearProject:
                break
            }
        }
        return lines.joined(separator: "\n")
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
        case .team(let team):
            "team \(team.key)"
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
        case .notAMember(let teamKey):
            "not a member of team \(teamKey)"
        case .permissionRefused(let reason):
            "permission refused (\(reason))"
        }
    }
}
