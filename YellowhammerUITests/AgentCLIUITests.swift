import Foundation
import XCTest

/// The Agent CLIs window driven against a stub `yh` (P14.4). The UI test runner is itself sandboxed,
/// so the stub — run via `/bin/sh <stub>`, the same crossing `SetupWizardUITests` documents — cannot
/// write a Ledger row the (unsandboxed) app under test could then read back. So this suite covers what
/// crosses the sandbox boundary through the app itself: both declared CLIs listed as never probed, and
/// running a Probe streaming the stub's echoed arguments and exit status into the window's log.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class AgentCLIUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-agent-cli-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)

        try Self.machineTOML.write(
            to: configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory),
            atomically: true, encoding: .utf8
        )
        let stubURL = try Self.writeStub(in: stubDirectory)

        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-YellowhammerEngineStub", stubURL.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
    }

    func testDeclaredCLIsListAsNeverProbedAndProbeStreamsTheLog() throws {
        openAgentCLIWindow()
        let window = app.windows["Agent CLIs"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))

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

    /// Every `argv: <arg>` line the stub echoed, in order.
    private func argv(in log: String) -> [String] {
        log.split(separator: "\n")
            .filter { $0.hasPrefix("argv: ") }
            .map { String($0.dropFirst("argv: ".count)) }
    }

    private func openAgentCLIWindow() {
        app.menuBars.menuItems["Agent CLIs\u{2026}"].click()
    }

    private static let machineTOML = """
    [linear]
    credential = "keychain:linear"
    [github]
    credential = "keychain:github"

    [cli.claude]
    [cli.codex]

    [[routing]]
    route = "claude/sonnet/medium"
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
