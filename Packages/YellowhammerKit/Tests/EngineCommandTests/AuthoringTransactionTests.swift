import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Testing

// roadmap P9.4 (spec: feature-authoring/author-the-cycle-and-card-dag, first story): the authoring
// transaction writes the Feature Issue, its Cards as sub-issues and the Journal's Feature, Cycle and Card
// rows atomically. These assert wiring, structure, rows and keys — never what a breakdown says.

@Suite("Authoring transaction (P9.4)")
struct AuthoringTransactionTests {
    @Test("Success: the Feature Issue and its Cards are on the board, nested, and the Journal rows agree")
    func successWritesBoardAndRows() async throws {
        let rig = try await AuthoringRig(sequence: FeatureSequence(precededBy: "A", followedBy: "B", seam: "S"))
        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authored)
        let live = await rig.boards.writing.liveIssues
        let feature = try #require(live.first { $0.title == "FEAT-1" })
        #expect(feature.labels == [try #require(rig.boards.ids["Feature"])])
        #expect(feature.parent == nil)
        // The sequence and its reasoning are recorded on the Feature card; the Managed Block is fenced.
        let featureDescription = try #require(feature.description)
        #expect(featureDescription.contains(ManagedBlockFence.start))
        #expect(featureDescription.contains(ManagedBlockFence.end))
        #expect(featureDescription.contains("Seam: S"))
        let cards = live.filter { $0.id != feature.id }
        #expect(cards.count == 3)
        for card in cards {
            #expect(card.parent == feature.id)
            #expect(card.labels == [try #require(rig.boards.ids["Card"])])
            #expect(ManagedBlockFence.parts(of: card.description).isSuccess)
        }

        #expect(try tableRowCount(rig.journal, table: "feature") == 1)
        #expect(try tableRowCount(rig.journal, table: "cycle") == 1)
        let (recorded, cycleID) = try #require(try rig.journal.inFlightFeature())
        #expect(recorded.issueID == feature.id.rawValue)
        let rows = try cardRows(rig.journal)
        #expect(rows.map(\.repository) == ["backend", "backend", "mobile"])
        #expect(rows.map(\.authoredOrder) == [1, 2, 1])
        #expect(rows.allSatisfy { $0.state == .todo && $0.cycleID == cycleID && $0.kind == "impl.boilerplate" })
        #expect(Set(rows.map(\.issueID)) == Set(cards.map(\.id.rawValue)))

