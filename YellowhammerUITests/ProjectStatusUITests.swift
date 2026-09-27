import Foundation
import XCTest

/// The Status tab of a Project window (P14.6; OQ12 Surface 3) driven against a stub `yh`, modelled on
/// `AgentCLIUITests` (the stub crossing the UI runner's sandbox) plus `CardAccountUITests`' machine and
/// `projects/demo.toml` fixture. Covers that the tab runs `yh status --project demo` then
/// `yh doctor --project demo`, shows each command's output verbatim, and never passes `--fix` or
/// `--probe`.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class ProjectStatusUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-project-status-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let projectsDirectory = configurationDirectory.appending(component: "projects", directoryHint: .isDirectory)
        let stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)

        try Self.machineTOML.write(
            to: configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory),
            atomically: true, encoding: .utf8
        )
        try Self.demoProjectTOML.write(
            to: projectsDirectory.appending(component: "demo.toml", directoryHint: .notDirectory),
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

    func testStatusAndDoctorRunAndDisplayVerbatim() throws {
        let statusTab = app.tabs["Status"]
        XCTAssertTrue(statusTab.waitForExistence(timeout: 10))
        statusTab.click()

        let statusLog = app.staticTexts["project-status-status-log"]
        XCTAssertTrue(statusLog.waitForExistence(timeout: 10))
        let doctorLog = app.staticTexts["project-status-doctor-log"]
        XCTAssertTrue(doctorLog.waitForExistence(timeout: 10))

        // Wait for the sequential yh status / yh doctor pair to finish: the doctor exit status caption
        // only appears once doctorExitStatus is set.
        let doctorExitStatus = app.staticTexts["project-status-doctor-exit-status"]
        XCTAssertTrue(doctorExitStatus.waitForExistence(timeout: 10))

        let statusText = (statusLog.value as? String) ?? ""
        for line in Self.stagedStatusLines {
            XCTAssertTrue(statusText.contains(line), "missing status line: \(line)\nfull: \(statusText)")
        }

        let doctorText = (doctorLog.value as? String) ?? ""
        for line in Self.stagedDoctorLines {
            XCTAssertTrue(doctorText.contains(line), "missing doctor line: \(line)\nfull: \(doctorText)")
        }

        let statusArgv = argv(in: statusText)
        XCTAssertTrue(statusArgv.contains("status"), statusArgv.joined(separator: ","))
        XCTAssertTrue(statusArgv.contains("--project"), statusArgv.joined(separator: ","))
        XCTAssertTrue(statusArgv.contains("demo"), statusArgv.joined(separator: ","))
        XCTAssertFalse(statusArgv.contains("--fix"), statusArgv.joined(separator: ","))
        XCTAssertFalse(statusArgv.contains("--probe"), statusArgv.joined(separator: ","))

        let doctorArgv = argv(in: doctorText)
        XCTAssertTrue(doctorArgv.contains("doctor"), doctorArgv.joined(separator: ","))
        XCTAssertTrue(doctorArgv.contains("--project"), doctorArgv.joined(separator: ","))
        XCTAssertTrue(doctorArgv.contains("demo"), doctorArgv.joined(separator: ","))
        XCTAssertFalse(doctorArgv.contains("--fix"), doctorArgv.joined(separator: ","))
        XCTAssertFalse(doctorArgv.contains("--probe"), doctorArgv.joined(separator: ","))
        XCTAssertFalse(doctorArgv.contains("--yes"), doctorArgv.joined(separator: ","))

        let doctorExitText = (doctorExitStatus.value as? String) ?? ""
        XCTAssertTrue(doctorExitText.contains("1"), doctorExitText)

        XCTAssertFalse(app.staticTexts["project-status-status-exit-status"].exists)
    }

    /// Every `argv: <arg>` line the stub echoed, in order.
    private func argv(in log: String) -> [String] {
        log.split(separator: "\n")
            .filter { $0.hasPrefix("argv: ") }
            .map { String($0.dropFirst("argv: ".count)) }
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

    private static let stagedStatusLines = [
        "Project demo:",
        "  last run: no Journal: this Project has never run an Act",
        "  last Night: none",
        "  author: not installed",
        "  build: not installed",
        "  land: not installed",
        "  sleep and wake: no sleep recorded",
        "  missed Nights:",
        "    2026-09-22: no LaunchAgent can fire: author not installed, build not installed, "
            + "land not installed; run `yh setup --install-jobs`"
    ]

    private static let stagedDoctorLines = [
        "[pass] configuration: Project demo is valid",
        "[FAIL] git: Project demo repo app at /nonexistent does not exist",
        "[warn] launchd: no LaunchAgent installed for Project demo",
        "1 failed, 1 warnings"
    ]

    /// A `sh` script, read (never exec'd) by `/bin/sh`: it echoes every argument as `argv: <arg>`, then a
    /// staged report matching the first argument (`status` or `doctor`). The stub writes no file: the
    /// sandboxed runner that creates it cannot write anywhere the unsandboxed app could read back.
    private static func writeStub(in directory: URL) throws -> URL {
        let script = """
        #!/bin/sh
        for arg in "$@"; do
          echo "argv: $arg"
        done
        case "$1" in
          status)
        \(stagedStatusLines.map(echoLine).joined(separator: "\n"))
            exit 0
            ;;
          doctor)
        \(stagedDoctorLines.map(echoLine).joined(separator: "\n"))
            exit 1
            ;;
        esac
        """
        let stubURL = directory.appending(component: "yh.sh", directoryHint: .notDirectory)
        try script.write(to: stubURL, atomically: true, encoding: .utf8)
        return stubURL
    }

    /// One staged line as a `sh` `echo` statement inside a double-quoted string: backslash-escapes `"`,
    /// `` ` `` and `$` so the shell emits the line verbatim rather than treating a backtick as command
    /// substitution or a `$` as a variable reference.
    private static func echoLine(_ line: String) -> String {
        var escaped = line
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "`", with: "\\`")
        escaped = escaped.replacingOccurrences(of: "$", with: "\\$")
        return "    echo \"\(escaped)\""
    }
}
