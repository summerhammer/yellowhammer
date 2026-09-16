import Foundation

/// The Board Provisioning Port (setup-time): how Yellowhammer provisions the board for one Project.
///
/// An implementation is bound to exactly one Project's Linear project when it is constructed.
///
/// The Port is not the policy. The Engine decides which state name and label groups to provision;
/// an implementation translates and never decides. The Engine's provisioner reads presence on each run
/// to ensure idempotency: running provisioning twice changes nothing on the second run.
public protocol BoardProvisioning: Sendable {
    /// The Linear project bound to this Project, as it exists on the board.
    /// Throws scopeNotFound when not visible to this identity.
    func linearProject() async throws(BoardError) -> BoardProjectScope

    /// Create a new Linear project with the given name in the specified team.
    /// Returns the created project's scope.
    func createLinearProject(name: String, team: BoardObjectID) async throws(BoardError) -> BoardProjectScope

    /// All workflow states in the given team. Archived states are excluded by the board.
    func workflowStates(team: BoardObjectID) async throws(BoardError) -> [BoardWorkflowState]

    /// Create a new workflow state in the given team with the given name.
    /// The adapter chooses the Linear type and color; these are vendor details.
    func createWorkflowState(name: String, team: BoardObjectID) async throws(BoardError) -> BoardWorkflowState

    /// All labels visible to the team: team-scoped labels in that team plus workspace-level labels.
    func labels(team: BoardObjectID) async throws(BoardError) -> [BoardLabel]

    /// Create a new label in the team with the given name, optionally as a group or with a parent.
    func createLabel(
        name: String, team: BoardObjectID, isGroup: Bool, parent: BoardObjectID?
    ) async throws(BoardError) -> BoardLabel
}

/// A Linear project as it exists on the board, with its teams.
public struct BoardProjectScope: Hashable, Sendable {
    public var id: BoardObjectID
    public var name: String
    /// The teams this project belongs to.
    public var teams: [BoardTeam]

    public init(id: BoardObjectID, name: String, teams: [BoardTeam]) {
        self.id = id
        self.name = name
        self.teams = teams
    }
}

/// A team within a Linear workspace.
public struct BoardTeam: Hashable, Sendable {
    public var id: BoardObjectID
    /// Linear's short key for the team, e.g. "ENG".
    public var key: String
    public var name: String

    public init(id: BoardObjectID, key: String, name: String) {
        self.id = id
        self.key = key
        self.name = name
    }
}

/// A label as it exists on the board.
public struct BoardLabel: Hashable, Sendable {
    public var id: BoardObjectID
    public var name: String
    /// True if this label is a group (can have child labels).
    public var isGroup: Bool
    /// The parent label id if this label is a child; nil for ungrouped labels.
    public var parent: BoardObjectID?
    /// The team this label is scoped to; nil if it is workspace-wide.
    public var team: BoardObjectID?

    public init(
        id: BoardObjectID, name: String, isGroup: Bool, parent: BoardObjectID?, team: BoardObjectID?
    ) {
        self.id = id
        self.name = name
        self.isGroup = isGroup
        self.parent = parent
        self.team = team
    }
}
