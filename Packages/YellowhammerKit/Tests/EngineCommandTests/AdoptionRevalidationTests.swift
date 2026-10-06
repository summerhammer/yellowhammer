import Domain
@testable import Engine
import Foundation
@testable import Journal
@testable import Repositories
import Testing

// roadmap P11.5 (spec: feature-authoring/author-the-cycle-and-card-dag, second story): re-validating
// Adoption before the breakdown is drafted. A stale Transcription Block refuses the Adoption durably —
// a Divergence, sibling of Refusal — outside the authoring Outbox group; untestable-and-not-stale
// provenance defers a Card without penalty; clean provenance adopts.

// Fixtures — `context`, `seedCandidate`, `SeededCandidate`, `selection`, `threeCardBreakdown`,
// `transaction` — live in AdoptionRevalidationFixtures.swift, split out to keep this suite's type body
// under the length limit.
@Suite("Adoption re-validation (P11.5)")
struct AdoptionRevalidationTests {
    @Test("""
        A stale Transcription Block refuses the Adoption: not adopted, a Divergence recorded, \
        Waiting on You / divergence with the Operator assigned, and the Feature is authored with the \
        other Cards; the unanswered-Nights clock starts fresh at 0
        """)
    func staleBlockRefusesAdoption() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let seeded = try await seedCandidate(journal, boards: boards)
        let operatorID = BoardObjectID(rawValue: "operator-1")
        let operatorIdentity = OperatorIdentity(configured: operatorID)

        let transaction = try transaction(
            provenance: FakeProvenanceTester(verdicts: ["backend": .stale(changedPaths: ["contract.swift"])])
        )
        let (context, _) = try context(
            journal, nightStart: "2026-09-20", boards: boards, operatorIdentity: operatorIdentity
        )

        let outcome = try await selection(transaction).selectAndAuthor(context)

        #expect(outcome == .authored)

        // Not adopted: parent and Cycle unchanged.
        #expect(await boards.writing.issue(seeded.card)?.parent == seeded.oldFeature)
        let after = try journal.card(id: seeded.cardRowID)
        let (_, newCycleID) = try #require(try journal.inFlightFeature())
        #expect(after.cycleID != newCycleID)

        // A durable Divergence, one row, naming the stale repository and paths; failed_adoptions +1.
        let refusals = try journal.adoptionRefusals(cardID: seeded.cardRowID)
        #expect(refusals.count == 1)
        #expect(refusals[0].staleBlocks.map(\.repository) == ["backend"])
        #expect(refusals[0].staleBlocks.first?.changedPaths == ["contract.swift"])
        #expect(after.failedAdoptions == 1)

        // Waiting on You / divergence, Operator assigned, unanswered clock fresh.
        #expect(after.state == .waitingOnYou)
        #expect(after.waitingReason == .divergence)
        #expect(after.unansweredNights == 0)
        let issue = try #require(await boards.writing.issue(seeded.card))
        #expect(issue.assignee == operatorID)

        // The Managed Block carries the notice.
        let description = try #require(issue.description)
        #expect(description.contains("Adoption not completed"))
        #expect(description.contains("contract.swift"))
        #expect(description.contains("FEAT-1"))

