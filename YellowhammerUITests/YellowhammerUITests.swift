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

    func testHealthOpensTheSettingsWindow() {
        let health = app.descendants(matching: .any)["pulse-health-settings"]
        XCTAssertTrue(health.waitForExistence(timeout: 10))
        health.click()
        let stub = app.descendants(matching: .any)["settings-stub"]
        XCTAssertTrue(stub.waitForExistence(timeout: 5))
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

    /// G-6 gives the app configuration and reading and gives Linear every decision (P14.8): the Project
    /// Window has Setup's configuration, the Journal account, Status and Recalibrate, and no Night Card,
    /// Feature detail, Card detail or triage gesture — settle included — on any of them.
    func testProjectWindowStillOpensFromItsMenuItem() {
        app.openProjectWindow()

        let tabs = app.tabs
        let labels = tabs.allElementsBoundByIndex.map(\.label)
        // Exactly these four: no Night Card, Feature detail or Card detail tab beside them.
        XCTAssertEqual(labels, ["Configuration", "Journal", "Status", "Recalibrate"])

        for label in labels {
            tabs[label].click()
            for gesture in ["Kept in Flight", "Released", "Settle", "Accept", "Adopt"] {
                XCTAssertFalse(
                    app.buttons[gesture].exists,
                    "The \(label) screen offers the triage gesture \u{201C}\(gesture)\u{201D}, which is Linear's"
                )
            }
        }
        XCTAssertFalse(app.popUpButtons["project-selector"].exists)
    }

    /// A link that launches the app: `XCUIApplication.open(_:)` relaunches it by URL. A link to the
    /// already-running app cannot be driven from here — LaunchServices does not route a URL to an
    /// instance XCUITest launched, and starts a second one instead.
    func testDeepLinkLaunchOpensTheNamedProject() throws {
        XCTAssertTrue(app.staticTexts["pulse-heading"].waitForExistence(timeout: 10))

        let landed = try relaunch(opening: "yellowhammer://project/reader") { headingText() == "Reader" }

        XCTAssertTrue(landed, "Pulse heading is \(headingText())")
    }

    func testDeepLinkToAnUnknownProjectStatesIt() throws {
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
            XCTAssertEqual((status.value as? String) ?? status.label, "idle")
            XCTAssertFalse(element("sidebar-\(id)-repo-\(id)-lane").exists)
        }
        let owner = element("sidebar-owner").frame.minY
        let ownerRepo = element("sidebar-owner-repo-owner").frame.minY
        let reader = element("sidebar-reader").frame.minY
        XCTAssertLessThan(owner, ownerRepo)
        XCTAssertLessThan(ownerRepo, reader)
    }

    func testSelectingARepoRowOpensItInTheInspector() {
        let row = element("sidebar-reader-repo-reader")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.activate()
        row.click()
        XCTAssertTrue(waitForHeading("Reader", timeout: 5), "Pulse heading is \(headingText())")
        let selection = element("inspector-selection")
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(5)
        while ((selection.value as? String) ?? selection.label) != "Repo reader", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual((selection.value as? String) ?? selection.label, "Repo reader")
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

    private static func writeConfiguration(in directory: URL) throws {
        let projects = directory.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try """
        [linear]
        credential = "keychain:linear"
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
            linear_project = "\(id.uppercased())"
            spec_source = "~/dev/spec"

            [[repos]]
            name = "\(id)"
            path = "~/dev/\(id)"
            role = "backend"
            check = "swift test"
            """.write(to: projects.appending(component: "\(id).toml"), atomically: true, encoding: .utf8)
        }
    }
}
