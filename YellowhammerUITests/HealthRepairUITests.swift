import Foundation
import XCTest

/// The app only triggers the bundled CLI. Stub output proves the command's scope and the refreshed Health read.
@MainActor
final class HealthRepairUITests: XCTestCase {
    private var base: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        base = FileManager.default.temporaryDirectory.appending(component: "yh-health-repair-\(UUID())")
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

    func testRepairRunsDoctorForSelectedProjectAndRefreshesHealth() throws {
        let stub = base.appending(component: "yh.sh")
        try Self.stub.write(to: stub, atomically: true, encoding: .utf8)
        let findings = base.appending(component: "findings.json")
        let missing = """
            [{"check":"linear","subject":"provisioning","severity":"failure",
            "message":"authoring defect is missing","projects":["owner"]}]
            """.replacingOccurrences(of: "\n", with: "")
        try missing.write(to: findings, atomically: true, encoding: .utf8)
        app.launchArguments += ["-YellowhammerEngineStub", stub.path()]
        app.launchEnvironment["YH_REPAIR_BASE"] = base.path()
        app.launch()
        let owner = element("sidebar-owner")
        XCTAssertTrue(owner.waitForExistence(timeout: 10))
        owner.click()
        let repair = element("pulse-repair-board")
        XCTAssertTrue(repair.waitForExistence(timeout: 15))
        XCTAssertTrue(repair.isEnabled)
        repair.click()
        XCTAssertTrue(element("pulse-repair-board-progress").waitForExistence(timeout: 5))
        XCTAssertTrue(element("pulse-repair-board-result").waitForExistence(timeout: 15))
        XCTAssertTrue(element("health-absence").waitForExistence(timeout: 10), "repair did not refresh doctor findings")
        XCTAssertEqual(try String(contentsOf: base.appending(component: "arguments"), encoding: .utf8),
                       "doctor --fix --check linear --project owner\n")
        XCTAssertFalse(repair.exists)
    }

    func testBoardScopeFailureRepairIsDisabledForFixtureWithoutEngineStub() throws {
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
            VALUES (1, 'build', 'repair-test', 'ActIncomplete', '2026-09-21T21:00:00Z',
            '{"reason":"The Project''s board scope is unresolved, so this Act did no work. missing label"}');
            """]
        try seed.run()
        seed.waitUntilExit()
        XCTAssertEqual(seed.terminationStatus, 0)
        let before = try Data(contentsOf: journal)
        app.launch()
        let health = element("pulse-summary-health")
        if health.waitForExistence(timeout: 10) { health.click() }
        let repair = element("pulse-repair-board")
        XCTAssertTrue(repair.waitForExistence(timeout: 10))
        XCTAssertFalse(repair.isEnabled, "fixture configuration must never repair the real board")
        XCTAssertEqual(try Data(contentsOf: journal), before)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private static let stub = """
    #!/bin/sh
    if [ "$#" -eq 2 ] && [ "$1" = doctor ] && [ "$2" = --json ]; then
      cat "$YH_REPAIR_BASE/findings.json"
      exit 0
    fi
    if [ "$*" = 'doctor --fix --check linear --project owner' ]; then
      echo "$*" > "$YH_REPAIR_BASE/arguments"
      sleep 2
      echo '[]' > "$YH_REPAIR_BASE/findings.json"
      echo 'every workflow state and label is present'
      echo '0 failed, 0 warnings'
      exit 0
    fi
    exit 2
    """
}
