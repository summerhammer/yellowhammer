import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
@testable import Journal
import Repositories
import Testing

// roadmap P10.8 (spec: landing/announce-a-partial-landing, morning-report/triage-the-morning): once
// the predecessor-ancestry gate first observes every touched repository merged (k = N), the Feature is
// closed by merge — unverified. A Card still Waiting on You is auto-Blocked `unanswered` ("merging
// costs the Card nothing"); surviving Blocked Cards are detached, awaiting Adoption; the Cycle is
// archived `closed_by = merge`; the Feature Issue is archived and never moved to Done. Never asserts
// model-authored content.

@Suite("Close a Feature by merge (P10.8)")
struct FeatureMergeClosureTests {
    @Test("k = 0: nothing merged writes nothing")
    func noRepositoriesMergedWritesNothing() async throws {
        let world = try await makeMergeWorld(mergedRepositories: [])
        let repositories = mergeWorldRepositories(world)
        let context = try world.makeContext(repositories: repositories)

        let outcome = try await PredecessorAncestryGate(closure: FeatureMergeClosure()).check(context)

        // An in-flight Feature is observed, never gated on: the outcome is always `.landed` regardless
        // of merge status — only the closure (or its absence) tells k = 0 apart from k = N.
        #expect(outcome == .landed)
        #expect(try world.journal.inFlightFeature() != nil)
        #expect(try mergeNightTriagedAt(world.journal, nightID: world.landingNightID) == nil)
        #expect(try mergeNightTriagedAt(world.journal, nightID: context.night.id) == nil)
        let events = try world.journal.events().map(\.type)
        #expect(!events.contains(.featureClosedByMerge))
        #expect(!events.contains(.cycleArchived))
        #expect(await world.boards.writing.createCommentCalls == 0)
        #expect(await world.boards.writing.archiveCalls == 0)
        let waiting = try world.journal.card(id: world.waitingCardID)
        #expect(waiting.state == .waitingOnYou)
    }

    @Test("k < N: one of two repositories merged writes only the landing, no receipt")
    func partiallyMergedWritesOnlyTheLanding() async throws {
        let world = try await makeMergeWorld(mergedRepositories: ["backend"])
        let repositories = mergeWorldRepositories(world)
        let context = try world.makeContext(repositories: repositories)

        let outcome = try await PredecessorAncestryGate(closure: FeatureMergeClosure()).check(context)

        #expect(outcome == .landed)
        let landings = try world.journal.landings(featureID: world.featureID)
        #expect(landings.keys.sorted() == ["backend"])
        #expect(try world.journal.inFlightFeature() != nil)
        let events = try world.journal.events().map(\.type)
        #expect(!events.contains(.featureClosedByMerge))
        #expect(!events.contains(.cycleArchived))
        #expect(await world.boards.writing.createCommentCalls == 0)
        let waiting = try world.journal.card(id: world.waitingCardID)
        #expect(waiting.state == .waitingOnYou)
    }

