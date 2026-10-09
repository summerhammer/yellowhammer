import Foundation
import XCTest

/// The main window rendering a populated Pulse from a seeded Journal (spec story
/// app/land-on-the-sidebar-and-pulse; issue #231).
///
/// This bundle links no Journal module and cannot build a Journal at test time, so the Journal is
/// `Fixtures/archive.db`, written and kept at the current schema by `PulseUITestJournalTests` in
/// `PulseTests`. Its seed is the contract the identifiers below rely on: Feature `ARC-10` with one Repo
/// Lane, `archive`, and pull request #42; `ARC-11` Blocked (route failure) with one ended Attempt;
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
        if name.contains("testDeliverNowBuildsAndRefreshesHealthAfterCompletion") {
            let stubDirectory = configurationDirectory.appending(component: "stub", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
            let stub = stubDirectory.appending(component: "yh.sh", directoryHint: .notDirectory)
            try Self.deliveryStub.write(to: stub, atomically: true, encoding: .utf8)
            app.launchArguments += ["-YellowhammerEngineStub", stub.path(percentEncoded: false)]
            app.launchEnvironment["YH_DELIVERY_FINDINGS"] = stubDirectory.appending(component: "findings.json").path()
            app.launchEnvironment["YH_DELIVERY_ARGUMENTS"] = stubDirectory.appending(component: "arguments.txt").path()
        }
        app.launch()
        XCTAssertTrue(waitForHeading("Zed Archive", timeout: 10), "Pulse heading is \(text(of: "pulse-heading"))")
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

    func testSidebarShowsTheRunningAttemptAndTheLaneBadge() {
        XCTAssertTrue(element("sidebar-archive-attempt-2").waitForExistence(timeout: 10))
        let lane = element("sidebar-archive-repo-archive-lane")
        XCTAssertTrue(lane.waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: lane), "blocked")
        // The fixture has no held Act Lease and no Act job alive, so the Journal's open Attempt does not
        // make the Project `working`.
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
        XCTAssertTrue(counts.contains("1 route failure"), "needs-you-counts is \u{201C}\(counts)\u{201D}")
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
        openHealth()
        let deliver = element("pulse-deliver-now")
        XCTAssertTrue(deliver.waitForExistence(timeout: 10), "the Journal fixture should include a pending write")
        XCTAssertFalse(deliver.isEnabled, "an overridden config without a yh stub must not launch an Act")
    }

    func testDeliverNowBuildsAndRefreshesHealthAfterCompletion() throws {
        openHealth()
        let deliver = element("pulse-deliver-now")
        XCTAssertTrue(deliver.waitForExistence(timeout: 10), "the pending Board write row has no Deliver now action")
        XCTAssertTrue(deliver.isEnabled, "Deliver now is disabled despite the Engine test stub")
        XCTAssertTrue(deliver.isHittable, "Deliver now is outside the visible Health card")
        app.activate()
        deliver.click()

        let calls = configurationDirectory.appending(components: "stub", "calls.txt", directoryHint: .notDirectory)
        XCTAssertTrue(
            waitForFileContaining(calls, "build --project archive", timeout: 5), "yh did not start the build stub"
        )
        let arguments = configurationDirectory
            .appending(components: "stub", "arguments.txt", directoryHint: .notDirectory)
        XCTAssertTrue(waitForFile(arguments, timeout: 5), "yh build was not launched")
        let line = try? String(contentsOf: arguments, encoding: .utf8)
        XCTAssertEqual(line?.trimmingCharacters(in: .whitespacesAndNewlines), "build --project archive")
        XCTAssertTrue(waitForFileContaining(calls, "build completed", timeout: 5), "the build stub did not finish")

        let refreshedHealth = app.buttons
            .matching(NSPredicate(format: "label == %@", "Health, 2, flags"))
            .firstMatch
        XCTAssertTrue(refreshedHealth.waitForExistence(timeout: 10), "Pulse did not refresh after the build Act exited")
        let refreshedFlag = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'delivery refreshed'"))
            .firstMatch
        XCTAssertTrue(refreshedFlag.exists, "the refreshed Doctor finding was not rendered in Health")
        let events = (try? String(contentsOf: calls, encoding: .utf8))?.components(separatedBy: .newlines) ?? []
        let completionIndex = events.firstIndex { $0.contains("build completed") }
        let finalDoctorIndex = events.lastIndex { $0.contains("doctor --json") }
        XCTAssertNotNil(completionIndex)
        XCTAssertNotNil(finalDoctorIndex)
        XCTAssertGreaterThan(finalDoctorIndex ?? -1, completionIndex ?? .max, "Health reread preceded build completion")
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

    private static let deliveryStub = """
    #!/bin/sh
    echo "$(date +%s) $*" >> "$(dirname "$0")/calls.txt"
    if [ "$1" = doctor ] && [ "$2" = --json ]; then
      if [ -f "$YH_DELIVERY_FINDINGS" ]; then cat "$YH_DELIVERY_FINDINGS"; else echo '[]'; fi
      exit 0
    fi
    if [ "$1" = build ] && [ "$2" = --project ] && [ "$3" = archive ]; then
      echo "$*" > "$YH_DELIVERY_ARGUMENTS"
      sleep 2
      echo '[{"check":"probes","subject":"codex","severity":"failure",' \
        '"message":"delivery refreshed"}]' > "$YH_DELIVERY_FINDINGS"
      echo "$(date +%s) build completed" >> "$(dirname "$0")/calls.txt"
      exit 0
    fi
    exit 2
    """

    private func click(_ identifier: String) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(identifier) is missing")
        // Another app's window can hold focus under a busy runner; XCUITest clicks only a frontmost app.
        app.activate()
        target.click()
    }

    private func openHealth() {
        let health = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Health,'")).firstMatch
        XCTAssertTrue(health.waitForExistence(timeout: 5), "Health summary action is missing")
        health.click()
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func waitForFileContaining(_ url: URL, _ text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? String(contentsOf: url, encoding: .utf8), content.contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (try? String(contentsOf: url, encoding: .utf8))?.contains(text) == true
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
