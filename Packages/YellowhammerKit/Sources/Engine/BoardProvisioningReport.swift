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
        /// A native workflow category (`unstarted`, `started`, `completed`, `canceled`) the team must hold
        /// a state of, selected by category and never created (board-projection/provision-the-board).
        case nativeCategory(String, team: BoardTeam)
        /// A Board Mapping entry (its `[board.linear.mapping]` key) that failed verification.
        case boardMapping(String)
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
        /// The item cannot be provisioned as declared, and creating it by hand would not help either: an
        /// `Override` label whose Route text collides with another Route's, or that the board refuses
        /// as a label name (OQ126). The reason names the Routing Entries to change.
        case refused(String)
        /// A Board Mapping entry that fails verification: the id does not exist, has the wrong category, or
        /// serves two meanings. Nothing is inferred from a matching name in its place.
        case invalidMapping(String)
    }

    public var subject: Subject
    public var outcome: Outcome
    /// The board id of the item, for a `.present` or `.created` one that has an id worth recording.
    public var id: BoardObjectID?
    /// For a `.collision` of a custom workflow state: the exact `[board.linear.mapping]` lines the Operator
    /// can add to adopt an existing state as Yellowhammer's own. Nil otherwise.
    public var mappingHint: String?
    /// For a custom-state `.collision`: the ids of the same-name `started` states that could be adopted.
    public var candidates: [BoardObjectID]
    /// For a `.collision`: the existing item that holds the name, as the Operator would find it in
    /// Linear (e.g. label `Night Card` in group `Object Type`), so the fix can name it. Nil otherwise.
    public var collidesWith: String?

    public init(
        subject: Subject, outcome: Outcome, collidesWith: String? = nil, id: BoardObjectID? = nil,
        mappingHint: String? = nil, candidates: [BoardObjectID] = []
    ) {
        self.candidates = candidates
        self.subject = subject
        self.outcome = outcome
        self.collidesWith = collidesWith
        self.id = id
        self.mappingHint = mappingHint
    }
}

/// The result of a provisioning run.
public struct ProvisioningReport: Sendable {
    public var entries: [ProvisioningEntry]
    /// The Linear project that was found or created, or nil when missing. Setup needs the created
    /// project's id to write into the Project file.
    public var linearProject: BoardProjectScope?
    /// The footprint ids this run resolved and that the Project's Journal does not yet hold (or holds
    /// differently): the ids of states setup created, a mapped object, a bootstrapped one. The caller
    /// records them; a run that only verifies never writes.
    public var footprint: [BoardFootprintRecord]

    public init(
        entries: [ProvisioningEntry], linearProject: BoardProjectScope? = nil, footprint: [BoardFootprintRecord] = []
    ) {
        self.entries = entries
        self.linearProject = linearProject
        self.footprint = footprint
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

    /// The entries setup could not finish: not a member, a permission refusal, or a name collision
    /// (and the children it blocks). Every other step still ran (Refusals Ruling) — these are
    /// reported individually. The create-by-hand guideline follows for the not-a-member and refused
    /// items; a collision gets ``collisionGuideline`` instead, since creating it by hand would collide
    /// too. Without this, a collision left setup "complete" while every Act failed on the label it
    /// could not provision (#361).
    public var unfinished: [ProvisioningEntry] {
        entries.filter { entry in
            switch entry.outcome {
            case .notAMember, .permissionRefused, .collision, .blocked, .invalidMapping:
                true
            case .present, .created, .missing, .refused:
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
        let createByHand = unfinished.filter { entry in
            switch entry.outcome {
            case .notAMember, .permissionRefused:
                true
            default:
                false
            }
        }
        guard !createByHand.isEmpty else { return nil }
        var lines = ["To finish by hand in Linear, then re-run setup (it re-verifies afterwards):"]
        for entry in createByHand {
            switch entry.subject {
            case .team(let team):
                lines.append("- add Yellowhammer as a member in team \(team.key)'s Settings → Members")
            case .workflowState(let name, let team):
                lines.append("- workflow state `\(name)` (category started) in team \(team.key)")
            case .labelGroup(let name, let team):
                lines.append("- label group `\(name)` in team \(team.key)")
            case .label(let name, let group, let team):
                lines.append("- label `\(name)` in group `\(group)` in team \(team.key)")
            case .linearProject, .nativeCategory, .boardMapping:
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
            var outcomeStr = outcomeString(entry.outcome)
            if case .collision(let scope) = entry.outcome, let existing = entry.collidesWith {
                outcomeStr = "collision (\(scope)-level, with \(existing))"
            }
            return "\(outcomeStr)  \(subjectStr)"
        }.joined(separator: "\n")
    }

    private func subjectString(_ subject: ProvisioningEntry.Subject) -> String {
        subject.description
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
        case .refused(let reason):
            "refused  (\(reason))"
        case .invalidMapping(let reason):
            "invalid mapping  (\(reason))"
        }
    }
}

extension ProvisioningEntry.Subject: CustomStringConvertible {
    /// The item as setup and `yh doctor` name it, e.g. label `Night Card` in group `Card Type` (team YLH).
    public var description: String {
        switch self {
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
        case .nativeCategory(let category, let team):
            "native workflow category `\(category)` (team \(team.key))"
        case .boardMapping(let key):
            "Board Mapping `\(key)`"
        }
    }
}
