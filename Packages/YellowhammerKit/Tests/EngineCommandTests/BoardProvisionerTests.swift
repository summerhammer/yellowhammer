import Domain
import Engine
import Testing

private let engineering = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering")
private let product = BoardTeam(id: BoardObjectID(rawValue: "team-2"), key: "PRD", name: "Product")

/// A board whose teams already hold the native states Yellowhammer selects by category: Linear gives every
/// team these, and setup never creates a substitute for one that is missing.
private func board(teams: [BoardTeam] = [engineering]) async -> FakeProvisioningBoard {
    let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: teams)
    let board = FakeProvisioningBoard(project: scope)
    for team in teams {
        await board.seed(state: "Todo", team: team.id, category: .unstarted)
        await board.seed(state: "In Progress", team: team.id, category: .started)
        await board.seed(state: "Done", team: team.id, category: .completed)
        await board.seed(state: "Canceled", team: team.id, category: .shelved)
    }
    return board
}

/// Provisions with the footprint store setup would hold, and records what the run resolved into it, as setup
/// does — so a second run sees the first run's ids.
private func provision(
    _ board: FakeProvisioningBoard, createIn team: BoardObjectID? = nil,
    store: InMemoryBoardFootprintStore = InMemoryBoardFootprintStore(), mapping: BoardMapping = .empty
) async throws -> ProvisioningReport {
    let report = try await BoardProvisioner.provision(
        using: board, projectName: "Yellowhammer", createIn: team,
        footprint: BoardFootprintInputs(mapping: mapping, store: store)
    )
    try store.recordFootprint(report.footprint)
    return report
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

private func anyBlockReasonLabel(_ subject: ProvisioningEntry.Subject) -> Bool {
    if case .label(_, "Block Reason", _) = subject { return true }
    return blockReasonGroup(subject)
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
    if case .workflowState("Kept in Flight", _) = subject { return true }
    return false
}

private func abandoned(_ subject: ProvisioningEntry.Subject) -> Bool {
    if case .workflowState("Abandoned", _) = subject { return true }
    return false
}

@Suite("Board provisioning")
struct BoardProvisionerTests {
    @Test("A bare team gets its two custom workflow states and the Card Type group with three labels, each reported")
    func firstRunCreatesTheDeclaredSet() async throws {
        let board = await board()
        let report = try await provision(board)

        #expect(await board.creates == 6)
        #expect(report.changes.count == 6)
        #expect(outcome(of: report, waitingOnYou) == .created)
        #expect(outcome(of: report, blocked) == .created)
        // The legacy settle pair is neither provisioned nor verified (P22.8), and the board never gains one.
        #expect(!report.entries.contains { keptInFlight($0.subject) || abandoned($0.subject) })
        let held = try await board.workflowStates(team: engineering.id).map(\.name)
        #expect(!held.contains("Kept in Flight") && !held.contains("Abandoned"))
        #expect(outcome(of: report, cardTypeGroup) == .created)
        for name in ["Feature Card", "Work Card", "Night Card"] {
            #expect(outcome(of: report, label(name, in: "Card Type")) == .created)
        }
        // Block Reason is Card content, not a label (Board Simplification Ruling 2026-10-20): the
        // group is neither provisioned nor reported.
        #expect(!report.entries.contains { anyBlockReasonLabel($0.subject) })
    }

    @Test("Blocked is provisioned in category started, right after Waiting on You")
    func blockedProvisionedAsStarted() async throws {
        let board = await board()
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
        let board = await board()
        await board.seed(state: BoardProvisioner.blockedState, team: engineering.id, category: .unstarted)

        let report = try await provision(board)

        #expect(outcome(of: report, blocked) == .collision("team"))
        let states = try await board.workflowStates(team: engineering.id)
        #expect(states.filter { $0.name == BoardProvisioner.blockedState }.count == 1)
    }

    @Test("Re-running provisioning with Blocked already present reports no change")
    func blockedAlreadyPresentIsIdempotent() async throws {
        let board = await board()
        let store = InMemoryBoardFootprintStore()
        _ = try await provision(board, store: store)
        let createsAfterFirstRun = await board.creates

        let second = try await provision(board, store: store)

        #expect(await board.creates == createsAfterFirstRun)
        #expect(outcome(of: second, blocked) == .present)
        #expect(!second.isChanged)
    }

    @Test("Provisioning twice changes nothing the second time")
    func secondRunChangesNothing() async throws {
        let board = await board()
        let store = InMemoryBoardFootprintStore()
        _ = try await provision(board, store: store)
        let createsAfterFirstRun = await board.creates

        let second = try await provision(board, store: store)

        #expect(await board.creates == createsAfterFirstRun)
        #expect(!second.isChanged)
        #expect(second.entries.allSatisfy { $0.outcome == .present })
    }

    @Test("On a team with default Feature label, setup provisions Card Type with all 3 children without collision")
    func workspaceFeatureDoesNotCollide() async throws {
        let board = await board()
        let store = InMemoryBoardFootprintStore()
        await board.seed(workspaceLabel: "Feature")

        let first = try await provision(board, store: store)
        #expect(outcome(of: first, label("Feature Card", in: "Card Type")) == .created)
        #expect(outcome(of: first, label("Work Card", in: "Card Type")) == .created)
        #expect(outcome(of: first, label("Night Card", in: "Card Type")) == .created)
        #expect(first.collisions.isEmpty)

        let createsAfterFirstRun = await board.creates
        let second = try await provision(board, store: store)
        #expect(await board.creates == createsAfterFirstRun)
        #expect(!second.isChanged)
        #expect(outcome(of: second, label("Feature Card", in: "Card Type")) == .present)
    }

    @Test("A workspace label named Feature Card is a collision, not overwritten, and the rest of the group is created")
    func workspaceFeatureCardCollides() async throws {
        let board = await board()
        let store = InMemoryBoardFootprintStore()
        await board.seed(workspaceLabel: "Feature Card")

        let first = try await provision(board, store: store)
        #expect(outcome(of: first, label("Feature Card", in: "Card Type")) == .collision("workspace"))
        #expect(outcome(of: first, label("Work Card", in: "Card Type")) == .created)
        #expect(outcome(of: first, label("Night Card", in: "Card Type")) == .created)
        #expect(first.collisions.count == 1)

        let createsAfterFirstRun = await board.creates
        let second = try await provision(board, store: store)
        #expect(await board.creates == createsAfterFirstRun)
        #expect(!second.isChanged)
        #expect(outcome(of: second, label("Feature Card", in: "Card Type")) == .collision("workspace"))
    }

    @Test("A label in another group with a child's name is a collision")
    func childNameInAnotherGroupCollides() async throws {
        let board = await board()
        await board.seed(label: "Status", team: engineering.id, isGroup: true)
        let status = try await board.labels(team: engineering.id)[0].id
        await board.seed(label: "Work Card", team: engineering.id, parent: status)

        let report = try await provision(board)

        #expect(outcome(of: report, label("Work Card", in: "Card Type")) == .collision("team"))
        #expect(outcome(of: report, label("Night Card", in: "Card Type")) == .created)
    }

    @Test("A label that is not a group, grouped or not, holding a group's name blocks the group and its labels")
    func groupNameCollisionBlocksChildren() async throws {
        for parent: BoardObjectID? in [nil, BoardObjectID(rawValue: "some-other-group")] {
            let board = await board()
            await board.seed(label: "Card Type", team: engineering.id, parent: parent)

            let report = try await provision(board)

            #expect(outcome(of: report, cardTypeGroup) == .collision("team"))
            let blocked = report.entries.filter {
                if case .blocked = $0.outcome, case .label(_, "Card Type", _) = $0.subject { return true }
                return false
            }
            #expect(blocked.count == CardType.allCases.count)
            // Only Waiting on You and Blocked: the group's name is held, so none of its labels is attempted.
            #expect(await board.creates == 2)
            // A collision is an unfinished step (#361), but never a create-by-hand item: renaming the
            // colliding label is the fix (P17.2 must not conflate this with a permission refusal), and
            // the group's one line covers the labels it blocks.
            #expect(report.hasUnfinishedSteps)
            #expect(report.createByHandGuideline == nil)
            let guideline = try #require(report.collisionGuideline)
            #expect(guideline.split(separator: "\n").count == 2)
            #expect(guideline.contains("label group `Card Type`"))
        }
    }

    @Test("A same-name started state with no persisted id, mapping or provenance is a collision, never created again")
    func sameNameStateWithoutProvenanceIsACollision() async throws {
        let board = await board()
        let existing = await board.seed(state: "waiting on you", team: engineering.id, category: .started)
        let before = await board.creates

        let report = try await provision(board)

        #expect(outcome(of: report, waitingOnYou) == .collision("team"))
        let entry = try #require(report.entries.first { waitingOnYou($0.subject) })
        // The diagnostic prints the exact Board Mapping lines the Operator can add to adopt it.
        let hint = try #require(entry.mappingHint)
        #expect(hint.contains("[board.linear.mapping]"))
        #expect(hint.contains("waiting_on_you = \"\(existing)\""))
        #expect(report.hasUnfinishedSteps)
        // Blocked is still created; no second same-name state exists.
        #expect(await board.creates == before + 5)
        let held = try await board.workflowStates(team: engineering.id)
        #expect(held.filter { $0.name.lowercased() == "waiting on you" }.count == 1)
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
        #expect(report.changes.count == 7)
        #expect(report.linearProject?.id == BoardObjectID(rawValue: "fake-1"))
    }

    @Test("A re-read that keeps failing after creation still uses the created scope for provisioning")
    func createdProjectIsUsedEvenWhenReReadKeepsFailing() async throws {
        let board = FakeProvisioningBoard(project: nil)
        await board.alwaysThrowScopeNotFound()

        let report = try await provision(board, createIn: engineering.id)

        #expect(report.linearProject?.id == BoardObjectID(rawValue: "fake-1"))
        #expect(outcome(of: report, waitingOnYou) == .created)
        #expect(await board.creates == 7)
    }

    @Test("Each team of the Linear project is provisioned on its own")
    func eachTeamIsProvisioned() async throws {
        let board = await board(teams: [engineering, product])

        let report = try await provision(board)

        let states = report.entries.compactMap { entry -> (String, ProvisioningEntry.Outcome)? in
            if case .workflowState(_, let team) = entry.subject { return (team.key, entry.outcome) }
            return nil
        }
        #expect(states.map(\.0) == ["ENG", "ENG", "PRD", "PRD"])
        #expect(states.map(\.1) == [.created, .created, .created, .created])
        // Per team: two custom states, the Card Type group and its three labels.
        #expect(await board.creates == 12)
    }

    // MARK: - No Override label group (the Card override is a description field, P22.7)

    private static func overrideGroup(_ subject: ProvisioningEntry.Subject) -> Bool {
        if case .labelGroup("Override", _) = subject { true } else { false }
    }

    @Test("Provisioning creates no Override label group, and verifying does not require one")
    func noOverrideGroupIsProvisionedOrRequired() async throws {
        let board = await board()
        let report = try await provision(board)

        // Two workflow states, the Card Type group and its three children: nothing for Routes.
        #expect(await board.creates == 6)
        #expect(!report.entries.contains { Self.overrideGroup($0.subject) })
        #expect(!(try await board.labels(team: engineering.id)).contains { $0.name.hasPrefix("Override") })

        let verified = try await BoardProvisioner.verify(using: board, projectName: "Yellowhammer")
        #expect(!verified.isChanged)
        #expect(!verified.hasUnfinishedSteps)
        #expect(!verified.entries.contains { Self.overrideGroup($0.subject) })
    }

    @Test("A board that still carries a legacy Override group verifies clean and the group is left as it is")
    func legacyOverrideGroupIsLeftAlone() async throws {
        let board = await board()
        let store = InMemoryBoardFootprintStore()
        _ = try await provision(board, store: store)
        let group = try await board.createLabel(name: "Override", team: engineering.id, isGroup: true, parent: nil)
        _ = try await board.createLabel(
            name: "codex/o3/high", team: engineering.id, isGroup: false, parent: group.id
        )
        let createsBefore = await board.creates

        let report = try await provision(board, store: store)

        #expect(!report.isChanged)
        #expect(await board.creates == createsBefore)
        let names = try await board.labels(team: engineering.id).map(\.name)
        #expect(names.contains("Override") && names.contains("codex/o3/high"))
    }

    // MARK: - Membership first and refusals (P17.2, OQ80)

    @Test("A team the app is not a member of gets no create attempt; another team is still provisioned")
    func notAMemberTeamIsSkippedEntirely() async throws {
        let board = await board(teams: [engineering, product])
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
        #expect(prdStates.count == 2)
        #expect(prdStates.allSatisfy { $0.outcome == .created })
        // No create call reached the board for ENG at all: only PRD's 2 states, Card Type group and 3 labels.
        #expect(await board.creates == 6)
        #expect(report.hasUnfinishedSteps)
        #expect(report.createByHandGuideline?.contains("team ENG") == true)
    }

    @Test("A permission refusal on a create while the app is a member is reported, and the rest still runs")
    func permissionRefusalWhileMemberStillRunsTheRest() async throws {
        let board = await board()
        await board.script(.refuse(.forbidden("You are not allowed to create workflow states for this team")),
                            for: BoardProvisioner.blockedState)

        let report = try await provision(board)

        #expect(outcome(of: report, blocked) == .permissionRefused(
            "You are not allowed to create workflow states for this team"
        ))
        // Every other declared item in the team still got created.
        #expect(outcome(of: report, waitingOnYou) == .created)
        #expect(outcome(of: report, cardTypeGroup) == .created)
        #expect(report.hasUnfinishedSteps)
        #expect(report.createByHandGuideline?.contains("Blocked") == true)
        // The guideline lists only the missing item, not everything already created.
        #expect(report.createByHandGuideline?.contains("Waiting on You") == false)
    }

    @Test("A permission refusal creating a label group refuses its children too, without attempting them")
    func groupCreationRefusalRefusesChildrenWithoutAttempt() async throws {
        let board = await board()
        await board.script(.refuse(.forbidden("not allowed")), for: BoardProvisioner.cardTypeGroup)

        let report = try await provision(board)

        #expect(outcome(of: report, cardTypeGroup) == .permissionRefused("not allowed"))
        for name in ["Feature Card", "Work Card", "Night Card"] {
            guard case .permissionRefused? = outcome(of: report, label(name, in: "Card Type")) else {
                Issue.record("expected permissionRefused for \(name)")
                continue
            }
        }
        // Only the refused group and its three children are unfinished.
        #expect(report.unfinished.count == 4)
        // 2 states + the refused Card Type attempt.
        #expect(await board.creates == 3)
    }

    @Test("A fully provisioned member team reports no changes, unaffected by the membership check")
    func fullyProvisionedMemberTeamIsIdempotentWithMembershipCheck() async throws {
        let board = await board()
        let store = InMemoryBoardFootprintStore()
        _ = try await provision(board, store: store)

        let second = try await provision(board, store: store)

        #expect(!second.isChanged)
        #expect(!second.hasUnfinishedSteps)
    }
}
