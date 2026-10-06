import Domain
import Engine
import Testing

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

private func cardTypeGroup(_ subject: ProvisioningEntry.Subject) -> Bool {
    if case .labelGroup("Card Type", _) = subject { return true }
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

private func blocked(_ subject: ProvisioningEntry.Subject) -> Bool {
    if case .workflowState(BoardProvisioner.blockedState, _) = subject { return true }
    return false
}

private func keptInFlight(_ subject: ProvisioningEntry.Subject) -> Bool {
    if case .workflowState(SettleValue.keptInFlight.rawValue, _) = subject { return true }
    return false
}

private func released(_ subject: ProvisioningEntry.Subject) -> Bool {
    if case .workflowState(SettleValue.released.rawValue, _) = subject { return true }
    return false
}

@Suite("Board provisioning")
struct BoardProvisionerTests {
    @Test("A bare team gets its four workflow states, both label groups and all thirteen labels, each reported")
    func firstRunCreatesTheDeclaredSet() async throws {
        let board = board()
        let report = try await provision(board)

        #expect(await board.creates == 19)
        #expect(report.changes.count == 19)
        #expect(outcome(of: report, waitingOnYou) == .created)
        #expect(outcome(of: report, blocked) == .created)
        #expect(outcome(of: report, keptInFlight) == .created)
        #expect(outcome(of: report, released) == .created)
        #expect(outcome(of: report, cardTypeGroup) == .created)
        #expect(outcome(of: report, blockReasonGroup) == .created)
        for name in ["Feature Card", "Work Card", "Night Card"] {
            #expect(outcome(of: report, label(name, in: "Card Type")) == .created)
        }
        let blockReasons = [
            "reviewer rejection", "check failure", "route failure", "host crash", "engine fault", "operator abort",
            "reply overdue", "decision overdue", "feature abandoned", "failure recurrence"
        ]
        for name in blockReasons {
            #expect(outcome(of: report, label(name, in: "Block Reason")) == .created)
        }
        // The ten Block Reason labels are provisioned in the ruled order (OQ127, OQ128).
        #expect(BoardProvisioner.blockReasonChildren == blockReasons)
    }

    @Test("Blocked is provisioned in category started, right after Waiting on You")
    func blockedProvisionedAsStarted() async throws {
        let board = board()
        let report = try await provision(board)

        #expect(outcome(of: report, blocked) == .created)
        let states = report.entries.compactMap { entry -> String? in
            if case .workflowState(let name, _) = entry.subject { return name }
            return nil
        }
        let waitingIndex = try #require(states.firstIndex(of: "Waiting on You"))
        let blockedIndex = try #require(states.firstIndex(of: BoardProvisioner.blockedState))
        #expect(blockedIndex == waitingIndex + 1)
        let created = try await board.workflowStates(team: engineering.id)
        #expect(created.first { $0.name == BoardProvisioner.blockedState }?.category == .started)
    }

    @Test("An existing Blocked of another category is a collision, never reused")
    func blockedOfAnotherCategoryCollides() async throws {
        let board = board()
        await board.seed(state: BoardProvisioner.blockedState, team: engineering.id, category: .unstarted)

        let report = try await provision(board)

        #expect(outcome(of: report, blocked) == .collision("team"))
        let states = try await board.workflowStates(team: engineering.id)
        #expect(states.filter { $0.name == BoardProvisioner.blockedState }.count == 1)
    }

    @Test("Re-running provisioning with Blocked already present reports no change")
    func blockedAlreadyPresentIsIdempotent() async throws {
        let board = board()
        _ = try await provision(board)
        let createsAfterFirstRun = await board.creates

        let second = try await provision(board)

        #expect(await board.creates == createsAfterFirstRun)
        #expect(outcome(of: second, blocked) == .present)
        #expect(!second.isChanged)
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

    @Test("On a team with default Feature label, setup provisions Card Type with all 3 children without collision")
    func workspaceFeatureDoesNotCollide() async throws {
        let board = board()
        await board.seed(workspaceLabel: "Feature")

        let first = try await provision(board)
        #expect(outcome(of: first, label("Feature Card", in: "Card Type")) == .created)
        #expect(outcome(of: first, label("Work Card", in: "Card Type")) == .created)
        #expect(outcome(of: first, label("Night Card", in: "Card Type")) == .created)
        #expect(first.collisions.isEmpty)

        let createsAfterFirstRun = await board.creates
        let second = try await provision(board)
        #expect(await board.creates == createsAfterFirstRun)
        #expect(!second.isChanged)
        #expect(outcome(of: second, label("Feature Card", in: "Card Type")) == .present)
    }

    @Test("A workspace label named Feature Card is a collision, not overwritten, and the rest of the group is created")
    func workspaceFeatureCardCollides() async throws {
        let board = board()
        await board.seed(workspaceLabel: "Feature Card")

        let first = try await provision(board)
        #expect(outcome(of: first, label("Feature Card", in: "Card Type")) == .collision("workspace"))
        #expect(outcome(of: first, label("Work Card", in: "Card Type")) == .created)
        #expect(outcome(of: first, label("Night Card", in: "Card Type")) == .created)
        #expect(first.collisions.count == 1)

        let createsAfterFirstRun = await board.creates
        let second = try await provision(board)
        #expect(await board.creates == createsAfterFirstRun)
        #expect(!second.isChanged)
        #expect(outcome(of: second, label("Feature Card", in: "Card Type")) == .collision("workspace"))
    }

    @Test("A label in another group with a child's name is a collision")
    func childNameInAnotherGroupCollides() async throws {
        let board = board()
        await board.seed(label: "Status", team: engineering.id, isGroup: true)
        let status = try await board.labels(team: engineering.id)[0].id
        await board.seed(label: "reply overdue", team: engineering.id, parent: status)

        let report = try await provision(board)

        #expect(outcome(of: report, label("reply overdue", in: "Block Reason")) == .collision("team"))
        #expect(outcome(of: report, label("decision overdue", in: "Block Reason")) == .created)
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
            // Waiting on You, Blocked, Kept in Flight, Released, Card Type and its three labels
            #expect(await board.creates == 8)
            // An ordinary name collision is never a create-by-hand item: renaming the colliding label
            // is the fix, not creating anything (P17.2 must not conflate this with a permission refusal).
            #expect(!report.hasUnfinishedSteps)
        }
    }

    @Test("An existing Waiting on You in a different case is present, not created again")
    func waitingOnYouMatchesCaseInsensitively() async throws {
        let board = board()
        await board.seed(state: "waiting on you", team: engineering.id, category: .started)

        let report = try await provision(board)

        #expect(outcome(of: report, waitingOnYou) == .present)
        #expect(await board.creates == 18)
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
        #expect(report.changes.count == 20)
        #expect(report.linearProject?.id == BoardObjectID(rawValue: "fake-1"))
    }

    @Test("A re-read that keeps failing after creation still uses the created scope for provisioning")
    func createdProjectIsUsedEvenWhenReReadKeepsFailing() async throws {
        let board = FakeProvisioningBoard(project: nil)
        await board.alwaysThrowScopeNotFound()

        let report = try await provision(board, createIn: engineering.id)

        #expect(report.linearProject?.id == BoardObjectID(rawValue: "fake-1"))
        #expect(outcome(of: report, waitingOnYou) == .created)
        #expect(await board.creates == 20)
    }

    @Test("Each team of the Linear project is provisioned on its own")
    func eachTeamIsProvisioned() async throws {
        let board = board(teams: [engineering, product])
        await board.seed(state: "Waiting on You", team: engineering.id, category: .started)

        let report = try await provision(board)

        let states = report.entries.compactMap { entry -> (String, ProvisioningEntry.Outcome)? in
            if case .workflowState(_, let team) = entry.subject { return (team.key, entry.outcome) }
            return nil
        }
        #expect(states.map(\.0) == ["ENG", "ENG", "ENG", "ENG", "PRD", "PRD", "PRD", "PRD"])
        #expect(states.map(\.1) == [.present, .created, .created, .created, .created, .created, .created, .created])
        #expect(await board.creates == 37)
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

        // 17 as before, plus three groups and 2 + 3 + 2 children.
        #expect(await board.creates == 29)
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

    // MARK: - Membership first and refusals (P17.2, OQ80)

    @Test("A team the app is not a member of gets no create attempt; another team is still provisioned")
    func notAMemberTeamIsSkippedEntirely() async throws {
        let board = board(teams: [engineering, product])
        await board.excludeMembership(of: engineering.id)

        let report = try await provision(board)

        #expect(outcome(of: report) { if case .team(engineering) = $0 { true } else { false } } == .notAMember("ENG"))
        // Nothing at all was attempted in ENG: no workflow-state or label entries for it.
        #expect(!report.entries.contains { subject in
            if case .workflowState(_, let team) = subject.subject, team == engineering { return true }
            return false
        })
        // PRD, unaffected, still gets its full declared set.
        let prdStates = report.entries.filter { entry in
            if case .workflowState(_, let team) = entry.subject { return team == product }
            return false
        }
        #expect(prdStates.count == 4)
        #expect(prdStates.allSatisfy { $0.outcome == .created })
        // No create call reached the board for ENG at all: only PRD's 4 states + 2 groups + 10 labels.
        #expect(await board.creates == 19)
        #expect(report.hasUnfinishedSteps)
        #expect(report.createByHandGuideline?.contains("team ENG") == true)
    }

    @Test("A permission refusal on a create while the app is a member is reported, and the rest still runs")
    func permissionRefusalWhileMemberStillRunsTheRest() async throws {
        let board = board()
        await board.script(.refuse(.forbidden("You are not allowed to create workflow states for this team")),
                            for: BoardProvisioner.blockedState)

        let report = try await provision(board)

        #expect(outcome(of: report, blocked) == .permissionRefused(
            "You are not allowed to create workflow states for this team"
        ))
        // Every other declared item in the team still got created.
        #expect(outcome(of: report, waitingOnYou) == .created)
        #expect(outcome(of: report, keptInFlight) == .created)
        #expect(outcome(of: report, released) == .created)
        #expect(outcome(of: report, cardTypeGroup) == .created)
        #expect(report.hasUnfinishedSteps)
        #expect(report.createByHandGuideline?.contains("Blocked") == true)
        // The guideline lists only the missing item, not everything already created.
        #expect(report.createByHandGuideline?.contains("Waiting on You") == false)
    }

    @Test("A permission refusal creating a label group refuses its children too, without attempting them")
    func groupCreationRefusalRefusesChildrenWithoutAttempt() async throws {
        let board = board()
        await board.script(.refuse(.forbidden("not allowed")), for: BoardProvisioner.cardTypeGroup)

        let report = try await provision(board)

        #expect(outcome(of: report, cardTypeGroup) == .permissionRefused("not allowed"))
        for name in ["Feature Card", "Work Card", "Night Card"] {
            guard case .permissionRefused? = outcome(of: report, label(name, in: "Card Type")) else {
                Issue.record("expected permissionRefused for \(name)")
                continue
            }
        }
        // The next group is unaffected: Block Reason still runs to completion.
        #expect(outcome(of: report, blockReasonGroup) == .created)
        // Only the refused group and its three children are unfinished.
        #expect(report.unfinished.count == 4)
        // 4 states + the refused Card Type attempt + Block Reason's group and 10 children.
        #expect(await board.creates == 16)
    }

    @Test("A fully provisioned member team reports no changes, unaffected by the membership check")
    func fullyProvisionedMemberTeamIsIdempotentWithMembershipCheck() async throws {
        let board = board()
        _ = try await provision(board)

        let second = try await provision(board)

        #expect(!second.isChanged)
        #expect(!second.hasUnfinishedSteps)
    }

    @Test("Without a Routing Table the Override groups are not touched")
    func noTableProvisionsNoOverrideGroups() async throws {
        let board = board()
        let report = try await provision(board)

        #expect(await board.creates == 19)
        #expect(report.entries.allSatisfy { subject in
            if case .labelGroup(let name, _) = subject.subject { return !name.hasPrefix("Override") }
            return true
        })
    }
}
