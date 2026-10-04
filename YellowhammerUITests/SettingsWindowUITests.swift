import Foundation
import XCTest

/// The Settings window (Cmd+,), driven through the running app against a fixture configuration
/// directory (roadmap P18.12). It reuses `OverviewWindowUITests`' fixture: three Projects and one
/// refused Project file.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class SettingsWindowUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        configurationDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try OverviewWindowUITests.writeConfiguration(in: configurationDirectory)
        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
    }

    override func tearDown() async throws {
        if testRun?.hasSucceeded == false {
            add(XCTAttachment(string: app.debugDescription))
            add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        }
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Waits for the main window's Sidebar, then opens Settings with Cmd+,.
    private func showSettings() {
        XCTAssertTrue(element("sidebar-archive").waitForExistence(timeout: 10))
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element("settings-general").waitForExistence(timeout: 5))
    }

    func testCommandCommaOpensTheSettingsWindow() {
        showSettings()
        for id in ["settings-general", "settings-boards", "settings-agent-clis", "settings-base-routing-table",
                   "settings-refused-files", "settings-project-archive", "settings-project-owner",
                   "settings-project-reader"] {
            XCTAssertTrue(element(id).waitForExistence(timeout: 5), "\(id) is missing")
        }
    }

    /// The Linear workspaces are in the Boards section's Linear section, not in General.
    func testBoardsHoldsTheLinearWorkspacesAndGeneralDoesNot() {
        showSettings()
        app.activate()
        element("settings-general").click()
        XCTAssertTrue(element("settings-general-pane").waitForExistence(timeout: 5))
        XCTAssertFalse(element("settings-linear-section").exists)
        XCTAssertFalse(element("settings-linear-row-acme").exists)
        element("settings-boards").click()
        XCTAssertTrue(element("settings-boards-pane").waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings-linear-section").exists)
        XCTAssertTrue(element("settings-linear-row-acme").waitForExistence(timeout: 5))
    }

    func testRefusedProjectAppearsInSettingsWithItsDiagnosticAndNotInEitherSidebar() {
        showSettings()
        app.activate()
        element("settings-refused-files").click()
        let file = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS 'broken.toml' OR label CONTAINS 'broken.toml'")
        ).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertFalse(element("settings-refused-none").exists)
        XCTAssertTrue(element("settings-refused-file-0").exists)
        // The diagnostic: at least one decode or validation error under the path.
        XCTAssertTrue(element("settings-refused-file-0-error-0").exists)
        XCTAssertFalse(element("settings-project-broken").exists)
        XCTAssertFalse(element("sidebar-broken").exists)
    }

    func testSettingsOpensWithTheMainWindowsProjectPreselected() {
        let reader = element("sidebar-reader")
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        app.activate()
        reader.click()
        app.typeKey(",", modifierFlags: .command)
        // Not the window's title: the main window's title is the Project's name too.
        XCTAssertTrue(
            element("settings-project-pane-reader").waitForExistence(timeout: 5), "Settings did not open on Reader"
        )
        XCTAssertTrue(element("Configuration").exists)
        XCTAssertTrue(element("Recalibrate").exists)
    }

    func testBackAndForwardMoveThroughVisitedSections() {
        showSettings()
        // Checked by the pane shown, not the window's title: the main window's title is the Project's name.
        XCTAssertTrue(element("settings-project-pane-archive").waitForExistence(timeout: 5))
        XCTAssertFalse(element("settings-forward").isEnabled)
        app.activate()
        element("settings-general").click()
        XCTAssertTrue(element("settings-general-pane").waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows["General"].exists, "The toolbar does not name the section")
        element("settings-back").click()
        XCTAssertTrue(element("settings-project-pane-archive").waitForExistence(timeout: 5))
        element("settings-forward").click()
        XCTAssertTrue(element("settings-general-pane").waitForExistence(timeout: 5))
    }

    /// The Configuration tab names the Project's Linear workspace and installation, read-only. `yh doctor`
    /// does not run against this fixture, so the workspace falls back to the local name (OQ117).
    func testConfigurationShowsTheProjectsLinearWorkspaceReadOnly() {
        showSettings()
        XCTAssertTrue(element("settings-project-pane-archive").waitForExistence(timeout: 5))
        for id in ["project-linear-workspace", "project-linear-installation"] {
            let text = element(id)
            XCTAssertTrue(text.waitForExistence(timeout: 5), "\(id) is missing")
            XCTAssertEqual(text.value as? String ?? text.label, "acme", id)
            XCTAssertNotEqual(text.elementType, .textField, "\(id) must be read-only")
        }
        XCTAssertTrue(element("project-linear-workspace-caption").exists)
        XCTAssertEqual(element("project-linear-project").elementType, .textField)
    }
}
