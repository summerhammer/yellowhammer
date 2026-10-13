import Foundation
import XCTest

/// The Night's account, read from the seeded Journal: its one Act run, a build Act run with no closing event,
/// recorded the Night opening and a failed Check for ARC-11, the Night's one problem.
extension PulseJournalUITests {
    /// The seeded Night's opening, 2026-09-21T20:00:00Z.
    private static let nightOpenedAt = Date(timeIntervalSince1970: 1_790_020_800)
    /// The seeded failed Check for ARC-11, the Night's one problem, 2026-09-21T20:04:00Z.
    private static let failedCheckAt = Date(timeIntervalSince1970: 1_790_021_040)

    /// The account takes the Pulse's place, headed by the Project's name, with its playhead on the problem;
    /// the Inspector keeps the Night's facts and its way out to the Night Card, and the back button brings
    /// the Pulse back.
    func testTheNightOpensItsAccountInPlaceOfThePulse() {
        click("night-account-link")
        let clock = element("night-account-clock")
        XCTAssertTrue(clock.waitForExistence(timeout: 10), "the Night account never loaded")
        XCTAssertEqual(text(of: "night-account-project"), "Zed Archive", "the Project's name does not head the account")
        XCTAssertEqual(text(of: "night-account-title"), "Night of 2026-09-21")
        XCTAssertEqual(text(of: clock), Self.clockTime(Self.failedCheckAt))
        XCTAssertEqual(text(of: "night-account-problem-count"), "1 problem")
        XCTAssertTrue(element("night-account-entry-3").exists, "the failed Check is not in the log")
        // The run recorded no closing event: the account never calls it running.
        let build = text(of: "night-account-act-build")
        XCTAssertTrue(build.contains("recorded no end"), "night-account-act-build is \u{201C}\(build)\u{201D}")
        XCTAssertFalse(element("pulse-night").exists, "the Pulse is still shown beside the Night's account")

        XCTAssertEqual(text(of: "night-detail-title"), "Night of 2026-09-21")
        XCTAssertEqual(text(of: "night-detail-problem-count"), "1")
        XCTAssertEqual(text(of: "night-detail-open-linear"), "Open ARC-20 in Linear")
        XCTAssertFalse(element("night-account-journal-missing").exists)
        XCTAssertFalse(element("night-account-failure").exists)

        click("night-account-close")
        XCTAssertTrue(element("pulse-night").waitForExistence(timeout: 5), "the Pulse never came back")
        XCTAssertFalse(element("night-account-clock").exists)
    }

    /// The transport moves the playhead inside the Night only: back five minutes from the problem stops at
    /// the Night's opening, and the next problem returns to it.
    func testTheNightAccountsTransportStepsWithinTheNight() {
        click("night-account-link")
        let clock = element("night-account-clock")
        XCTAssertTrue(clock.waitForExistence(timeout: 10), "the Night account never loaded")
        XCTAssertFalse(element("night-account-previous-problem").isEnabled, "no problem precedes the first")

        click("night-account-back-5-minutes")
        XCTAssertEqual(text(of: clock), Self.clockTime(Self.nightOpenedAt))
        XCTAssertTrue(element("night-account-next-problem").isEnabled)

        click("night-account-next-problem")
        XCTAssertEqual(text(of: clock), Self.clockTime(Self.failedCheckAt))
        XCTAssertFalse(element("night-account-next-problem").isEnabled, "no problem follows the last")
    }

    /// `date` as the Night account's clock shows it, in this Mac's locale and time zone, as the app does.
    private static func clockTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second())
    }
}
