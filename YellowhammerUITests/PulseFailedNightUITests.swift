import Foundation
import XCTest

/// A Night that shipped nothing reads as a failure on the Pulse (issue #728).
///
/// `Fixtures/failed-night.db` is written by `PulseFailedNightUITestJournalTests` in `PulseTests` and installed
/// as the `owner` Project's Journal. Its seed replays the yellowhammer Night of 2026-10-31: one closed real
/// Night, Feature `OWN-10` in flight with its one Card `OWN-406` back in Todo, two claude Attempts
/// rounds-exhausted on two different Routes (both excluded) with a red Check, four codex Attempts usage
/// limited, no pull request and no Cycle landed.
@MainActor
final class PulseFailedNightUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        configurationDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try OverviewWindowUITests.writeConfiguration(in: configurationDirectory)
        let journals = configurationDirectory.appending(component: "journals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(
            Bundle(for: PulseFailedNightUITests.self).url(forResource: "failed-night", withExtension: "db"),
            "Fixtures/failed-night.db is not a resource of the UI test bundle"
        )
        try FileManager.default.copyItem(
            at: fixture, to: journals.appending(component: "owner.db", directoryHint: .notDirectory)
        )
        app = .yellowhammer(configurationDirectory: configurationDirectory)
        app.launch()
    }

    override func tearDown() async throws {
        if testRun?.hasSucceeded == false {
            add(XCTAttachment(string: app.debugDescription))
            add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
            add(XCTAttachment(string: "UI fixture: \(configurationDirectory.path(percentEncoded: false))"))
        } else {
            try? FileManager.default.removeItem(at: configurationDirectory)
        }
        app.terminate()
    }

    /// The header, the verdict line, Health and the Sidebar mark all say the Night failed; none says it
    /// succeeded or that nothing is known.
    func testANightThatShippedNothingReadsAsAFailure() {
        // Only `owner` has a Journal, so only its row carries the mark.
        XCTAssertTrue(element("sidebar-owner-failure").waitForExistence(timeout: 10), "owner carries no failure mark")
        XCTAssertFalse(element("sidebar-archive-failure").exists, "a Project with no Journal carries a mark")
        click("sidebar-owner")
        XCTAssertTrue(waitForHeading("Owner", timeout: 10), "Pulse heading is \(text(of: "pulse-heading"))")

        let status = text(of: "pulse-status")
        XCTAssertTrue(status.contains("Night ended without shipping"), "pulse-status is \u{201C}\(status)\u{201D}")
        XCTAssertFalse(status.contains("Night done"), "pulse-status is \u{201C}\(status)\u{201D}")

        let verdict = text(of: "night-card-link")
        XCTAssertTrue(verdict.contains("Nothing shipped"), "night-card-link is \u{201C}\(verdict)\u{201D}")
        XCTAssertTrue(verdict.contains("rounds-exhausted (OWN-406)"), "night-card-link is \u{201C}\(verdict)\u{201D}")
        XCTAssertTrue(verdict.contains("codex usage limit"), "night-card-link is \u{201C}\(verdict)\u{201D}")
        XCTAssertFalse(verdict.contains("verdict unknown"))

        XCTAssertTrue(element("feature-stalled").exists, "the stalled Feature is not said")

        // Each row is its own `health-flag` element, labelled with its kind first.
        let excluded = app.descendants(matching: .any).matching(identifier: "health-flag")
            .matching(NSPredicate(format: "label BEGINSWITH 'Route excluded:'"))
        XCTAssertTrue(excluded.firstMatch.waitForExistence(timeout: 10), "no Route excluded flag")
        XCTAssertEqual(excluded.count, 2, "one Route excluded flag per excluded Route")
        XCTAssertFalse(element("health-absence").exists, "Health says No health flags")
    }

    private func click(_ identifier: String) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(identifier) is missing")
        app.activate()
        target.click()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(of identifier: String) -> String {
        let target = element(identifier)
        guard target.exists else { return "" }
        let value = target.value as? String ?? ""
        return value.isEmpty ? target.label : value
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
