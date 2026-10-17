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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
