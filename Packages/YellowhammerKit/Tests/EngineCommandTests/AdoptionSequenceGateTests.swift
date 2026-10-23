import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// spec ruling OQ182 (2026-10-22), item 6 (with item 8.3): a later member of a same-repository sequence
// is adopted only when every earlier member of its old lane is Done with an Observed Merge of the old
// Feature in that repository, or is adopted ahead of it into the same successor Feature this same pass.
// `AdoptionRevalidation.absentEarlierSequenceMembers` is the pure gate behind that check — tested
// directly here, against a lightweight Journal, apart from the full authoring pipeline exercised in
// AdoptionRevalidationTests.swift.

@Suite("Same-repository sequence gate (OQ182 item 6)")
struct AdoptionSequenceGateTests {
    private func setState(_ journal: JournalStore, issueID: String, state: CardState) throws {
        try journal.write { db in
            try db.execute(sql: "UPDATE card SET state = ? WHERE issue_id = ?", arguments: [state.rawValue, issueID])
        }
    }

    @Test("An earlier member Done with an Observed Merge of the old Feature: not absent")
    func doneWithLandingPasses() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (featureID, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "FEAT-OLD")
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "A", repository: "backend", order: 1)
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "B", repository: "backend", order: 2)
        try setState(journal, issueID: "A", state: .done)
        try journal.recordLanding(
            featureID: featureID, repository: "backend", mainlineCommit: String(repeating: "a", count: 40),
            evidence: .ancestry
        )

        let candidate = try #require(try journal.card(issueID: "B"))
        let absent = try AdoptionRevalidation.absentEarlierSequenceMembers(
            of: candidate, oldCycleID: cycleID, journal: journal, kept: []
        )

        #expect(absent.isEmpty)
    }

    @Test("An earlier member Done but the old Feature has no Observed Merge in that repository: absent")
    func doneWithoutLandingFails() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "FEAT-OLD")
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "A", repository: "backend", order: 1)
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "B", repository: "backend", order: 2)
        try setState(journal, issueID: "A", state: .done)

        let candidate = try #require(try journal.card(issueID: "B"))
        let absent = try AdoptionRevalidation.absentEarlierSequenceMembers(
            of: candidate, oldCycleID: cycleID, journal: journal, kept: []
        )

        #expect(absent.map(\.title) == ["A"])
        #expect(absent.map(\.repository) == ["backend"])
    }

    @Test("An earlier member kept by this same pass, ahead of the candidate: not absent")
    func keptAheadPasses() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "FEAT-OLD")
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "A", repository: "backend", order: 1)
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "B", repository: "backend", order: 2)
        // A is still Blocked (not Done), but it is this same pass's own kept selection, ahead of B.

        let candidate = try #require(try journal.card(issueID: "B"))
        let absent = try AdoptionRevalidation.absentEarlierSequenceMembers(
            of: candidate, oldCycleID: cycleID, journal: journal, kept: ["A"]
        )

        #expect(absent.isEmpty)
    }

    @Test("A Shelved predecessor: absent")
    func shelvedPredecessorFails() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "FEAT-OLD")
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "A", repository: "backend", order: 1)
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "B", repository: "backend", order: 2)
        try setState(journal, issueID: "A", state: .shelved)

        let candidate = try #require(try journal.card(issueID: "B"))
        let absent = try AdoptionRevalidation.absentEarlierSequenceMembers(
            of: candidate, oldCycleID: cycleID, journal: journal, kept: []
        )

        #expect(absent.map(\.title) == ["A"])
    }

    @Test("An earlier member already adopted into another Feature: absent, never meets either condition")
    func departedMemberFails() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "FEAT-OLD")
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "B", repository: "backend", order: 2)
        // A left FEAT-OLD for FEAT-ELSEWHERE on an earlier Night, at its old order 1 — it is no longer a
        // row of this Cycle at all.
        let (_, elsewhereCycleID) = try insertFeatureSelectionAdoptionFixture(
            journal, closedFeatureIssueID: "FEAT-ELSEWHERE"
        )
        let aRowID = try insertFeatureSelectionAdoptionCard(
            journal, cycleID: elsewhereCycleID, issueID: "A", repository: "backend", order: 1
        )
        try journal.append(.cardAdopted(
            cardID: aRowID, issueID: "A", previousFeatureIssueID: "FEAT-OLD", newFeatureIssueID: "FEAT-ELSEWHERE",
            priorBlockReason: nil, coldStartNote: "cold", previousAuthoredOrder: 1
        ))

        let candidate = try #require(try journal.card(issueID: "B"))
        let absent = try AdoptionRevalidation.absentEarlierSequenceMembers(
            of: candidate, oldCycleID: cycleID, journal: journal, kept: []
        )

        #expect(absent.map(\.title) == ["A"])
    }

    @Test("A legacy CardAdopted event with no recorded order is treated as unprovably early: absent")
    func legacyDepartureEventWithNoOrderFails() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "FEAT-OLD")
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "B", repository: "backend", order: 1)
        let (_, elsewhereCycleID) = try insertFeatureSelectionAdoptionFixture(
            journal, closedFeatureIssueID: "FEAT-ELSEWHERE"
        )
        let aRowID = try insertFeatureSelectionAdoptionCard(
            journal, cycleID: elsewhereCycleID, issueID: "A", repository: "backend", order: 1
        )
        // A Journal written before this field existed: no previousAuthoredOrder recorded.
        try journal.append(.cardAdopted(
            cardID: aRowID, issueID: "A", previousFeatureIssueID: "FEAT-OLD", newFeatureIssueID: "FEAT-ELSEWHERE",
            priorBlockReason: nil, coldStartNote: "cold", previousAuthoredOrder: nil
        ))

        let candidate = try #require(try journal.card(issueID: "B"))
        let absent = try AdoptionRevalidation.absentEarlierSequenceMembers(
            of: candidate, oldCycleID: cycleID, journal: journal, kept: []
        )

        #expect(absent.map(\.title) == ["A"])
    }

    @Test("A first sequence member is never affected")
    func firstMemberUnaffected() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "FEAT-OLD")
        try insertFeatureSelectionAdoptionCard(journal, cycleID: cycleID, issueID: "A", repository: "backend", order: 1)

        let candidate = try #require(try journal.card(issueID: "A"))
        let absent = try AdoptionRevalidation.absentEarlierSequenceMembers(
            of: candidate, oldCycleID: cycleID, journal: journal, kept: []
        )

        #expect(absent.isEmpty)
    }

    @Test("""
        A Card from an adopted sequence of the old Feature with no earlier member of its own is never \
        affected by an unrelated, newly authored sibling ahead of it (OQ182 item 5 keeps the sequences apart)
        """)
    func adoptedSequenceFirstMemberUnaffected() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "FEAT-OLD")
        // A newly authored Card, order 1 — a different sequence from the adopted Card below.
        try insertFeatureSelectionAdoptionCard(
            journal, cycleID: cycleID, issueID: "NEW-1", repository: "backend", order: 1
        )
        // B was itself adopted into FEAT-OLD from an even earlier ancestor, at order 2 — the first (and
        // only) member of its own adopted sequence there.
        let bRowID = try insertFeatureSelectionAdoptionCard(
            journal, cycleID: cycleID, issueID: "B", repository: "backend", order: 2
        )
        try journal.append(.cardAdopted(
            cardID: bRowID, issueID: "B", previousFeatureIssueID: "FEAT-ANCESTOR", newFeatureIssueID: "FEAT-OLD",
            priorBlockReason: nil, coldStartNote: "cold", previousAuthoredOrder: 9
        ))

        let candidate = try #require(try journal.card(issueID: "B"))
        let absent = try AdoptionRevalidation.absentEarlierSequenceMembers(
            of: candidate, oldCycleID: cycleID, journal: journal, kept: []
        )

        #expect(absent.isEmpty)
    }
}
