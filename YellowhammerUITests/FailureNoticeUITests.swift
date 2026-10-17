import Foundation
import XCTest

/// An authoring fault reads as a failure where the Operator looks: a failure mark on the Project's Sidebar row
/// beside an unchanged `idle`/`working` status, and an Act failure row in Health (morning-report/disclose-a-failure).
@MainActor
final class FailureNoticeUITests: XCTestCase {
    private var base: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        base = FileManager.default.temporaryDirectory.appending(component: "yh-failure-notice-\(UUID())")
        try HealthGroupUITests.writeConfiguration(in: base)
        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", base.path(), "-ApplePersistenceIgnoreState", "YES"
        ]
    }

    override func tearDown() async throws {
        if testRun?.hasSucceeded == false {
            add(XCTAttachment(string: app.debugDescription))
            add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        }
        app.terminate()
        try? FileManager.default.removeItem(at: base)
    }

    func testAuthoringFaultMarksTheSidebarRowAndShowsInHealth() throws {
        try seedFault()
        app.launch()

        let mark = element("sidebar-archive-failure")
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        XCTAssertEqual(mark.label, "Authoring “Schedule read” failed: over the description budget")
        XCTAssertEqual(element("sidebar-archive-status").label, "idle")
        XCTAssertFalse(element("sidebar-owner-failure").exists)
        XCTAssertFalse(element("sidebar-reader-failure").exists)

        element("sidebar-archive").click()
        let health = element("pulse-summary-health")
        if health.waitForExistence(timeout: 10) { health.click() }
        let row = app.descendants(matching: .any).matching(identifier: "health-flag")
            .matching(NSPredicate(format: "label CONTAINS %@", "is 12,153 of 10,000 description budget")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Shorten or split the Feature's spec first"))
    }

    /// Tonight lists the unrecovered fault under its header, and choosing it opens the Night's account with the
    /// playhead at the fault, not on the Night's first problem (morning-report/disclose-a-failure#where).
    func testATonightFailureLineOpensTheNightsAccountAtTheFault() throws {
        try seedFault()
        app.launch()

        let row = element("sidebar-archive")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let line = element("night-failure-notice")
        XCTAssertTrue(line.waitForExistence(timeout: 10), "Tonight shows no failure line")
        XCTAssertTrue(line.label.contains("Authoring “Schedule read” failed: over the description budget"))
        line.click()

        let clock = element("night-account-clock")
        XCTAssertTrue(clock.waitForExistence(timeout: 10), "the Night's account never opened")
        let value = clock.value as? String ?? ""
        XCTAssertEqual(value.isEmpty ? clock.label : value, Self.faultAt.formatted(.dateTime.hour().minute().second()))
    }

    /// A failed Health row ends its details with its Act's log path and Reveal in Finder, and shows no excerpt
    /// (morning-report/disclose-a-failure#log-path). Reveal is only looked for, never clicked.
    func testAnActFailureRowOffersItsActLogWithRevealInFinder() throws {
        try seedFault()
        app.launch()

        element("sidebar-archive").click()
        let health = element("pulse-summary-health")
        if health.waitForExistence(timeout: 10) { health.click() }
        let path = element("act-log-path")
        XCTAssertTrue(path.waitForExistence(timeout: 10), "the failed Health row shows no Act log path")
        XCTAssertTrue((path.value as? String ?? path.label).contains("archive.author.log"))
        XCTAssertTrue(element("act-log-reveal").exists)
    }

    /// The seeded fault's time, 2026-09-21T21:00:00Z.
    private static let faultAt = Date(timeIntervalSince1970: 1_790_024_400)

    /// Seeds one over-budget authoring fault into the archive Project's Night.
    private func seedFault() throws {
        let journals = base.appending(component: "journals")
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        let journal = journals.appending(component: "archive.db")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "archive", withExtension: "db"))
        try FileManager.default.copyItem(at: fixture, to: journal)
        // Fixture construction only: the running app never writes the Journal.
        let seed = Process()
        seed.executableURL = URL(filePath: "/usr/bin/sqlite3")
        seed.arguments = [journal.path(), """
            INSERT INTO event (night_id, act, run_id, type, occurred_at, payload)
            VALUES (1, 'author', 'fault-test', 'FeatureBreakdownRejected', '2026-09-21T21:00:00Z',
            '{"name":"Schedule read","reason":"the Routing Table has no Route left for the authoring Kind; \
            last failure: breakdown on codex/high returned invalid output: Work Card \\"Serve Proposals\\" \
            (backend) composes 12,153 UTF-16 code units, over the description budget of 10,000: Brief 9,000"}');
            """]
        try seed.run()
        seed.waitUntilExit()
        XCTAssertEqual(seed.terminationStatus, 0)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
