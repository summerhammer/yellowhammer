import Foundation
import XCTest

/// The main window rendering a populated Pulse from a seeded Journal (spec story
/// app/land-on-the-sidebar-and-pulse; issue #231).
///
/// This bundle links no Journal module and cannot build a Journal at test time, so the Journal is
/// `Fixtures/archive.db`, written and kept at the current schema by `PulseUITestJournalTests` in
/// `PulseTests`. Its seed is the contract the identifiers below rely on: Feature `ARC-10` with one Repo
/// Lane, `archive`, and pull request #42; `ARC-11` Blocked (hard failure) with one ended Attempt;
/// `ARC-12` Waiting on You; `ARC-13` with the one running Attempt, `2`; `ARC-14` Done; and a running
/// Night with Night Card `ARC-20`. Each issue's Journal id is a Linear issue UUID (``issueID(_:)``), and
/// its `ARC-n` identifier and Linear URL are recorded beside it.
///
/// The Journal is installed as the `archive` Project's, the first configured one, so the window shows
/// it at launch. The other two Projects keep no Journal.
@MainActor
final class PulseJournalUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var journal: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        configurationDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try OverviewWindowUITests.writeConfiguration(in: configurationDirectory)
        let journals = configurationDirectory.appending(component: "journals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        journal = journals.appending(component: "archive.db", directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: try Self.fixture(), to: journal)

        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        XCTAssertTrue(waitForHeading("Zed Archive", timeout: 10), "Pulse heading is \(text(of: "pulse-heading"))")
    }

    override func tearDown() async throws {
        if testRun?.hasSucceeded == false {
            add(XCTAttachment(string: app.debugDescription))
            add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        }
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory)
    }

    func testSidebarShowsTheRunningAttemptAndTheLaneBadge() {
        XCTAssertTrue(element("sidebar-archive-attempt-2").waitForExistence(timeout: 10))
        let lane = element("sidebar-archive-repo-archive-lane")
        XCTAssertTrue(lane.waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: lane), "blocked")
        // `working` comes from the Project's `launchd` Act jobs, never the Journal, and the app reads none
        // alive under a fixture configuration: a running Attempt in the Journal does not make it `working`.
        XCTAssertEqual(text(of: "sidebar-archive-status"), "idle")
        // The Projects with no Journal stay empty: nothing of archive's appears under them.
        XCTAssertFalse(element("sidebar-owner-repo-owner-lane").exists)
        XCTAssertFalse(element("sidebar-owner-attempt-2").exists)
    }

    func testNeedsYouListsEveryDecisionCardAndItsCounts() {
        XCTAssertTrue(element("needs-you-card-\(issueID(11))").waitForExistence(timeout: 10))
        XCTAssertTrue(element("needs-you-card-\(issueID(12))").exists)
        XCTAssertFalse(element("needs-you-card-\(issueID(13))").exists, "A running Card does not need the Operator")
        XCTAssertFalse(element("needs-you-card-\(issueID(14))").exists, "A Done Card does not need the Operator")
        XCTAssertFalse(element("needs-you-absence").exists)
        let counts = text(of: "needs-you-counts")
        XCTAssertTrue(counts.contains("1 Waiting on You"), "needs-you-counts is \u{201C}\(counts)\u{201D}")
        XCTAssertTrue(counts.contains("1 hard failure"), "needs-you-counts is \u{201C}\(counts)\u{201D}")
    }

    func testNowListsTheRunningAttempt() {
        XCTAssertTrue(element("now-attempt-2").waitForExistence(timeout: 10))
        XCTAssertFalse(element("now-absence").exists)
    }

    func testFeatureGroupShowsTheFeatureItsLaneAndItsPullRequest() {
        XCTAssertTrue(element("feature-title").waitForExistence(timeout: 10))
        XCTAssertTrue(element("feature-lane-archive").exists)
        XCTAssertTrue(element("feature-lane-archive-pull-request").exists)
        XCTAssertFalse(element("feature-absence").exists)
        XCTAssertFalse(element("feature-lanes-absence").exists)
    }

    func testNightGroupShowsTheRunningNight() {
        XCTAssertTrue(element("night-state").waitForExistence(timeout: 10))
        XCTAssertTrue(text(of: "night-state").contains("running"), "night-state is \(text(of: "night-state"))")
        XCTAssertTrue(element("night-dispositions").exists)
        XCTAssertFalse(element("night-absence").exists)
    }

    func testACardOpensItsDetailInTheInspector() {
        click("needs-you-card-\(issueID(11))")
        let state = element("card-detail-state")
        XCTAssertTrue(state.waitForExistence(timeout: 5), "the Card detail pane never opened")
        XCTAssertTrue(
            text(of: state).localizedCaseInsensitiveContains("blocked"), "card-detail-state is \(text(of: state))"
        )
        // The account is read from the Journal off the main actor, after the header.
        XCTAssertTrue(element("card-detail-attempt-1").waitForExistence(timeout: 10), "the Card account never loaded")
        XCTAssertFalse(element("card-detail-journal-missing").exists)
        XCTAssertFalse(element("card-detail-failure").exists)
    }

    func testTheFeatureOpensItsDetailInTheInspector() {
        click("feature-title")
        XCTAssertTrue(
            element("feature-detail-lane-archive").waitForExistence(timeout: 5), "the Feature detail pane never opened"
        )
        XCTAssertFalse(element("feature-detail-no-lanes").exists)
    }

    func testAnAttemptOpensItsDetailInTheInspector() {
        click("now-attempt-2")
        let card = element("attempt-detail-card")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "the Attempt detail pane never opened")
        XCTAssertTrue(
            text(of: card).contains("Backfill archived Cards"), "attempt-detail-card is \(text(of: card))"
        )
    }

    /// Every external way out the Journal recorded a link for is offered, named by the issue's Linear
    /// identifier. None is clicked: each opens its URL in the browser.
    func testRecordedWaysOutAreOffered() {
        let pullRequest = element("feature-lane-archive-pull-request")
        XCTAssertTrue(pullRequest.waitForExistence(timeout: 10))
        XCTAssertTrue(pullRequest.isEnabled)
        XCTAssertTrue(element("night-card-link").exists)

        click("needs-you-card-\(issueID(11))")
        let linear = element("card-detail-open-linear")
        XCTAssertTrue(linear.waitForExistence(timeout: 5), "the Card detail offers no way out to Linear")
        XCTAssertEqual(text(of: linear), "Open ARC-11 in Linear")
    }

    /// The app is read-only on every Journal: rendering the Pulse and reading a Card's account leave the
    /// file byte-for-byte as installed, and add no file beside it.
    func testRenderingThePopulatedPulseWritesNothingToTheJournal() throws {
        click("needs-you-card-\(issueID(11))")
        XCTAssertTrue(element("card-detail-attempt-1").waitForExistence(timeout: 10), "the Card account never loaded")
        app.terminate()

        XCTAssertEqual(try Data(contentsOf: journal), try Data(contentsOf: try Self.fixture()))
        let journals = try FileManager.default.contentsOfDirectory(atPath: journal.deletingLastPathComponent().path)
        XCTAssertEqual(journals, ["archive.db"])
    }

    /// The Journal's id of seeded issue `ARC-<number>`: Linear's issue UUID, as the fixture records it.
    private func issueID(_ number: Int) -> String {
        "00000000-0000-4000-8000-0000000000\(number)"
    }

    private static func fixture() throws -> URL {
        try XCTUnwrap(
            Bundle(for: PulseJournalUITests.self).url(forResource: "archive", withExtension: "db"),
            "Fixtures/archive.db is not a resource of the UI test bundle"
        )
    }

    private func click(_ identifier: String) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(identifier) is missing")
        // Another app's window can hold focus under a busy runner; XCUITest clicks only a frontmost app.
        app.activate()
        target.click()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(of identifier: String) -> String {
        let target = element(identifier)
        return target.exists ? text(of: target) : ""
    }

    private func text(of element: XCUIElement) -> String {
        let value = element.value as? String ?? ""
        return value.isEmpty ? element.label : value
    }

    private func waitForHeading(_ heading: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if text(of: "pulse-heading") == heading { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return text(of: "pulse-heading") == heading
    }
}
