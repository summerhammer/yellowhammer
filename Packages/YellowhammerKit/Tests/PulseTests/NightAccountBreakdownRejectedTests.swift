import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// A rejected Feature breakdown is a problem in the Night's account, worded with its reason (#533): the
// sibling `featureAuthoringFailed` already was, and the row used to fall back to the bare event name.

@Test("A rejected breakdown reads as a problem naming the Feature, with the reason as its detail")
func rejectedBreakdownIsAWordedProblem() {
    let reason = "no Route left: Work Card composes 12,153 UTF-16 code units, over the description budget of 10,000"
    let record = JournalEventRecord(
        id: 329, event: .featureBreakdownRejected(name: "Serve pending Proposals", reason: reason),
        act: .author, runID: nil, nightID: 1, occurredAt: Date(timeIntervalSince1970: 0)
    )

    let entry = NightAccount.Entry(record: record, cardNames: [:])

    #expect(entry.isProblem)
    #expect(entry.headline == "Authoring the Feature “Serve pending Proposals” failed: breakdown rejected")
    #expect(entry.detail == reason)
}