        let types = try rig.journal.events().map(\.type)
        let accepted = try #require(types.firstIndex(of: .featureAuthoringAccepted))
        #expect(accepted < (try #require(types.firstIndex(of: .featureAuthored))))
        #expect(!types.contains(.featureAuthoringFailed))
        #expect(rig.drafting.callCount == 1)
    }

    @Test("finaliseAuthoring records the feature row's Feature Branch (yh-<project>-<feature>)")
    func recordsFeatureBranch() async throws {
        let rig = try await AuthoringRig()
        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authored)
        let (recorded, _) = try #require(try rig.journal.inFlightFeature())
        let expected = FeatureBranch(project: rig.fixture.projectID.rawValue, feature: "FEAT-1")
        #expect(recorded.branch == expected)
    }

    @Test("The plan is recorded with the group's keys, and the group carries no Linear milestone or cycle write")
    func planKeysAreDeterministic() async throws {
        let rig = try await AuthoringRig()
        _ = try await rig.run(rig.context())

        let event = try #require(try rig.journal.events(ofType: .featureAuthoringAccepted).first)
        guard case .featureAuthoringAccepted(let plan) = event.event else {
            Issue.record("expected featureAuthoringAccepted")
            return
        }
        #expect(plan.groupKey == "authoring:FEAT-1:0")
        #expect(plan.featureKey == "feature:FEAT-1:0:create")
        #expect(plan.cards.map(\.key) == [
            "card:FEAT-1:0:backend:1:create", "card:FEAT-1:0:backend:2:create", "card:FEAT-1:0:mobile:1:create"
        ])
        let operations = try rig.journal.outboxEntries(groupID: plan.groupKey).map(\.operation)
        #expect(Set(operations) == ["issueCreate"])
        #expect(operations.count == 4)
    }

    @Test("A forced mid-transaction failure leaves no board and no rows, and is recorded")
    func failureRollsBackEverything() async throws {
        let rig = try await AuthoringRig()
        await rig.boards.writing.script(.refuse(.refused("Linear reports the title is invalid")), for: "Backend two")

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authoringRolledBack)
        #expect(await rig.boards.writing.liveIssues.isEmpty)
        #expect(await rig.boards.writing.archivedIssues.count == 2)
        #expect(try tableRowCount(rig.journal, table: "feature") == 0)
        #expect(try tableRowCount(rig.journal, table: "cycle") == 0)
        #expect(try tableRowCount(rig.journal, table: "card") == 0)
        let failed = try #require(try rig.journal.events(ofType: .featureAuthoringFailed).first)
        guard case .featureAuthoringFailed(let name, let groupKey, let reason) = failed.event else {
            Issue.record("expected featureAuthoringFailed")
            return
        }
        #expect(name == "FEAT-1" && groupKey == "authoring:FEAT-1:0")
        #expect(reason.contains("title is invalid"))
        #expect(try rig.journal.events(ofType: .featureAuthored).isEmpty)
        #expect(try rig.journal.unfinishedAuthoringPlan() == nil)
    }

    @Test("The failure appears on the Night Card's authoring section")
    func failureIsOnTheNightCard() async throws {
        let rig = try await AuthoringRig()
        await rig.boards.writing.script(.refuse(.refused("Linear reports the title is invalid")), for: "Backend two")
        let board = ActBoard(
            reading: FakeReadingBoard([]), writing: rig.boards.writing, provisioning: rig.boards.provisioning
        )

        try await EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: featureSelectionNightStart, journal: rig.journal,
            trigger: .forced, runID: RunID(), board: board, repositories: selectionRepositories(),
            work: AuthorAct(predecessorGate: nil, authoring: rig.selection).work
        ).run()

        let nightCard = try #require(await rig.boards.writing.liveIssues.first { $0.title.hasPrefix("Night ") })
        let description = try #require(nightCard.description)
        #expect(description.contains("Authoring Feature `FEAT-1` failed"))
        #expect(description.contains("the author Act stood down without authoring"))
        #expect(!description.contains("halt"))
        #expect(await rig.boards.writing.liveIssues.map(\.title) == [nightCard.title])
    }

    @Test("A crash after the first create is resumed without selecting or breaking down again, no duplicates")
    func resumeAfterCrashDoesNotDuplicate() async throws {
        let rig = try await AuthoringRig()
        let first = try rig.context()
        await #expect(throws: SimulatedCrash.self) {
            _ = try await rig.run(crashing(first, boards: rig.boards, afterApplying: 1))
        }
        #expect(await rig.boards.writing.liveIssues.map(\.title) == ["FEAT-1"])
        #expect(try tableRowCount(rig.journal, table: "feature") == 0)
        #expect(try rig.journal.unfinishedAuthoringPlan() != nil)
        let selectorCalls = rig.selector.callCount
        let breakdownCalls = rig.drafting.callCount

        let outcome = try await rig.run(rig.context(previous: first))

        #expect(outcome == .authored)
        #expect(rig.selector.callCount == selectorCalls)
        #expect(rig.drafting.callCount == breakdownCalls)
        let live = await rig.boards.writing.liveIssues
        #expect(live.map(\.title).sorted() == ["Backend one", "Backend two", "FEAT-1", "Mobile one"])
        let feature = try #require(live.first { $0.title == "FEAT-1" })
        #expect(live.filter { $0.id != feature.id }.allSatisfy { $0.parent == feature.id })
        #expect(try tableRowCount(rig.journal, table: "feature") == 1)
        #expect(try tableRowCount(rig.journal, table: "cycle") == 1)
        #expect(try tableRowCount(rig.journal, table: "card") == 3)
        #expect(try rig.journal.events(ofType: .featureAuthoringAccepted).count == 1)
        #expect(try rig.journal.events(ofType: .featureAuthored).count == 1)
    }

    @Test("A rate-limited delivery is pending and writes no rows; the next Act completes it")
    func deferredThenResumed() async throws {
        let rig = try await AuthoringRig()
        // The first refusal lands on the Feature Issue's create, before anything is applied.
        await rig.boards.writing.refuseNext(.rateLimited(retryAfter: nil, budget: nil))
        let first = try rig.context()

        let outcome = try await rig.run(first)

        #expect(outcome == .authoringPending)
        #expect(try tableRowCount(rig.journal, table: "feature") == 0)
        #expect(try tableRowCount(rig.journal, table: "card") == 0)
        #expect(try rig.journal.events(ofType: .featureAuthoringFailed).isEmpty)

        let resumed = try await rig.run(rig.context(previous: first))

        #expect(resumed == .authored)
        #expect(rig.selector.callCount == 1)
        #expect(rig.drafting.callCount == 1)
        #expect(await rig.boards.writing.liveIssues.count == 4)
        #expect(try tableRowCount(rig.journal, table: "card") == 3)
    }

    @Test("A retry after a rollback uses the next attempt number in its keys and succeeds")
    func retryAfterFailure() async throws {
        let rig = try await AuthoringRig(
            drafting: ScriptedBreakdown(
                try authoringBreakdown(), try authoringBreakdown(backendTitles: ["Backend uno", "Backend dos"])
            )
        )
        await rig.boards.writing.script(.refuse(.refused("no")), for: "Backend two")
        let first = try rig.context()
        #expect(try await rig.run(first) == .authoringRolledBack)

        let second = try await rig.run(rig.context(previous: first))

        #expect(second == .authored)
        let accepted = try rig.journal.events(ofType: .featureAuthoringAccepted).compactMap { record -> String? in
            if case .featureAuthoringAccepted(let plan) = record.event { plan.groupKey } else { nil }
        }
        #expect(accepted == ["authoring:FEAT-1:0", "authoring:FEAT-1:1"])
        #expect(try tableRowCount(rig.journal, table: "feature") == 1)
        #expect(await rig.boards.writing.liveIssues.count == 4)
    }

    // Validation-rejected breakdowns and accepted-but-undelivered are covered in
    // AuthoringTransactionFaultTests.swift (roadmap P9.10).

    @Test("Authoring without an Outbox and a Board throws instead of silently skipping")
    func noBoardThrows() async throws {
        let rig = try await AuthoringRig()
        let bare = try makeSelectionContext(rig.journal, repositories: selectionRepositories()).context

        await #expect(throws: AuthoringTransactionError.noBoard) { _ = try await rig.run(bare) }
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { true } else { false }
    }
}
