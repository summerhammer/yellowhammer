import Domain
import Engine

/// An in-memory board: labels and workflow states per team, workspace labels visible to every team,
/// and a count of every create it was asked for. Shared by ``BoardProvisionerTests`` and
/// ``SetupTests``.
actor FakeProvisioningBoard: BoardProvisioning {
    private var project: BoardProjectScope?
    private var states: [BoardObjectID: [BoardWorkflowState]] = [:]
    private var teamLabels: [BoardObjectID: [BoardLabel]] = [:]
    private var workspaceLabels: [BoardLabel] = []
    private var nextID = 0
    private(set) var creates = 0
    private(set) var reads = 0
    /// Errors thrown by the next call to ``linearProject()``, in order, consumed before it answers —
    /// following ``FakeWritingBoard/refuseNext(_:)``'s pattern.
    private var refusals: [BoardError] = []
    /// When true, ``linearProject()`` always throws `.scopeNotFound`, even after creation.
    private var alwaysScopeNotFound = false
    var members: [BoardMember] = []
    var boardTeams: [BoardTeam] = []

    init(project: BoardProjectScope?) {
        self.project = project
    }

    func workspaceMembers() async throws(BoardError) -> [BoardMember] { members }

    func teams() async throws(BoardError) -> [BoardTeam] { boardTeams }

    func setMembers(_ members: [BoardMember]) { self.members = members }
    func setTeams(_ teams: [BoardTeam]) { boardTeams = teams }

    func refuseNext(_ error: BoardError) {
        refusals.append(error)
    }

    func seed(workspaceLabel name: String) {
        workspaceLabels.append(BoardLabel(id: mint(), name: name, isGroup: false, parent: nil, team: nil))
    }

    func seed(label name: String, team: BoardObjectID, isGroup: Bool = false, parent: BoardObjectID? = nil) {
        let label = BoardLabel(id: mint(), name: name, isGroup: isGroup, parent: parent, team: team)
        teamLabels[team, default: []].append(label)
    }

    func seed(state name: String, team: BoardObjectID, category: BoardWorkflowStateCategory? = nil) {
        states[team, default: []].append(BoardWorkflowState(id: mint(), name: name, category: category))
    }

    func alwaysThrowScopeNotFound() { alwaysScopeNotFound = true }

    func linearProject() async throws(BoardError) -> BoardProjectScope {
        reads += 1
        if alwaysScopeNotFound { throw .scopeNotFound("still not visible to this identity") }
        if !refusals.isEmpty { throw refusals.removeFirst() }
        guard let project else { throw .scopeNotFound("no such Linear project") }
        return project
    }

    func createLinearProject(name: String, team: BoardObjectID) async throws(BoardError) -> BoardProjectScope {
        creates += 1
        let scope = BoardProjectScope(id: mint(), name: name, teams: [BoardTeam(id: team, key: "NEW", name: "New")])
        project = scope
        return scope
    }

    func workflowStates(team: BoardObjectID) async throws(BoardError) -> [BoardWorkflowState] {
        reads += 1
        return states[team, default: []]
    }

    func createWorkflowState(
        name: String, category: BoardWorkflowStateCategory, team: BoardObjectID
    ) async throws(BoardError) -> BoardWorkflowState {
        creates += 1
        let state = BoardWorkflowState(id: mint(), name: name, category: category)
        states[team, default: []].append(state)
        return state
    }

    func labels(team: BoardObjectID) async throws(BoardError) -> [BoardLabel] {
        reads += 1
        return teamLabels[team, default: []] + workspaceLabels
    }

    func createLabel(
        name: String, team: BoardObjectID, isGroup: Bool, parent: BoardObjectID?
    ) async throws(BoardError) -> BoardLabel {
        creates += 1
        let label = BoardLabel(id: mint(), name: name, isGroup: isGroup, parent: parent, team: team)
        teamLabels[team, default: []].append(label)
        return label
    }

    private func mint() -> BoardObjectID {
        nextID += 1
        return BoardObjectID(rawValue: "fake-\(nextID)")
    }
}
