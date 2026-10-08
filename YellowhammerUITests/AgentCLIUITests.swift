import Foundation
import XCTest

/// The Settings window's Agent CLIs pane driven against a stub `yh` (P14.4, #281). The UI test runner is itself
/// sandboxed, so the stub — run via `/bin/sh <stub>`, the same crossing `AddProjectUITests` documents — cannot
/// write a Ledger row the (unsandboxed) app under test could then read back. So this suite covers what
/// crosses the sandbox boundary through the app itself: both declared CLIs listed as never probed,
/// running a Probe streaming the stub's echoed arguments and exit status into the window's log, and
/// declaring a CLI on a machine file that has none — the app writes `config.toml`, which the runner reads.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class AgentCLIUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var stubURL: URL!
    private var app: XCUIApplication!

    private var machineFile: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-agent-cli-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    /// Writes `machineTOML` as `config.toml` — none at all when nil — then launches the app against it and
    /// the stub `yh`.
    /// `discoveryHome`, when given, is the fixture home directory the pane's discovery searches instead of the
    /// real machine (`-YellowhammerDiscoveryHome`); without it, discovery finds nothing.
    private func launch(machineTOML: String?, discoveryHome: URL? = nil) throws {
        try machineTOML?.write(to: machineFile, atomically: true, encoding: .utf8)
        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-YellowhammerEngineStub", stubURL.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        if let discoveryHome {
            app.launchArguments += ["-YellowhammerDiscoveryHome", discoveryHome.path(percentEncoded: false)]
        }
        app.launch()
    }

    func testDeclaredCLIsListAsNeverProbedAndProbeStreamsTheLog() throws {
        try launch(machineTOML: Self.machineTOML)
        openAgentCLIsPane()
        let window = app.windows["Agent CLIs"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "The toolbar does not name the section")

        let claudeProbedAt = window.staticTexts["agent-cli-probed-at-claude"]
        XCTAssertTrue(claudeProbedAt.waitForExistence(timeout: 5))
        XCTAssertEqual(claudeProbedAt.value as? String, "Never probed")

        let codexProbedAt = window.staticTexts["agent-cli-probed-at-codex"]
        XCTAssertTrue(codexProbedAt.waitForExistence(timeout: 5))
        XCTAssertEqual(codexProbedAt.value as? String, "Never probed")

        let probeButton = window.buttons["agent-cli-probe-claude"]
        XCTAssertTrue(probeButton.waitForExistence(timeout: 5))
        probeButton.click()

        let log = window.staticTexts["agent-cli-probe-log"]
        XCTAssertTrue(log.waitForExistence(timeout: 10))
        let recorded = argv(in: (log.value as? String) ?? "")
        XCTAssertTrue(recorded.contains("probe"), recorded.joined(separator: ","))
        XCTAssertTrue(recorded.contains("claude"), recorded.joined(separator: ","))

        let exitStatus = window.staticTexts["agent-cli-probe-exit-status"]
        XCTAssertTrue(exitStatus.waitForExistence(timeout: 5))
        let statusText = (exitStatus.value as? String) ?? ""
        XCTAssertTrue(statusText.contains("1"), statusText)
    }

    /// A fresh Mac with no `config.toml` at all: the pane still offers to declare a CLI, and declaring one
    /// creates the file — the Add Project sheet waits on a route, so nothing here may wait on that sheet.
    /// The pane offers no way into a second Add Project sheet.
    func testDeclaringACLIOnAFreshMacCreatesTheMachineFile() throws {
        try launch(machineTOML: nil)
        openAgentCLIsPane()
        let window = app.windows["Agent CLIs"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "The toolbar does not name the section")
        XCTAssertFalse(window.buttons["open-setup"].exists)

        let picker = window.popUpButtons["agent-cli-declare-name"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "claude")
        window.buttons["agent-cli-declare"].click()

        let probedAt = window.staticTexts["agent-cli-probed-at-claude"]
        XCTAssertTrue(probedAt.waitForExistence(timeout: 10), "The declared CLI is not listed")
        XCTAssertFalse(window.staticTexts["agent-cli-declare-failure"].exists)
        XCTAssertTrue(window.buttons["agent-cli-open-routing-table"].waitForExistence(timeout: 5))

        let written = try String(contentsOf: machineFile, encoding: .utf8)
        XCTAssertTrue(written.contains("[cli.\"claude\"]") || written.contains("[cli.claude]"), written)
    }

    /// A fresh Mac after `yh setup --install-linear`: `config.toml` exists with no CLI and no route. The
    /// pane declares `claude` with an executable, writes it, lists it as never probed, and points to
    /// the base Routing Table for the route the Add Project sheet still needs.
    func testDeclaringACLIWritesItAndPointsToTheRoutingTable() throws {
        try launch(machineTOML: Self.linearOnlyMachineTOML)
        openAgentCLIsPane()
        let window = app.windows["Agent CLIs"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "The toolbar does not name the section")

        let picker = window.popUpButtons["agent-cli-declare-name"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "claude")

        let executable = window.textFields["agent-cli-declare-executable"]
        XCTAssertTrue(executable.waitForExistence(timeout: 5))
        executable.click()
        executable.typeText("/opt/homebrew/bin/claude")

        window.buttons["agent-cli-declare"].click()

        let probedAt = window.staticTexts["agent-cli-probed-at-claude"]
        XCTAssertTrue(probedAt.waitForExistence(timeout: 10), "The declared CLI is not listed")
        XCTAssertEqual(probedAt.value as? String, "Never probed")
        XCTAssertFalse(window.staticTexts["agent-cli-declare-failure"].exists)

        let written = try String(contentsOf: machineFile, encoding: .utf8)
        XCTAssertTrue(written.contains("[cli.\"claude\"]") || written.contains("[cli.claude]"), written)
        XCTAssertTrue(written.contains("executable = \"/opt/homebrew/bin/claude\""), written)

        // `codex` is the only name left to declare.
        XCTAssertEqual(picker.value as? String, "codex")

        let noRoute = window.staticTexts["agent-cli-no-route"]
        XCTAssertTrue(noRoute.waitForExistence(timeout: 5))
        window.buttons["agent-cli-open-routing-table"].click()
        XCTAssertTrue(app.windows["Base Routing Table"].waitForExistence(timeout: 10))
    }

    /// Discovery (#375) against a fixture home: `codex` is found in `~/.local/bin`, `claude` is already declared
    /// at an explicit path with a space in it that discovery does not find, and `agy` is nowhere. Declaring the
    /// found `codex` goes through the existing flow and writes its absolute path; the explicit `claude`
    /// declaration and the one route stay exactly as they were, and no route is added.
    func testDeclaringADetectedCLIKeepsExplicitPathsAndRoutes() throws {
        let base = configurationDirectory.deletingLastPathComponent()
        let home = base.appending(component: "home", directoryHint: .isDirectory)
        let codex = try Self.writeExecutable(named: "codex", in: home.appending(path: ".local/bin"))
        let claude = try Self.writeExecutable(named: "claude", in: base.appending(path: "Claude Install/bin"))
        let claudePath = claude.path(percentEncoded: false)
        let route = "route = \"claude/sonnet/medium\""
        try launch(
            machineTOML: Self.linearOnlyMachineTOML + """

            [cli.claude]
            executable = "\(claudePath)"

            [[routing]]
            \(route)
            """,
            discoveryHome: home
        )
        openAgentCLIsPane()
        let window = app.windows["Agent CLIs"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "The toolbar does not name the section")

        let foundPath = window.staticTexts["agent-cli-detected-path-codex"]
        XCTAssertTrue(foundPath.waitForExistence(timeout: 10), "The found codex is not listed")
        XCTAssertEqual(foundPath.value as? String, codex.path(percentEncoded: false))
        XCTAssertTrue(window.staticTexts["agent-cli-detected-not-found-agy"].exists)
        XCTAssertTrue(window.staticTexts["agent-cli-detected-not-found-claude"].exists)
        XCTAssertFalse(window.buttons["agent-cli-detected-use-claude"].exists)

        window.buttons["agent-cli-detected-declare-codex"].click()

        let probedAt = window.staticTexts["agent-cli-probed-at-codex"]
        XCTAssertTrue(probedAt.waitForExistence(timeout: 10), "The declared CLI is not listed")
        XCTAssertEqual(probedAt.value as? String, "Never probed")
        XCTAssertFalse(window.staticTexts["agent-cli-declare-failure"].exists)

        let written = try String(contentsOf: machineFile, encoding: .utf8)
        XCTAssertTrue(written.contains("[cli.codex]") || written.contains("[cli.\"codex\"]"), written)
        XCTAssertTrue(written.contains("executable = \"\(codex.path(percentEncoded: false))\""), written)
        XCTAssertTrue(written.contains("executable = \"\(claudePath)\""), written)
        XCTAssertEqual(written.components(separatedBy: "[[routing]]").count - 1, 1, written)
        XCTAssertTrue(written.contains(route), written)
    }

    /// Writes a `sh` script named `name` into `directory`, mode 0755. Discovery only stats it; nothing runs it.
    private static func writeExecutable(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(component: name, directoryHint: .notDirectory)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    /// Every `argv: <arg>` line the stub echoed, in order.
    private func argv(in log: String) -> [String] {
        log.split(separator: "\n")
            .filter { $0.hasPrefix("argv: ") }
            .map { String($0.dropFirst("argv: ".count)) }
    }

    private func openAgentCLIsPane() {
        app.activate()
        // The application menu's Settings item, not Cmd+,: a synthesized shortcut was dropped once while
        // the app settled, and the menu item is the same command.
        app.menuBars.menuBarItems["Yellowhammer"].click()
        app.menuBars.menuItems["Settings\u{2026}"].click()
        let row = app.descendants(matching: .any)["settings-agent-clis"].firstMatch
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

    /// What `yh setup --install-linear` writes on a Mac with no `config.toml`: no CLI, no route.
    private static let linearOnlyMachineTOML = """
    [board.linear.connections.acme]
    credential = "keychain:linear"
    workspace = "workspace-1"
    yellowhammer_identity = "app-user-1"
    [code_hosting.github.connections.github]
    type = "keychain"
    credential = "keychain:github"
    """

    /// A `sh` script, read (never exec'd) by `/bin/sh`: it echoes every argument as `argv: <arg>`, then
    /// a canned report line, then exits 1 — the same "a result, not a crash" status `yh probe` returns
    /// when a finding failed or drifted. The stub writes no file and no Ledger row: the sandboxed
    /// runner that creates it cannot write anywhere the unsandboxed app could read back.
    private static func writeStub(in directory: URL) throws -> URL {
        let script = """
        #!/bin/sh
        for arg in "$@"; do
          echo "argv: $arg"
        done
        echo "verdict: failed"
        exit 1
        """
        let stubURL = directory.appending(component: "yh.sh", directoryHint: .notDirectory)
        try script.write(to: stubURL, atomically: true, encoding: .utf8)
        return stubURL
    }
}
