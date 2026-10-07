import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Testing

// roadmap P9.10 (spec: feature-authoring/author-the-cycle-and-card-dag, "A rolled-back transaction is
// an authoring fault, not a halt"): a breakdown `FeatureBreakdownValidation` refuses is an authoring
// fault, not a throw — nothing is accepted into the Outbox, no board write is made, and the Act ends
// normally. Split out of AuthoringTransactionTests.swift to keep that suite under the file length limit.

@Suite("Authoring faults: a rejected breakdown, and accepted-but-undelivered (P9.10)")
struct AuthoringTransactionFaultTests {
    @Test("A Card naming a repository outside the selection is an authoring fault: no throw, nothing accepted")
    func validationRefusesForeignRepository() async throws {
        let kind = try authoringKind()
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(FeatureBreakdown(
            definitionOfDone: [authoringClause("x")],
            cards: [CardDraft(
                repository: "web", kind: kind, title: "Web", unitOfWork: "x", brief: "Approach.",
                definitionOfDone: [authoringClause("x")]
            )]
        )))

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authoringRolledBack)
        #expect(try tableRowCount(rig.journal, table: "outbox") == 0)
        #expect(try rig.journal.events(ofType: .featureAuthoringAccepted).isEmpty)
        #expect(await rig.boards.writing.liveIssues.isEmpty)
        #expect(try rig.journal.events(ofType: .featureAuthoringHalted).isEmpty)
        #expect(try rig.journal.events(ofType: .refusalOpened).isEmpty)
        let rejected = try #require(try rig.journal.events(ofType: .featureBreakdownRejected).first)
        guard case .featureBreakdownRejected(let name, let reason) = rejected.event else {
            Issue.record("expected featureBreakdownRejected")
            return
        }
        #expect(name == "FEAT-1")
        #expect(reason.contains("web"))
    }

    @Test("A breakdown with no Card, and no adoption, is an authoring fault: no throw, nothing accepted")
    func validationRequiresACard() async throws {
        let empty = FeatureBreakdown(definitionOfDone: [authoringClause("x")], cards: [])
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(empty))

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authoringRolledBack)
        #expect(try tableRowCount(rig.journal, table: "outbox") == 0)
        #expect(try rig.journal.events(ofType: .featureBreakdownRejected).count == 1)
    }

    @Test("A briefless Card is an authoring fault: no throw, no board write, the fault is on the Night Card")
    func validationRefusesAnEmptyBrief() async throws {
        let kind = try authoringKind()
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(FeatureBreakdown(
            definitionOfDone: [authoringClause("x")],
            cards: [CardDraft(
                repository: "backend", kind: kind, title: "Backend", unitOfWork: "x", brief: "   ",
                definitionOfDone: [authoringClause("x")]
            )]
        )))
        let board = ActBoard(
            reading: FakeReadingBoard([]), writing: rig.boards.writing, provisioning: rig.boards.provisioning
        )

        try await EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: featureSelectionNightStart, journal: rig.journal,
            trigger: .forced, runID: RunID(), board: board, repositories: selectionRepositories(),
            work: AuthorAct(predecessorGate: nil, authoring: rig.selection).work
        ).run()

        #expect(try tableRowCount(rig.journal, table: "feature") == 0)
        // No board write from authoring: the board holds only the Night Card this invocation opened.
        let live = await rig.boards.writing.liveIssues
        #expect(live.count == 1 && live.first?.title.hasPrefix("Night ") == true)
        let rejected = try #require(try rig.journal.events(ofType: .featureBreakdownRejected).first)
        guard case .featureBreakdownRejected(let name, let reason) = rejected.event else {
            Issue.record("expected featureBreakdownRejected")
            return
        }
        #expect(name == "FEAT-1")
        #expect(reason.contains("Architectural Brief"))

        // The board holds only the Night Card, and the Act ended normally (no throw): the invocation's
        // write-back ran and put the exception on the Night Card, naming no halt.
        let nightCard = try #require(await rig.boards.writing.liveIssues.first { $0.title.hasPrefix("Night ") })
        let description = try #require(nightCard.description)
        #expect(description.contains("Authoring Feature `FEAT-1` failed"))
        #expect(description.contains("the author Act stood down without authoring"))
        #expect(!description.contains("halt"))
        #expect(await rig.boards.writing.liveIssues.map(\.title) == [nightCard.title])
    }

    @Test(
        "Accepted-but-undelivered says the board is still being written, not a halt, and disappears once delivered"
    )
    func pendingIsOnTheNightCardUntilDelivered() async throws {
        // Driven directly through NightCardMaintenance and the Journal's events, rather than a full
        // authoring transaction: `Outbox.deliverPendingExclusively` stops the whole run at the first
        // rate-limited entry it meets in accepted order, so a scripted rate limit on the authoring
        // group's own create would also block the Night Card's own rewrite from ever reaching the
        // board this same run — a pre-existing Outbox ordering rule, not part of what P9.10 changes.
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let run = RunID()
        _ = try journal.claimActLease(act: .author, runID: run, mode: .rehearsal)
        let opened = try journal.openNight(nightStart: nightCardNightStart, mode: .rehearsal, act: .author, runID: run)
            .night
        let outbox = Outbox(journal: journal, board: boards.writing, runID: run, act: .author, nightID: opened.id)
        let maintenance = NightCardMaintenance(journal: journal, outbox: outbox, provisioning: boards.provisioning)
        _ = try await maintenance.open(night: opened)
        let night = try #require(try journal.night(id: opened.id))

        let plan = FeatureAuthoringAcceptedPayload(
            name: "FEAT-1", groupKey: "authoring:FEAT-1:0", featureKey: "feature:FEAT-1:0:create",
            nightID: night.id, cards: [], adoptions: []
        )
        try journal.append(.featureAuthoringAccepted(plan), act: .author, runID: run, nightID: night.id)

        try await maintenance.recordAuthoring(night: night)
        _ = try await outbox.deliverPending()

        let pendingIssue = try #require(await boards.writing.liveIssues.first { $0.title.hasPrefix("Night ") })
        let pendingDescription = try #require(pendingIssue.description)
        #expect(pendingDescription.contains("is not yet fully delivered"))
        #expect(pendingDescription.contains("the board is still being written"))
        #expect(!pendingDescription.contains("Authoring halted"))
        #expect(!pendingDescription.contains("A quiet Night, not a failure"))

        // The plan completes: `featureAuthored` for the same group key.
        let authored = FeatureAuthoredPayload(
            name: "FEAT-1", groupKey: "authoring:FEAT-1:0", featureIssueID: "issue-9", cycleID: 1, cardCount: 0,
            adoptedCount: 0
        )
        try journal.append(.featureAuthored(authored), act: .author, runID: run, nightID: night.id)

        try await maintenance.recordAuthoring(night: night)
        _ = try await outbox.deliverPending()

        let finalIssue = try #require(await boards.writing.liveIssues.first { $0.title.hasPrefix("Night ") })
        let finalDescription = try #require(finalIssue.description)
        #expect(!finalDescription.contains("is not yet fully delivered"))
        #expect(!finalDescription.contains("the board is still being written"))
    }
}