        // The Feature is authored with the other Cards (not the adopted one).
        let live = await boards.writing.liveIssues
        let feature = try #require(live.first { $0.title == "FEAT-1" })
        #expect(live.filter { $0.parent == feature.id }.count == 2)
    }

    @Test("A second refusal on a later Night: two Divergence rows, one current notice naming the newer paths")
    func secondRefusalReplacesTheNotice() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let seeded = try await seedCandidate(journal, boards: boards)

        // Calls `AuthoringTransaction.author` directly rather than through `FeatureSelection`: once the
        // first refusal moves the Card to Waiting on You it is no longer a Blocked candidate, so a real
        // second refusal only happens after the unanswered-Nights clock re-Blocks it `undecided` — this
        // exercises the re-validation and the notice's replacement in isolation from that clock.
        func author(paths: [String], nightStart: String, previous: RunID?) async throws -> RunID {
            let transaction = try transaction(
                provenance: FakeProvenanceTester(verdicts: ["backend": .stale(changedPaths: paths)])
            )
            let (context, runID) = try self.context(
                journal, nightStart: nightStart, boards: boards, previous: previous
            )
            let outcome = try await transaction.author(
                try authoringSelection(adopting: ["CARD-OLD"]), reselectionDepth: 0, context: context
            )
            #expect(outcome == .authored)
            return runID
        }

        let run1 = try await author(paths: ["contract.swift"], nightStart: "2026-09-20", previous: nil)
        _ = try await author(paths: ["newer.swift"], nightStart: "2026-09-21", previous: run1)

        let refusals = try journal.adoptionRefusals(cardID: seeded.cardRowID)
        #expect(refusals.count == 2)
        #expect(refusals.map { $0.staleBlocks.first?.changedPaths } == [["contract.swift"], ["newer.swift"]])

        let after = try journal.card(id: seeded.cardRowID)
        #expect(after.failedAdoptions == 2)

        let issue = try #require(await boards.writing.issue(seeded.card))
        let description = try #require(issue.description)
        let notice = try #require(description.components(separatedBy: "### Adoption not completed").last)
        #expect(notice.contains("newer.swift"))
        #expect(!notice.contains("contract.swift"))
    }

    @Test("""
        A refused Card, sole content and no new Card: nothing authored, .noWorkAvailable, no Feature \
        Issue on the board
        """)
    func refusalLeavingNoWorkIsAQuietNight() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        _ = try await seedCandidate(journal, boards: boards)

        let transaction = AuthoringTransaction(
            drafting: ScriptedBreakdown(FeatureBreakdown(definitionOfDone: [authoringClause("done")], cards: [])),
            citations: FakeCitationResolver(), transcribing: FakeContractTranscriber(),
            provenance: FakeProvenanceTester(verdicts: ["backend": .stale(changedPaths: ["contract.swift"])])
        )
        let (context, _) = try context(journal, nightStart: "2026-09-20", boards: boards)

        let outcome = try await selection(transaction).selectAndAuthor(context)

        #expect(outcome == .noWorkAvailable)
        let live = await boards.writing.liveIssues
        #expect(!live.contains { $0.title == "FEAT-1" })
        #expect(try journal.inFlightFeature() == nil)
    }

    @Test("A refused Card is later auto-Blocked undecided once overdue_nights_max is exceeded")
    func refusedCardIsLaterAutoBlocked() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let seeded = try await seedCandidate(journal, boards: boards)

        let transaction = try transaction(
            provenance: FakeProvenanceTester(verdicts: ["backend": .stale(changedPaths: ["contract.swift"])])
        )
        let (context1, run1) = try context(journal, nightStart: "2026-09-20", boards: boards)
        _ = try await selection(transaction).selectAndAuthor(context1)
        #expect(try journal.card(id: seeded.cardRowID).state == .waitingOnYou)

        // Two later author Acts' clock (unansweredNightsMax = 1: Night 2 leaves it open at count 1,
        // Night 3 exceeds it): the Card sits Waiting on You in an archived (not landed) Cycle — still
        // counted (roadmap P11.5's widened `landedCycleIDsWithWaitingOnYouCards`).
        var previous = run1
        for nightStart in ["2026-09-21", "2026-09-22"] {
            let (context, runID) = try context(journal, nightStart: nightStart, boards: boards, previous: previous)
            let cycleIDs = try journal.landedCycleIDsWithWaitingOnYouCards()
            #expect(cycleIDs.contains(try journal.card(id: seeded.cardRowID).cycleID))
            try await UnansweredCardClock.run(cycleIDs: cycleIDs, unansweredNightsMax: 1, context: context)
            previous = runID
        }

        let after = try journal.card(id: seeded.cardRowID)
        #expect(after.state == .blocked)
        #expect(after.blockReason == BlockReason.undecided.rawValue)
    }

    @Test("Untestable provenance: the Card is not adopted, no Divergence, and its counters are unchanged")
    func untestableProvenanceDefersWithoutPenalty() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let seeded = try await seedCandidate(journal, boards: boards)
        let before = try journal.card(id: seeded.cardRowID)

        let transaction = try transaction(
            provenance: FakeProvenanceTester(verdicts: ["backend": .untestable(reason: "no working tree")])
        )
        let (context, _) = try context(journal, nightStart: "2026-09-20", boards: boards)

        let outcome = try await selection(transaction).selectAndAuthor(context)

        #expect(outcome == .authored)
        // Not adopted, but not refused either: still Blocked, in its original archived Cycle, untouched.
        let after = try journal.card(id: seeded.cardRowID)
        #expect(after.state == .blocked)
        #expect(after.cycleID == before.cycleID)
        #expect(after.failedAdoptions == 0)
        #expect(try journal.adoptionRefusals(cardID: seeded.cardRowID).isEmpty)

        let events = try journal.events(ofType: .adoptionUntestable)
        #expect(events.contains { event in
            if case .adoptionUntestable(let cardID, _, _, _) = event.event { return cardID == seeded.cardRowID }
            return false
        })

        // Still a candidate for a later selection.
        let candidates = try journal.blockedCardsLeftByClosedFeatures()
        #expect(candidates.contains { $0.issueID == "CARD-OLD" })
    }

    @Test("A real moved path (git): ProvenanceDiffTester finds the recorded path stale and the Adoption is refused")
    func realGitMovedPathRefusesAdoption() async throws {
        let repo = AdoptionGitFixture()
        await repo.initRepo()
        let recordedCommit = try await repo.commit(
            filename: "contract.swift", content: "protocol Contract {}", message: "v1"
        )
        let mainlineCommit = try await repo.commit(
            filename: "contract.swift", content: "protocol Contract { func a() }", message: "v2"
        )

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let seeded = try await seedCandidate(journal, boards: boards, mainlineCommit: recordedCommit)

        let repositories = ProjectRepositories(
            workingRepos: [
                Repo(name: "backend", path: repo.path, role: .backend),
                Repo(name: "mobile", path: "/repos/mobile", role: .mobile)
            ],
            specSource: SpecSource(path: "/repos/spec")
        )
        let mainlines = ResolvedMainlines(workingRepos: [
            "backend": ResolvedMainline(
                repository: "backend", defaultBranch: "main", ref: "refs/heads/main", commit: mainlineCommit
            ),
            "mobile": ResolvedMainline(
                repository: "mobile", defaultBranch: "main", ref: "refs/heads/main",
                commit: String(repeating: "b", count: 40)
            )
        ])

        let transaction = try transaction(provenance: ProvenanceDiffTester())
        let (context, _) = try context(
            journal, nightStart: "2026-09-20", boards: boards, repositories: repositories, mainlines: mainlines
        )

        let outcome = try await selection(transaction).selectAndAuthor(context)

        #expect(outcome == .authored)
        let after = try journal.card(id: seeded.cardRowID)
        #expect(after.state == .waitingOnYou)
        #expect(after.waitingReason == .divergence)
        let refusals = try journal.adoptionRefusals(cardID: seeded.cardRowID)
        #expect(refusals.first?.staleBlocks.first?.changedPaths == ["contract.swift"])
    }
}
