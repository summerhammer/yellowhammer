import Foundation
import XCTest

/// The Settings window's Repo Roles pane driven against a stub `yh`, on the `AgentCLIUITests` pattern: the
/// pane lists the built-in Repo Roles, declares one by writing `repo_roles` into `config.toml`, refuses an
/// invalid name before writing, and removes a declared one. The app writes `config.toml`, which the runner reads.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class RepoRolesUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var stubURL: URL!
    private var app: XCUIApplication!

    private var machineFile: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-repo-roles-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
        stubURL = try Self.writeStub(in: stubDirectory)
    }

    override func tearDown() async throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
    }

    /// Writes `machineTOML` as `config.toml`, then launches the app against it and the stub `yh`.
    private func launch(machineTOML: String) throws {
        try machineTOML.write(to: machineFile, atomically: true, encoding: .utf8)
        app = .yellowhammer(configurationDirectory: configurationDirectory)
        app.launchArguments += [
            "-YellowhammerEngineStub", stubURL.path(percentEncoded: false)
        ]
        app.launch()
    }

    func testBuiltInRolesListAndDeclaringWritesTheMachineFile() throws {
        try launch(machineTOML: Self.machineTOML)
        openRepoRolesPane()
        let window = app.windows["Repo Roles"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "The toolbar does not name the section")

        for role in ["spec", "backend", "mobile", "web"] {
            XCTAssertTrue(
                window.descendants(matching: .any)["repo-role-row-\(role)"].firstMatch.waitForExistence(timeout: 5),
                "\(role) is not listed"
            )
        }
        XCTAssertFalse(window.buttons["repo-role-remove-spec"].exists)

        let name = window.textFields["repo-role-declare-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("firmware")
        window.buttons["repo-role-declare"].click()

        XCTAssertTrue(
            window.descendants(matching: .any)["repo-role-row-firmware"].firstMatch.waitForExistence(timeout: 10),
            "The declared Repo Role is not listed"
        )
        XCTAssertFalse(window.staticTexts["repo-role-declare-failure"].exists)

        let written = try String(contentsOf: machineFile, encoding: .utf8)
        XCTAssertTrue(written.contains("repo_roles = [\"firmware\"]"), written)
        XCTAssertTrue(written.contains("[cli.\"claude\"]") || written.contains("[cli.claude]"), written)
        XCTAssertTrue(written.contains("[cli.\"codex\"]") || written.contains("[cli.codex]"), written)
        XCTAssertTrue(written.contains("[[routing]]"), written)
    }

    func testDeclaringAnInvalidNameIsRefusedBeforeWriting() throws {
        try launch(machineTOML: Self.machineTOML)
        openRepoRolesPane()
        let window = app.windows["Repo Roles"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "The toolbar does not name the section")

        let name = window.textFields["repo-role-declare-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Firmware")
        window.buttons["repo-role-declare"].click()

        XCTAssertTrue(window.staticTexts["repo-role-declare-failure"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.descendants(matching: .any)["repo-role-row-Firmware"].firstMatch.exists)
        let written = try String(contentsOf: machineFile, encoding: .utf8)
        XCTAssertEqual(written, Self.machineTOML)
    }

    func testRemovingADeclaredRoleRewritesTheFile() throws {
        try launch(machineTOML: "repo_roles = [\"infra\"]\n\n" + Self.machineTOML)
        openRepoRolesPane()
        let window = app.windows["Repo Roles"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "The toolbar does not name the section")

        let row = window.descendants(matching: .any)["repo-role-row-infra"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The declared Repo Role is not listed")
        window.buttons["repo-role-remove-infra"].click()
        let confirm = app.buttons["repo-role-remove-confirm-infra"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 10)
        let written = try String(contentsOf: machineFile, encoding: .utf8)
        XCTAssertFalse(written.contains("repo_roles"), written)
    }

    private func openRepoRolesPane() {
        app.activate()
        // The application menu's Settings item, not Cmd+,: a synthesized shortcut was dropped once while
        // the app settled, and the menu item is the same command.
        app.menuBars.menuBarItems["Yellowhammer"].click()
        app.menuBars.menuItems["Settings\u{2026}"].click()
        let row = app.descendants(matching: .any)["settings-repo-roles"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings did not open")
        row.click()
    }

    private static let machineTOML = """
    [board.linear.connections.acme]
    credential = "keychain:linear"
    workspace = "workspace-1"
    yellowhammer_identity = "app-user-1"
    [code_hosting.github.connections.github]
    type = "keychain"
    credential = "keychain:github"

    [cli.claude]
    [cli.codex]

    [[routing]]
    route = "claude/sonnet/medium"
    """

    /// A `sh` script, read (never exec'd) by `/bin/sh`; the pane never runs `yh`, so it only has to exist.
    private static func writeStub(in directory: URL) throws -> URL {
        let script = """
        #!/bin/sh
        exit 0
        """
        let stubURL = directory.appending(component: "yh.sh", directoryHint: .notDirectory)
        try script.write(to: stubURL, atomically: true, encoding: .utf8)
        return stubURL
    }
}
