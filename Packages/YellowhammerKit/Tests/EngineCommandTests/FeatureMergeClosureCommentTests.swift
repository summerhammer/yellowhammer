import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// roadmap P10.8: the merge-closure comment body — fixed copy over fixed inputs, never model content.

@Suite("The merge-closure comment body (P10.8)")
struct FeatureMergeClosureCommentTests {
    @Test("Fixed copy over fixed inputs")
    func fixedCopyOverFixedInputs() {
        let comment = FeatureMergeClosureComment(
            landings: ["backend": "abc123", "mobile": "def456"],
            carriedForward: [
                FeatureMergeClosureComment.CarriedForwardCard(issueID: "MOB-1", blockReason: .replyOverdue),
                FeatureMergeClosureComment.CarriedForwardCard(issueID: "BACK-2", blockReason: .reviewerRejection)
            ],
            acceptedCards: ["BACK-1"],
            unmetClauses: [],
            triagedNightStart: mergeClosureLandingNightStart,
            observingNightStart: mergeClosureObservingNightStart
        )

        let body = comment.body()

        #expect(body.hasPrefix("**Closed by merge.** All 2 of this Feature's Feature Branches"))
        #expect(body.contains("It is not Done."))
        #expect(body.contains("## Merged"))
        #expect(body.contains("- backend: mainline abc123 contains the Feature Branch"))
        #expect(body.contains("- mobile: mainline def456 contains the Feature Branch"))
        #expect(!body.contains("## Still unmet"))
        #expect(body.contains("## Carried forward"))
        #expect(body.contains(
            "- BACK-2 — Blocked (reviewer rejection), awaiting Adoption by a later Feature; its counters "
                + "and round history are intact."
        ))
        #expect(body.contains("## Accepted"))
        #expect(body.contains("1 green Cards recorded as accepted: BACK-1"))
        #expect(body.contains("Night \(mergeClosureLandingNightStart) is recorded as triaged."))
        #expect(body.contains("Observed on Night \(mergeClosureObservingNightStart) from mainline ancestry"))
    }

    @Test("No carried-forward Cards and no accepted Cards render explicitly")
    func emptyCarriedForwardAndAccepted() {
        let comment = FeatureMergeClosureComment(
            landings: ["backend": "abc123"], carriedForward: [], acceptedCards: [], unmetClauses: [],
            triagedNightStart: mergeClosureLandingNightStart, observingNightStart: mergeClosureObservingNightStart
        )

        let body = comment.body()

        #expect(body.contains("- none"))
        #expect(body.contains("No green Cards to accept."))
    }
}
