import Domain
import Engine
import Testing

/// An in-memory board: labels and workflow states per team, workspace labels visible to every team,
/// and a count of every create it was asked for.
actor FakeProvisioningBoard: BoardProvisioning {
    private var project: BoardProjectScope?
    private var states: [BoardObjectID: [BoardWorkflowState]] = [:]
    private var teamLabels: [BoardObjectID: [BoardLabel]] = [:]
    private var workspaceLabels: [BoardLabel] = []
    private var nextID = 0
    private(set) var creates = 0
    private(set) var reads = 0

    init(project: BoardProjectScope?) {
        self.project = project
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

    func linearProject() async throws(BoardError) -> BoardProjectScope {
        reads += 1
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

    func createWorkflowState(name: String, team: BoardObjectID) async throws(BoardError) -> BoardWorkflowState {
        creates += 1
        let state = BoardWorkflowState(id: mint(), name: name)
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

private let engineering = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering")
private let product = BoardTeam(id: BoardObjectID(rawValue: "team-2"), key: "PRD", name: "Product")

private func board(teams: [BoardTeam] = [engineering]) -> FakeProvisioningBoard {
    let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: teams)
    return FakeProvisioningBoard(project: scope)
}

private func provision(
    _ board: FakeProvisioningBoard, createIn team: BoardObjectID? = nil
) async throws -> ProvisioningReport {
    try await BoardProvisioner.provision(using: board, projectName: "Yellowhammer", createIn: team)
}

private func outcome(
    of report: ProvisioningReport, _ matches: (ProvisioningEntry.Subject) -> Bool
) -> ProvisioningEntry.Outcome? {
    report.entries.first { matches($0.subject) }?.outcome
}

private func label(_ name: String, in group: String) -> (ProvisioningEntry.Subject) -> Bool {
    { subject in
        if case .label(name, group, _) = subject { return true }
        return false
    }
}

private func objectTypeGroup(_ subject: ProvisioningEntry.Subject) -> Bool {
    if case .labelGroup("Object Type", _) = subject { return true }
    return false
}

private func blockReasonGroup(_ subject: ProvisioningEntry.Subject) -> Bool {
    if case .labelGroup("Block Reason", _) = subject { return true }
    return false
}

private func waitingOnYou(_ subject: ProvisioningEntry.Subject) -> Bool {
    if case .workflowState("Waiting on You", _) = subject { return true }
    return false
}

@Suite("Board provisioning")
struct BoardProvisionerTests {
    @Test("A bare team gets Waiting on You, both label groups and all ten labels, and the report names each")
    func firstRunCreatesTheDeclaredSet() async throws {
        let board = board()
        let report = try await provision(board)

        #expect(await board.creates == 13)
        #expect(report.changes.count == 13)
        #expect(outcome(of: report, waitingOnYou) == .created)
        #expect(outcome(of: report, objectTypeGroup) == .created)
        #expect(outcome(of: report, blockReasonGroup) == .created)
        for name in ["Feature", "Card", "Night Card"] {
            #expect(outcome(of: report, label(name, in: "Object Type")) == .created)
        }
        for name in [
            "blocked by reviewer", "blocked by check", "hard failure", "host crash", "unanswered", "undecided"
        ] {
            #expect(outcome(of: report, label(name, in: "Block Reason")) == .created)
        }
    }

    @Test("Provisioning twice changes nothing the second time")
    func secondRunChangesNothing() async throws {
        let board = board()
        _ = try await provision(board)
        let createsAfterFirstRun = await board.creates

        let second = try await provision(board)

        #expect(await board.creates == createsAfterFirstRun)
        #expect(!second.isChanged)
        #expect(second.entries.allSatisfy { $0.outcome == .present })
    }

    @Test("A workspace label named Feature is a collision, not overwritten, and the rest of the group is created")
    func workspaceFeatureCollides() async throws {
        let board = board()
        await board.seed(workspaceLabel: "Feature")

        let first = try await provision(board)
        #expect(outcome(of: first, label("Feature", in: "Object Type")) == .collision("workspace"))
        #expect(outcome(of: first, label("Card", in: "Object Type")) == .created)
        #expect(outcome(of: first, label("Night Card", in: "Object Type")) == .created)
        #expect(first.collisions.count == 1)

        let createsAfterFirstRun = await board.creates
        let second = try await provision(board)
        #expect(await board.creates == createsAfterFirstRun)
        #expect(!second.isChanged)
        #expect(outcome(of: second, label("Feature", in: "Object Type")) == .collision("workspace"))
    }

    @Test("A label in another group with a child's name is a collision")
    func childNameInAnotherGroupCollides() async throws {
        let board = board()
        await board.seed(label: "Status", team: engineering.id, isGroup: true)
        let status = try await board.labels(team: engineering.id)[0].id
        await board.seed(label: "unanswered", team: engineering.id, parent: status)

        let report = try await provision(board)

        #expect(outcome(of: report, label("unanswered", in: "Block Reason")) == .collision("team"))
        #expect(outcome(of: report, label("undecided", in: "Block Reason")) == .created)
    }

    @Test("A label that is not a group, grouped or not, holding a group's name blocks the group and its labels")
    func groupNameCollisionBlocksChildren() async throws {
        for parent: BoardObjectID? in [nil, BoardObjectID(rawValue: "some-other-group")] {
            let board = board()
            await board.seed(label: "Block Reason", team: engineering.id, parent: parent)

            let report = try await provision(board)

            #expect(outcome(of: report, blockReasonGroup) == .collision("team"))
            let blocked = report.entries.filter {
                if case .blocked = $0.outcome, case .label(_, "Block Reason", _) = $0.subject { return true }
                return false
            }
            #expect(blocked.count == BlockReason.allCases.count)
            #expect(await board.creates == 5) // Waiting on You, Object Type and its three labels
        }
    }

    @Test("An existing Waiting on You in a different case is present, not created again")
    func waitingOnYouMatchesCaseInsensitively() async throws {
        let board = board()
        await board.seed(state: "waiting on you", team: engineering.id)

        let report = try await provision(board)

        #expect(outcome(of: report, waitingOnYou) == .present)
        #expect(await board.creates == 12)
    }

    @Test("A missing Linear project with no team named is reported missing and nothing else is touched")
    func missingLinearProjectWithoutTeam() async throws {
        let board = FakeProvisioningBoard(project: nil)

        let report = try await provision(board)

        #expect(report.entries.count == 1)
        guard case .missing = report.entries[0].outcome else {
            Issue.record("expected missing, got \(report.entries[0].outcome)")
            return
        }
        #expect(await board.creates == 0)
        #expect(await board.reads == 1)
    }

    @Test("A missing Linear project is created in the named team, and that team is then provisioned")
    func missingLinearProjectWithTeam() async throws {
        let board = FakeProvisioningBoard(project: nil)

        let report = try await provision(board, createIn: engineering.id)

        guard case .linearProject = report.entries[0].subject else {
            Issue.record("expected the Linear project first, got \(report.entries[0].subject)")
            return
        }
        #expect(report.entries[0].outcome == .created)
        #expect(report.changes.count == 14)
    }

    @Test("Each team of the Linear project is provisioned on its own")
    func eachTeamIsProvisioned() async throws {
        let board = board(teams: [engineering, product])
        await board.seed(state: "Waiting on You", team: engineering.id)

        let report = try await provision(board)

        let states = report.entries.compactMap { entry -> (String, ProvisioningEntry.Outcome)? in
            if case .workflowState(_, let team) = entry.subject { return (team.key, entry.outcome) }
            return nil
        }
        #expect(states.map(\.0) == ["ENG", "PRD"])
        #expect(states.map(\.1) == [.present, .created])
        #expect(await board.creates == 25)
    }

    // MARK: - Override label groups (G-17, P7.6)

    private static func route(_ cli: String, _ model: String, _ effort: String) -> Route {
        Route(cli: cli, model: model, effort: effort)!
    }

    private static let table = RoutingTable(entries: [
        RoutingEntry(route: route("claude", "sonnet", "medium"), fallbacks: [route("codex", "gpt-5.4", "medium")]),
        RoutingEntry(kind: Kind("impl")!, route: route("claude", "opus", "high"))
    ])

    @Test("With a Routing Table, the three Override groups are provisioned with the table's values as children")
    func overrideGroupsAreProvisionedFromTheTable() async throws {
        let board = board()
        let report = try await BoardProvisioner.provision(
            using: board, projectName: "Yellowhammer", createIn: nil, routingTable: Self.table
        )

        // 13 as before, plus three groups and 2 + 3 + 2 children.
        #expect(await board.creates == 23)
        for group in ["Override CLI", "Override Model", "Override Effort"] {
            #expect(outcome(of: report) { if case .labelGroup(group, _) = $0 { true } else { false } } == .created)
        }
        for name in ["claude", "codex"] {
            #expect(outcome(of: report, label(name, in: "Override CLI")) == .created)
        }
        for name in ["gpt-5.4", "opus", "sonnet"] {
            #expect(outcome(of: report, label(name, in: "Override Model")) == .created)
        }
        for name in ["high", "medium"] {
            #expect(outcome(of: report, label(name, in: "Override Effort")) == .created)
        }
        let labels = OverrideLabels(labels: try await board.labels(team: engineering.id))
        #expect(labels.cli.keys.sorted() == ["claude", "codex"])
        #expect(labels.model.keys.sorted() == ["gpt-5.4", "opus", "sonnet"])
        #expect(labels.effort.keys.sorted() == ["high", "medium"])
    }

    @Test("Provisioning the same table twice creates nothing the second time")
    func overrideGroupsAreIdempotent() async throws {
        let board = board()
        _ = try await BoardProvisioner.provision(
            using: board, projectName: "Yellowhammer", createIn: nil, routingTable: Self.table
        )
        let createsAfterFirstRun = await board.creates

        let second = try await BoardProvisioner.provision(
            using: board, projectName: "Yellowhammer", createIn: nil, routingTable: Self.table
        )

        #expect(await board.creates == createsAfterFirstRun)
        #expect(!second.isChanged)
    }

    @Test("A table that gains a value is refreshed by creating exactly that child; nothing is removed")
    func overrideGroupsRefreshWhenTheTableChanges() async throws {
        let board = board()
        _ = try await BoardProvisioner.provision(
            using: board, projectName: "Yellowhammer", createIn: nil, routingTable: Self.table
        )
        let createsAfterFirstRun = await board.creates

        var grown = Self.table
        grown.entries.append(RoutingEntry(kind: Kind("review")!, route: Self.route("codex", "o3", "high")))
        let report = try await BoardProvisioner.provision(
            using: board, projectName: "Yellowhammer", createIn: nil, routingTable: grown
        )

        #expect(await board.creates == createsAfterFirstRun + 1)
        #expect(report.changes.map(\.subject) == [.label("o3", group: "Override Model", team: engineering)])

        // A shrunken table removes nothing: the Operator's pins are never cleared.
        let shrunk = RoutingTable(entries: [Self.table.entries[1]])
        let after = try await BoardProvisioner.provision(
            using: board, projectName: "Yellowhammer", createIn: nil, routingTable: shrunk
        )
        #expect(!after.isChanged)
        #expect(try await board.labels(team: engineering.id).contains { $0.name == "o3" })
    }

    @Test("Without a Routing Table the Override groups are not touched")
    func noTableProvisionsNoOverrideGroups() async throws {
        let board = board()
        let report = try await provision(board)

        #expect(await board.creates == 13)
        #expect(report.entries.allSatisfy { subject in
            if case .labelGroup(let name, _) = subject.subject { return !name.hasPrefix("Override") }
            return true
        })
    }
}