    @Test("k = N closes by merge: auto-Blocks Waiting on You, detaches Blocked, archives the Feature Issue")
    // The scenario is the length: a full fixture, then every assertion the story names.
    // swiftlint:disable:next function_body_length
    func fullyMergedClosesByMerge() async throws {
        let world = try await makeMergeWorld(mergedRepositories: ["backend", "mobile"])
        let repositories = mergeWorldRepositories(world)
        let context = try world.makeContext(repositories: repositories)

        let outcome = try await PredecessorAncestryGate(closure: FeatureMergeClosure()).check(context)
        #expect(outcome == .landed)

        let row = try mergeFeatureRow(world.journal, featureID: world.featureID)
        #expect(row.state == "closed")
        #expect(row.closedBy == "merge")
        #expect(try world.journal.inFlightCycleID() == nil)

        // The Waiting on You Card was auto-Blocked `unanswered`, its counters untouched — on the board
        // too, under a Card Lease claimed for the one write and released after it.
        let waiting = try world.journal.card(id: world.waitingCardID)
        #expect(waiting.state == .blocked)
        #expect(waiting.blockReason == BlockReason.unanswered.rawValue)
        #expect(waiting.budgetEpoch == 2)
        #expect(waiting.boardStateVersion == waiting.stateVersion)
        #expect(try world.journal.currentCardLease(cardID: world.waitingCardID)?.runID != context.runID)
        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        let waitingOnBoard = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "MOB-1")))
        #expect(waitingOnBoard.workflowState == (try scope.id(for: .blocked)))

        // Cancelled, Done and the already-Blocked Card are untouched.
        #expect(try world.journal.card(id: world.cancelledCardID).state == .cancelled)
        #expect(try world.journal.card(id: world.doneCardID).state == .done)
        let alreadyBlocked = try world.journal.card(id: world.blockedCardID)
        #expect(alreadyBlocked.state == .blocked)
        #expect(alreadyBlocked.blockReason == BlockReason.blockedByReviewer.rawValue)

        // Both Blocked Cards are detached; the Done Card is not.
        let waitingIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "MOB-1")))
        #expect(waitingIssue.parent == nil)
        let blockedIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "BACK-2")))
        #expect(blockedIssue.parent == nil)
        let doneIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(doneIssue.parent == BoardObjectID(rawValue: "FEAT-1"))
        let cancelledIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "MOB-2")))
        #expect(cancelledIssue.parent == BoardObjectID(rawValue: "FEAT-1"))

        // The Feature Issue is archived, never moved to Done.
        let featureIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "FEAT-1")))
        #expect(featureIssue.archived)
        #expect(featureIssue.workflowState != (try scope.id(for: .done)))

        // Exactly one narrative comment, opening with the closed-by-merge bold line.
        #expect(await world.boards.writing.createCommentCalls == 1)
        let comments = await world.boards.writing.comments
        let comment = try #require(comments.first { $0.issue == BoardObjectID(rawValue: "FEAT-1") })
        #expect(comment.body.hasPrefix("**Closed by merge.**"))

        // The Night that landed the Cycle is triaged; the observing Night is not.
        #expect(try mergeNightTriagedAt(world.journal, nightID: world.landingNightID) != nil)
        #expect(try mergeNightTriagedAt(world.journal, nightID: context.night.id) == nil)

        let closedEvents = try world.journal.events(ofType: .featureClosedByMerge)
        #expect(closedEvents.count == 1)
        guard case .featureClosedByMerge(
            let cycleID, let featureIssueID, let repos, let carried, let accepted, let triagedNightID
        ) = closedEvents[0].event else {
            Issue.record("expected featureClosedByMerge")
            return
        }
        #expect(cycleID == world.cycleID)
        #expect(featureIssueID == "FEAT-1")
        #expect(repos == ["backend", "mobile"])
        #expect(carried == ["BACK-2", "MOB-1"])
        #expect(accepted == ["BACK-1"])
        #expect(triagedNightID == world.landingNightID)

        let archivedEvents = try world.journal.events(ofType: .cycleArchived)
        #expect(archivedEvents.count == 1)
        #expect(archivedEvents[0].event == .cycleArchived(
            cycleID: world.cycleID, featureIssueID: "FEAT-1", closedBy: .merge, detachedCards: 2
        ))

        // The Night Card authoring line renders.
        let line = NightCardMaintenance.authoringLine(for: closedEvents[0].event)
        #expect(line?.contains("closed by merge") == true)
    }

    @Test("The Cycle landing in the observing Night itself marks the observing Night triaged")
    func landingInTheObservingNightMarksIt() async throws {
        let world = try await makeMergeWorld(mergedRepositories: ["backend", "mobile"], landInObservingNight: true)
        let repositories = mergeWorldRepositories(world)
        let context = try world.makeContext(repositories: repositories)
        #expect(context.night.id == world.landingNightID)

        _ = try await PredecessorAncestryGate(closure: FeatureMergeClosure()).check(context)

        #expect(try mergeNightTriagedAt(world.journal, nightID: context.night.id) != nil)
    }

    @Test("A second gate pass after k = N writes nothing new")
    func secondPassWritesNothingNew() async throws {
        let world = try await makeMergeWorld(mergedRepositories: ["backend", "mobile"])
        let repositories = mergeWorldRepositories(world)
        let context1 = try world.makeContext(repositories: repositories)
        _ = try await PredecessorAncestryGate(closure: FeatureMergeClosure()).check(context1)

        try world.journal.releaseActLease(runID: context1.runID)
        let context2 = try world.makeContext(repositories: repositories)
        let outcome2 = try await PredecessorAncestryGate(closure: FeatureMergeClosure()).check(context2)

        #expect(outcome2 == .landed)
        #expect(try world.journal.events(ofType: .featureClosedByMerge).count == 1)
        #expect(try world.journal.events(ofType: .cycleArchived).count == 1)
        #expect(await world.boards.writing.createCommentCalls == 1)
        #expect(await world.boards.writing.archiveCalls == 1)
    }

    @Test("Calling the closure directly twice produces no duplicate writes")
    func directRetryIsIdempotent() async throws {
        let world = try await makeMergeWorld(mergedRepositories: ["backend", "mobile"])
        let repositories = mergeWorldRepositories(world)
        // Records the landings the closure itself reads, exactly what the gate would have done first.
        let context = try world.makeContext(repositories: repositories)
        try world.journal.recordLanding(featureID: world.featureID, repository: "backend", mainlineCommit: "b1")
        try world.journal.recordLanding(featureID: world.featureID, repository: "mobile", mainlineCommit: "m1")
        let (feature, _) = try #require(try world.journal.inFlightFeature())

        let closure = FeatureMergeClosure()
        let updatesBefore = await world.boards.writing.updateCalls
        try await closure.closeByMerge(feature: feature, context: context)
        try await closure.closeByMerge(feature: feature, context: context)

        #expect(try world.journal.events(ofType: .featureClosedByMerge).count == 1)
        #expect(try world.journal.events(ofType: .cycleArchived).count == 1)
        #expect(await world.boards.writing.createCommentCalls == 1)
        #expect(await world.boards.writing.archiveCalls == 1)
        // One auto-Block state write, and two Blocked Cards detached — each once.
        #expect(await world.boards.writing.updateCalls - updatesBefore == 3)
    }

    @Test("A Waiting on You Card held under another run's live Lease: the closure throws and closes nothing")
    func heldCardLeaseDefersTheClosure() async throws {
        let world = try await makeMergeWorld(mergedRepositories: ["backend", "mobile"])
        let context = try world.makeContext(repositories: mergeWorldRepositories(world))
        _ = try world.journal.claimCardLease(cardID: world.waitingCardID, runID: RunID())

        await #expect(throws: CycleArchiveFault.self) {
            _ = try await PredecessorAncestryGate(closure: FeatureMergeClosure()).check(context)
        }

        #expect(try world.journal.inFlightFeature() != nil)
        #expect(try world.journal.card(id: world.waitingCardID).state == .waitingOnYou)
        #expect(try world.journal.events(ofType: .featureClosedByMerge).isEmpty)
        #expect(try !world.journal.predecessorAncestryPreviouslyFullyMerged(featureIssueID: "FEAT-1"))
    }

    @Test("A Feature already closed by verification reaching k = N writes nothing")
    func alreadyClosedByVerificationWritesNothing() async throws {
        let world = try await makeMergeWorld(mergedRepositories: ["backend", "mobile"])
        let repositories = mergeWorldRepositories(world)
        let context = try world.makeContext(repositories: repositories)
        try world.journal.archiveCycle(
            cycleID: world.cycleID, featureID: world.featureID, closedBy: .verification, runID: context.runID
        )
        let (feature, _) = try #require(
            try world.journal.read { db in try Self.readFeature(db, id: world.featureID) }
        )

        try await FeatureMergeClosure().closeByMerge(feature: feature, context: context)

        #expect(try world.journal.events(ofType: .featureClosedByMerge).isEmpty)
        #expect(await world.boards.writing.createCommentCalls == 0)
    }

    @Test("A released Feature writes nothing")
    func releasedFeatureWritesNothing() async throws {
        let world = try await makeMergeWorld(mergedRepositories: ["backend", "mobile"])
        let repositories = mergeWorldRepositories(world)
        let context = try world.makeContext(repositories: repositories)
        try world.journal.markFeatureReleased(featureID: world.featureID)
        let (feature, _) = try #require(
            try world.journal.read { db in try Self.readFeature(db, id: world.featureID) }
        )

        try await FeatureMergeClosure().closeByMerge(feature: feature, context: context)

        #expect(try world.journal.events(ofType: .featureClosedByMerge).isEmpty)
        #expect(await world.boards.writing.createCommentCalls == 0)
    }

    // Reads a Feature by id regardless of in-flight status, for the two tests above whose Feature is
    // no longer "in flight" by the time the closure is called (verification-closed or released).
    private static func readFeature(_ db: Database, id: Int64) throws -> (feature: FeatureRecord, cycleID: Int64)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM feature WHERE id = ?", arguments: [id]) else {
            return nil
        }
        let feature = try JournalStore.featureRecord(from: row)
        let cycleID = try Int64.fetchOne(db, sql: "SELECT id FROM cycle WHERE feature_id = ?", arguments: [id])!
        return (feature, cycleID)
    }
}

