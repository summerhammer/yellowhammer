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

    /// Scripted behaviour for one create, keyed by the workflow state or label name (P17.2, OQ80).
    enum Script: Sendable {
        case refuse(BoardError)
    }
    private var scripts: [String: Script] = [:]

    /// The next `createWorkflowState` or `createLabel` naming `nameOrChild` throws `script`'s error,
    /// once, instead of creating.
    func script(_ script: Script, for nameOrChild: String) {
        scripts[nameOrChild] = script
    }
    /// Errors thrown by the next call to ``linearProject()``, in order, consumed before it answers —
    /// following ``FakeWritingBoard/refuseNext(_:)``'s pattern.
    private var refusals: [BoardError] = []
    /// When true, ``linearProject()`` always throws `.scopeNotFound`, even after creation.
    private var alwaysScopeNotFound = false
    /// Errors thrown by the next call to ``workspaceMembers()``, in order, consumed before it answers
    /// (`yh doctor`'s Linear check exercises the authorization failure path).
    private var workspaceMembersRefusals: [BoardError] = []
    var members: [BoardMember] = []
    var boardTeams: [BoardTeam] = []
    /// Teams excluded from ``memberTeams()``'s default — permissive membership in every team of the
    /// bound Linear project, so most tests need no setup at all.
    private var excludedMemberTeams: Set<BoardObjectID> = []
    /// Errors thrown by the next call to ``memberTeams()``, in order, consumed before it answers.
    private var memberTeamsRefusals: [BoardError] = []

    init(project: BoardProjectScope?) {
        self.project = project
    }

    func refuseWorkspaceMembersNext(_ error: BoardError) {
        workspaceMembersRefusals.append(error)
    }

    func workspaceMembers() async throws(BoardError) -> [BoardMember] {
        if !workspaceMembersRefusals.isEmpty {
            throw workspaceMembersRefusals.removeFirst()
        }
        return members
    }

    func teams() async throws(BoardError) -> [BoardTeam] { boardTeams }

    /// What ``linearProjects()`` reports; empty by default.
    var boardLinearProjects: [BoardLinearProject] = []
    /// When set, ``linearProjects()`` throws it.
    var linearProjectsFailure: BoardError?

    func setLinearProjects(_ projects: [BoardLinearProject]) { boardLinearProjects = projects }
    func failLinearProjects(with error: BoardError?) { linearProjectsFailure = error }

    func linearProjects() async throws(BoardError) -> [BoardLinearProject] {
        if let linearProjectsFailure { throw linearProjectsFailure }
        return boardLinearProjects
    }

    /// Excludes `team` from ``memberTeams()`` — the app is installed and can see the team read-only,
    /// but is not a member of it.
    func excludeMembership(of team: BoardObjectID) { excludedMemberTeams.insert(team) }

    func refuseMemberTeamsNext(_ error: BoardError) {
        memberTeamsRefusals.append(error)
    }

    /// Permissive by default: every team of the bound Linear project, plus every workspace team set
    /// with ``setTeams(_:)`` (so a Project not yet created, resolving a team by key through
    /// `teams()`, is still a member of it by default) — minus any explicitly excluded.
    func memberTeams() async throws(BoardError) -> [BoardObjectID] {
        if !memberTeamsRefusals.isEmpty { throw memberTeamsRefusals.removeFirst() }
        let allTeams = Set((project?.teams.map(\.id) ?? []) + boardTeams.map(\.id))
        return allTeams.filter { !excludedMemberTeams.contains($0) }
    }

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
        if case .refuse(let error)? = scripts[name] {
            scripts[name] = nil
            throw error
        }
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
        if case .refuse(let error)? = scripts[name] {
            scripts[name] = nil
            throw error
        }
        let label = BoardLabel(id: mint(), name: name, isGroup: isGroup, parent: parent, team: team)
        teamLabels[team, default: []].append(label)
        return label
    }

    private func mint() -> BoardObjectID {
        nextID += 1
        return BoardObjectID(rawValue: "fake-\(nextID)")
    }
}
