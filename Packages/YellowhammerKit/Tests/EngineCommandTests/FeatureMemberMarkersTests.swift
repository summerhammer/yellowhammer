import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// The banked-answer marker on a Feature member row (roadmap P11.3; spec: board-projection/maintain-
// the-managed-block, second story): derived at read time from the Journal, never written anywhere.

@Suite("Feature member markers (P11.3)")
struct FeatureMemberMarkersTests {
    @Test("A banked reply on a Waiting on You Card marks it bankedAnswer")
    func bankedReplyOnWaitingOnYouIsMarked() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let cardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .waitingOnYou
        )
        try bankAReply(journal, cardID: cardID)

        let markers = try FeatureMemberMarkers.derive(cycleID: cycleID, journal: journal)
        #expect(markers[cardID] == [.bankedAnswer])
    }

    @Test("A banked reply on a Blocked Card (carried forward after merge) is still marked bankedAnswer")
    func bankedReplyOnBlockedIsMarked() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let cardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .blocked
        )
        try bankAReply(journal, cardID: cardID)

        let markers = try FeatureMemberMarkers.derive(cycleID: cycleID, journal: journal)
        #expect(markers[cardID] == [.bankedAnswer])
    }

    @Test("A banked reply on a Done Card carries no marker")
    func bankedReplyOnDoneCardIsUnmarked() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let cardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done
        )
        try bankAReply(journal, cardID: cardID)

        let markers = try FeatureMemberMarkers.derive(cycleID: cycleID, journal: journal)
        #expect(markers[cardID] == nil)
    }

    @Test("A Cancelled Card is marked cancelled")
    func cancelledCardIsMarked() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let cardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .cancelled
        )

        let markers = try FeatureMemberMarkers.derive(cycleID: cycleID, journal: journal)
        #expect(markers[cardID] == [.cancelled])
    }

    @Test("A Card with no banked replies carries no marker, and the Card's own state is unchanged")
    func noBankedRepliesIsAbsent() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let cardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .waitingOnYou
        )

        let markers = try FeatureMemberMarkers.derive(cycleID: cycleID, journal: journal)
        #expect(markers[cardID] == nil)
        #expect(try journal.card(id: cardID).state == .waitingOnYou, "deriving markers writes nothing")
    }

    /// Records and banks one answer reply against `cardID`, on a fresh Night and Attempt, holding the
    /// Act Lease only for this call.
    private func bankAReply(_ journal: JournalStore, cardID: Int64) throws {
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: outboxEpoch)
        else { throw JournalError.actLeaseLost(runID: runID, holder: nil) }
        let nightID = try journal.openNight(
            nightStart: NightStart(rawValue: "2026-09-23")!, mode: .rehearsal, act: .build, runID: runID,
            now: outboxEpoch
        ).night.id
        let draft = CardReplyDraft(
            cardID: cardID, issueID: "BACK-1", questionID: nil, commentID: "comment-\(cardID)",
            body: "the answer", authorName: "Max", disposition: .answer, commentedAt: outboxEpoch
        )
        let reply = try journal.recordCardReply(draft, nightID: nightID, act: .build, runID: runID, now: outboxEpoch)
        _ = try journal.bankCardReply(id: reply.id, stamps: [], nightID: nightID, runID: runID, now: outboxEpoch)
    }
}