// MARK: - AuthorAct end-to-end

@Suite("Author Act proceeds to authoring once the merge closure runs (P10.8)")
struct AuthorActFeatureMergeClosureTests {
    @Test("An in-flight, landed Feature reaching k = N is closed and the same Act authors afresh")
    func authorActClosesAndAuthorsAfresh() async throws {
        let world = try await makeMergeWorld(mergedRepositories: ["backend", "mobile"])
        let repositories = mergeWorldRepositories(world)
        let board = ActBoard(
            reading: FakeReadingBoard([]), writing: world.boards.writing, provisioning: world.boards.provisioning
        )
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: mergeClosureObservingNightStart, journal: world.journal,
            trigger: .scheduled, runID: RunID(), board: board, repositories: repositories,
            work: AuthorAct(
                predecessorGate: PredecessorAncestryGate(closure: FeatureMergeClosure()), authoring: authoring
            ).work
        )
        try await invocation.run()

        #expect(authoring.wasCalled)
        let events = try world.journal.events().map(\.type)
        #expect(!events.contains(.authoringSkippedFeatureInFlight))
        #expect(events.contains(.featureClosedByMerge))
        let row = try mergeFeatureRow(world.journal, featureID: world.featureID)
        #expect(row.closedBy == "merge")
    }
}
