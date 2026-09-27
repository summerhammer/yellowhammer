import Foundation
import XCTest

/// The Journal tab of a Project window (P14.5) against a fixture configuration directory whose Project
/// has never run an Act. The UI test bundle links no Journal module, so it cannot build a Journal at the
/// engine's current schema; reading a populated Journal read-only — including while an Act writes it —
/// is covered by `CardAccountTests` in the `JournalTests` package. This suite covers what the app itself
/// is responsible for: the tab exists, and a missing Journal is stated as "not yet", not as an error,
/// without the app creating one.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class CardAccountUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-card-account-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let projectsDirectory = configurationDirectory.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)

        try Self.machineTOML.write(
            to: configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory),
            atomically: true, encoding: .utf8
        )
        try Self.demoProjectTOML.write(
            to: projectsDirectory.appending(component: "demo.toml", directoryHint: .notDirectory),
            atomically: true, encoding: .utf8
        )

        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
    }

    func testMissingJournalIsStatedAndNotCreated() throws {
        let journalTab = app.tabs["Journal"]
        XCTAssertTrue(journalTab.waitForExistence(timeout: 10))
        journalTab.click()

        let missing = app.staticTexts["card-account-journal-missing"]
        XCTAssertTrue(missing.waitForExistence(timeout: 5))

        let journalURL = configurationDirectory
            .appending(components: "journals", "demo.db", directoryHint: .notDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path(percentEncoded: false)))
    }

    private static let machineTOML = """
    [linear]
    credential = "keychain:linear"
    [github]
    credential = "keychain:github"

    [cli.claude]

    [[routing]]
    route = "claude/sonnet/medium"
    """

    private static let demoProjectTOML = """
    id = "demo"
    name = "Demo"
    linear_project = "DEMO"
    spec_source = "~/dev/demo-spec"

    [[repos]]
    name = "backend"
    path = "~/dev/demo-backend"
    role = "backend"
    check = "swift test"
    """
}
