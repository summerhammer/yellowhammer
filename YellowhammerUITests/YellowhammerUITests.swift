import Foundation
import XCTest

/// The main window (Sidebar, Pulse, Inspector) and the deep link, driven through the running app
/// against a fixture configuration directory (spec stories app/land-on-the-sidebar-and-pulse and
/// app/scope-windows-to-a-project).
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class OverviewWindowUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        configurationDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try Self.writeConfiguration(in: configurationDirectory)
        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
    }

    override func tearDown() async throws {
        // A failed wait says only that time ran out: keep what the app was showing when it did.
        if testRun?.hasSucceeded == false {
            add(XCTAttachment(string: app.debugDescription))
            add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        }
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory)
    }

    func testSidebarListsEveryConfiguredProjectInConfiguredOrder() {
        let rows = ["archive", "owner", "reader"].map { app.descendants(matching: .any)["sidebar-\($0)"] }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(row.identifier) is missing")
        }
        let tops = rows.map(\.frame.minY)
        XCTAssertLessThan(tops[0], tops[1])
        XCTAssertLessThan(tops[1], tops[2])
        XCTAssertTrue(waitForHeading("Zed Archive", timeout: 10))
    }

    func testSelectingASidebarRowScopesThePulse() {
        let row = app.descendants(matching: .any)["sidebar-reader"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // Another app's window can hold focus under a busy runner; XCUITest clicks only a frontmost app.
        app.activate()
        row.click()
        XCTAssertTrue(waitForHeading("Reader", timeout: 5), "Pulse heading is \(headingText())")
    }

    /// A window scoped to a Project that is then removed falls back to the first configured Project, not
    /// to the unknown-id notice a link gets. A window macOS restores after its Project was removed takes
    /// the same path; XCUITest cannot restore one (`-ApplePersistenceIgnoreState`).
    func testRemovingTheSelectedProjectUnscopesTheWindow() throws {
        let row = element("sidebar-reader")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.activate()
        row.click()
        XCTAssertTrue(waitForHeading("Reader", timeout: 5), "Pulse heading is \(headingText())")

        try FileManager.default.removeItem(
            at: configurationDirectory.appending(components: "projects", "reader.toml")
        )
        // The window reads its configuration again when the app becomes active.
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        app.activate()

        XCTAssertTrue(waitForHeading("Zed Archive", timeout: 10), "Pulse heading is \(headingText())")
        XCTAssertFalse(element("overview-unknown-id").exists)
        XCTAssertFalse(element("sidebar-reader").exists)
    }

    func testHealthOpensTheSettingsWindow() {
        let health = app.descendants(matching: .any)["pulse-health-settings"]
        XCTAssertTrue(health.waitForExistence(timeout: 10))
        health.click()
        // Settings opens preselected on the main window's Project, the first configured one.
        // The main window's title is the Project's name too, so the check is the Settings pane itself.
        let pane = app.descendants(matching: .any)["settings-project-pane-archive"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
    }

    /// `yh` reads the real configuration, not this fixture, so the app does not run `yh doctor`, and the
    /// Health group states that it was not read rather than claiming there are no flags.
    func testHealthStatesYhDoctorNotRead() {
        XCTAssertTrue(element("health-unread").waitForExistence(timeout: 10))
        XCTAssertFalse(element("health-absence").exists)
    }

    /// The fixture Journals hold no Feature, so the Feature group states its absence rather than a
    /// blank, and never invents a title, state or roll-up state.
    func testFeatureGroupStatesNoFeatureInFlight() {
        XCTAssertTrue(element("feature-absence").waitForExistence(timeout: 10))
    }

    /// The fixture Journals hold no Night, so the Tonight / last Night group states its absence rather
    /// than a blank.
    func testNightGroupStatesNoNightYet() {
        XCTAssertTrue(element("night-absence").waitForExistence(timeout: 10))
    }

    /// The app is read-only on every Journal: showing a Project that has no Journal yet never creates
    /// one. `PulseJournalUITests` checks that rendering a populated Journal leaves it unchanged.
    func testShowingProjectsCreatesNoJournal() {
        for id in ["archive", "owner", "reader"] {
            let row = element("sidebar-\(id)")
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(id) row is missing")
            app.activate()
            row.click()
        }
        XCTAssertTrue(waitForHeading("Reader", timeout: 5), "Pulse heading is \(headingText())")
        XCTAssertTrue(element("needs-you-absence").waitForExistence(timeout: 5))

        let journals = configurationDirectory.appending(component: "journals", directoryHint: .isDirectory)
        for id in ["archive", "owner", "reader"] {
            let journal = journals.appending(component: "\(id).db", directoryHint: .notDirectory)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: journal.path(percentEncoded: false)),
                "The app created \(id)'s Journal"
            )
        }
    }

    /// Every decision is Linear's: the main window carries no triage gesture. Any element type is
    /// checked, because the Pulse's ways out are link-styled buttons, which `app.buttons` does not find.
    func testMainWindowOffersNoTriageGesture() {
        XCTAssertTrue(app.staticTexts["pulse-heading"].waitForExistence(timeout: 10))
        // Control: the same query finds a link-styled button by its title, so the checks below can fail.
        XCTAssertTrue(app.descendants(matching: .any)["Open Settings"].exists)
        for gesture in ["Kept in Flight", "Released", "Settle", "Accept", "Adopt", "Re-ready", "Answer"] {
            XCTAssertFalse(
                app.descendants(matching: .any)[gesture].exists,
                "The main window offers the triage gesture \u{201C}\(gesture)\u{201D}, which is Linear's"
            )
        }
    }

    /// A link that launches the app: `XCUIApplication.open(_:)` relaunches it by URL. A link to the
    /// already-running app cannot be driven from here — LaunchServices does not route a URL to an
    /// instance XCUITest launched, and starts a second one instead.
    func testDeepLinkLaunchOpensTheNamedProject() throws {
        try XCTSkipIf(true, "#238: cold-launch GURL dropped by LaunchServices")
        XCTAssertTrue(app.staticTexts["pulse-heading"].waitForExistence(timeout: 10))

        let landed = try relaunch(opening: "yellowhammer://project/reader") { headingText() == "Reader" }

        XCTAssertTrue(landed, "Pulse heading is \(headingText())")
    }

    func testDeepLinkToAnUnknownProjectStatesIt() throws {
        try XCTSkipIf(true, "#238: cold-launch GURL dropped by LaunchServices")
        XCTAssertTrue(app.staticTexts["pulse-heading"].waitForExistence(timeout: 10))

        let landed = try relaunch(opening: "yellowhammer://project/nobody") { element("overview-unknown-id").exists }

        XCTAssertTrue(landed)
    }

    func testRefusedProjectIsAbsentFromTheSidebar() {
        XCTAssertTrue(element("sidebar-archive").waitForExistence(timeout: 10))
        XCTAssertTrue(element("sidebar-owner").exists)
        XCTAssertTrue(element("sidebar-reader").exists)
        XCTAssertFalse(element("sidebar-broken").exists)
        let broken = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Broken"))
        XCTAssertFalse(broken.firstMatch.exists)
    }

    func testDeepLinkToARefusedProjectStatesTheRefusal() throws {
        try XCTSkipIf(true, "#238: cold-launch GURL dropped by LaunchServices")
        XCTAssertTrue(app.staticTexts["pulse-heading"].waitForExistence(timeout: 10))

        let landed = try relaunch(opening: "yellowhammer://project/broken") { element("overview-refused-id").exists }

        XCTAssertTrue(landed)
        XCTAssertFalse(element("sidebar-broken").exists)
    }

    func testSidebarShowsEachProjectsReposAndStatus() {
        for id in ["archive", "owner", "reader"] {
            let repo = element("sidebar-\(id)-repo-\(id)")
            XCTAssertTrue(repo.waitForExistence(timeout: 10), "\(id) repo row is missing")
            let status = element("sidebar-\(id)-status")
            XCTAssertTrue(status.waitForExistence(timeout: 5), "\(id) status is missing")
            // The status is a dot, not text: its word is the accessibility label.
            XCTAssertEqual(status.label, "idle")
            XCTAssertFalse(element("sidebar-\(id)-repo-\(id)-lane").exists)
        }
        let owner = element("sidebar-owner").frame.minY
        let ownerRepo = element("sidebar-owner-repo-owner").frame.minY
        let reader = element("sidebar-reader").frame.minY
        XCTAssertLessThan(owner, ownerRepo)
        XCTAssertLessThan(ownerRepo, reader)
    }

    func testInspectorToggleHidesAndShowsTheInspector() {
        let toggle = element("toolbar-inspector-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let placeholder = app.staticTexts["Nothing Selected"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10))
        app.activate()
        toggle.click()
        XCTAssertTrue(waitForDisappearance(of: placeholder), "The Inspector is still shown")
        toggle.click()
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5), "The Inspector did not come back")
    }

    func testStopTheEngineIsOfferedOnlyWhileAnAttemptRuns() {
        let stop = element("toolbar-stop-engine")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertFalse(stop.isEnabled, "Stop the engine is offered for an idle Project")
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    func testSelectingARepoRowOpensItInTheInspector() {
        let row = element("sidebar-reader-repo-reader")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.activate()
        row.click()
        XCTAssertTrue(waitForHeading("Reader", timeout: 5), "Pulse heading is \(headingText())")
        // The Repo detail pane (P18.9) names the Repo it shows.
        let name = element("repo-detail-name")
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the Repo detail pane never opened")
        let deadline = Date().addingTimeInterval(5)
        while ((name.value as? String) ?? name.label) != "reader", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual((name.value as? String) ?? name.label, "reader")
    }

    /// Relaunches the app by `link` until `landed` holds, at most three times. A cold launch by URL
    /// sometimes never delivers the URL to the app (#238, which reproduces it with plain `open` against
    /// the installed Release build), so one launch is not enough to tell the app's handling of a link
    /// from that loss. Each launch waits for the new instance to come up in front first; the state in
    /// the message tells a launch that never finished from a link that never landed (#228).
    private func relaunch(opening link: String, until landed: () -> Bool) throws -> Bool {
        let url = try XCTUnwrap(URL(string: link))
        for _ in 1...3 {
            app.open(url)
            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 20),
                "The app is in state \(app.state.rawValue) after the relaunch by \(link)"
            )
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if landed() { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        return landed()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func headingText() -> String {
        let heading = app.staticTexts["pulse-heading"]
        guard heading.exists else { return "" }
        return (heading.value as? String) ?? heading.label
    }

    private func waitForHeading(_ text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if headingText() == text { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return headingText() == text
    }

    /// The fixture configuration: three Projects, one refused Project file, and no Journals. Shared
    /// with `SettingsWindowUITests`, and with `PulseJournalUITests`, which adds `archive`'s Journal.
    static func writeConfiguration(in directory: URL) throws {
        let projects = directory.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try """
        [board.linear.installations.acme]
        credential = "keychain:linear"
        workspace = "workspace-1"
        app_user = "app-user-1"
        [github]
        credential = "keychain:github"

        [cli.claude]

        [[routing]]
        route = "claude/sonnet"
        """.write(to: directory.appending(component: "config.toml"), atomically: true, encoding: .utf8)
        // A refused Project: the loader rejects the malformed line, so it never reaches the sidebar.
        try """
        id = "broken"
        name = "Broken"
        [[repos
        """.write(to: projects.appending(component: "broken.toml"), atomically: true, encoding: .utf8)
        // Id order differs from name order on purpose; the sidebar lists in configured (id) order.
        for (id, name) in [("archive", "Zed Archive"), ("owner", "Owner"), ("reader", "Reader")] {
            try """
            id = "\(id)"
            name = "\(name)"
            spec_source = "~/dev/spec"

            [board.linear]
            installation = "acme"
            project = "\(id.uppercased())"

            [[repos]]
            name = "\(id)"
            path = "~/dev/\(id)"
            role = "backend"
            check = "swift test"
            """.write(to: projects.appending(component: "\(id).toml"), atomically: true, encoding: .utf8)
        }
    }
}
