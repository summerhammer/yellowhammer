import Foundation
import XCTest

/// The Unmerged Feature Stack in the Feature group (issue #626; proposed amendment, yellowhammer-spec#132), read
/// from the seeded Journal: `ARC-9` landed during the seeded Night and awaits merge in `archive`, with pull
/// request #41, and the in-flight `ARC-10` is stacked on it there.
extension PulseJournalUITests {
    /// The in-flight Feature keeps its header and lanes; the Feature awaiting merge is listed beside it, never as
    /// the Feature in flight, with its `k of N`, its landed-tonight mark and its pull request.
    func testTheFeatureGroupListsTheFeatureAwaitingMerge() {
        let awaiting = element("feature-awaiting-merge-\(issueID(9))")
        XCTAssertTrue(awaiting.waitForExistence(timeout: 10), "the Feature awaiting merge is not listed")
        let row = text(of: awaiting)
        XCTAssertTrue(row.contains("ARC-9"), "feature-awaiting-merge row is \u{201C}\(row)\u{201D}")
        XCTAssertTrue(row.contains("0 of 1 merged"), "feature-awaiting-merge row is \u{201C}\(row)\u{201D}")
        XCTAssertTrue(row.contains("landed tonight"), "feature-awaiting-merge row is \u{201C}\(row)\u{201D}")
        XCTAssertTrue(element("feature-awaiting-merge").exists, "the Awaiting merge heading is missing")
        XCTAssertTrue(element("feature-awaiting-merge-\(issueID(9))-archive-pull-request").exists)

        XCTAssertTrue(element("feature-title").exists, "the in-flight Feature is no longer shown")
        let stackedOn = text(of: "feature-stacked-on")
        XCTAssertTrue(stackedOn.contains("ARC-9"), "feature-stacked-on is \u{201C}\(stackedOn)\u{201D}")
        XCTAssertFalse(element("feature-absence").exists)
        XCTAssertFalse(element("feature-slot-free").exists, "a Feature is in flight, so the slot is not free")
        XCTAssertFalse(element("feature-stack-full").exists)
    }

    /// A Feature awaiting merge opens its own detail in the Inspector, which names its Repo and way out.
    func testAFeatureAwaitingMergeOpensItsDetailInTheInspector() {
        click("feature-awaiting-merge-\(issueID(9))")
        let detail = element("awaiting-merge-detail-repo-archive")
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "the awaiting-merge detail pane never opened")
        XCTAssertFalse(element("feature-detail-lane-archive").exists, "the in-flight Feature's detail opened instead")
    }
}
