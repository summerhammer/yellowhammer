import Foundation
import XCTest

/// The Settings window's Code Hosting pane driven against the shared stub `yh` (`EngineStub`): the Code
/// Hosting Connections list, connecting the gh CLI or a Keychain token, replacing a token, and removing a
/// connection. The report `yh` prints is a file in the test runner's container
/// (`YH_STUB_CODE_HOSTING_REPORT_FILE`), so a test can change it mid-test; a run that `yh` would end by editing
/// `config.toml` waits on a gate (`YH_STUB_GATE_DIR`, `YH_STUB_CODE_HOSTING_GATES`) while the test makes that
/// edit itself, as in `AddProjectUITests`. The stub's argv log shows what the app ran, and that it never put a
/// token on the command line.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class CodeHostingSettingsUITests: XCTestCase {
    var configurationDirectory: URL!
    var app: XCUIApplication!
    var argvLog: URL!
    var reportFile: URL!
    var gateDirectory: URL!

    var machineFile: URL { configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory) }

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-code-hosting-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        gateDirectory = base.appending(component: "gates", directoryHint: .isDirectory)
        let stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        for directory in [configurationDirectory!, gateDirectory!, stubDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        reportFile = base.appending(component: "report.json", directoryHint: .notDirectory)
        let stubURL = try EngineStub.write(in: stubDirectory)
        argvLog = URL(filePath: "/tmp/yh-uitest-code-hosting-argv-\(UUID().uuidString)")

        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-YellowhammerEngineStub", stubURL.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launchEnvironment = [
            "YH_STUB_ARGV_LOG": argvLog.path(percentEncoded: false),
            "YH_STUB_CODE_HOSTING_REPORT_FILE": reportFile.path(percentEncoded: false)
        ]
    }

    override func tearDown() async throws {
        if testRun?.hasSucceeded == false {
            add(XCTAttachment(string: app.debugDescription))
            add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        }
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
        if let argvLog { try? FileManager.default.removeItem(at: argvLog) }
    }

    // MARK: Helpers

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func text(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    /// Polls the condition (pumping the run loop) until it holds or `timeout` passes; returns whether it holds.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// The argument vectors the stub recorded, one per run.
    func recordedArguments() -> [String] {
        let contents = (try? String(contentsOf: argvLog, encoding: .utf8)) ?? ""
        return contents.split(separator: "\n").map(String.init)
    }

    /// Whether the stub has recorded exactly `line`, waiting for it.
    func waitForRecorded(_ line: String) -> Bool {
        waitUntil { recordedArguments().contains(line) }
    }

    /// Writes `config.toml`, Project `alpha` and the report `yh` will print.
    func writeFixture(
        connections: [String] = CodeHostingSettingsUITests.defaultConnections,
        offer: String = CodeHostingSettingsUITests.availableOffer
    ) throws {
        try Self.machineTOML().write(to: machineFile, atomically: true, encoding: .utf8)
        let projects = configurationDirectory.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Self.alphaProjectTOML.write(
            to: projects.appending(component: "alpha.toml"), atomically: true, encoding: .utf8
        )
        try writeReport(connections: connections, offer: offer)
    }

    func writeReport(connections: [String], offer: String) throws {
        try Self.report(connections, offer: offer).write(to: reportFile, atomically: true, encoding: .utf8)
    }

    /// Appends `text` to `config.toml` as its own lines, as the edit a gated stub run stands for.
    func appendToMachine(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: machineFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + text + "\n").utf8))
    }

    /// Makes the stub's connect, replace and remove runs wait on their gates.
    func enableGates() {
        app.launchEnvironment["YH_STUB_CODE_HOSTING_GATES"] = "1"
        app.launchEnvironment["YH_STUB_GATE_DIR"] = gateDirectory.path(percentEncoded: false)
    }

    /// Lets a stub run waiting on the gate `name` finish (`EngineStub.waitForGate`).
    func openGate(_ name: String) {
        let gate = gateDirectory.appending(component: name, directoryHint: .notDirectory)
        XCTAssertTrue(FileManager.default.createFile(atPath: gate.path(percentEncoded: false), contents: nil))
    }

    /// Launches, waits for the main window, opens Settings from the application menu and shows Code Hosting.
    func showCodeHostingSettings() {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        // The application menu's Settings item, not Cmd+,: a synthesized shortcut was dropped once while
        // the app settled, and the menu item is the same command.
        app.menuBars.menuBarItems["Yellowhammer"].click()
        app.menuBars.menuItems["Settings\u{2026}"].click()
        let codeHosting = element("settings-code-hosting")
        XCTAssertTrue(codeHosting.waitForExistence(timeout: 5))
        codeHosting.click()
        XCTAssertTrue(element("settings-code-hosting-pane").waitForExistence(timeout: 5))
    }

    /// Clicks the Remove button of `name` and confirms the dialog (a sheet's button, not `app.buttons`: a
    /// Touch Bar element matches that).
    func removeConnection(_ name: String) {
        let remove = element("settings-code-hosting-remove-\(name)")
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.click()
        let confirm = app.sheets.buttons["Remove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
    }

    // MARK: Listing

    func testConnectionsAreListedWithTheirIdentityTypeAndProjects() throws {
        try writeFixture()
        showCodeHostingSettings()

        let github = element("settings-code-hosting-connection-github")
        XCTAssertTrue(github.waitForExistence(timeout: 10))
        // The Code Hosting identity read live through yh; the local name stands in until it is read.
        XCTAssertTrue(waitUntil { text(of: github).contains("octocat") }, text(of: github))
        XCTAssertTrue(text(of: element("settings-code-hosting-type-github")).contains("Keychain token"))
        XCTAssertTrue(text(of: element("settings-code-hosting-projects-github")).contains("alpha"))

        let companyA = element("settings-code-hosting-connection-company-a")
        XCTAssertTrue(companyA.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: companyA).contains("company-a"), text(of: companyA))
        let status = element("settings-code-hosting-status-company-a")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: status).contains(Self.companyARefusal), text(of: status))

        let unsupported = element("settings-code-hosting-unsupported")
        XCTAssertTrue(unsupported.waitForExistence(timeout: 5))
        XCTAssertEqual(unsupported.descendants(matching: .button).count, 0)
    }

    func testTheGitHubCLIOptionIsDisabledWithYhsReason() throws {
        try writeFixture(offer: Self.unavailableOffer)
        showCodeHostingSettings()

        let detail = element("settings-code-hosting-gh-detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { text(of: detail).contains("gh auth login") }, text(of: detail))
        XCTAssertFalse(element("settings-code-hosting-connect-gh").isEnabled)
    }

    func testGeneralNoLongerShowsTheGitHubCredentialCard() throws {
        try writeFixture()
        showCodeHostingSettings()

        let general = element("settings-general")
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        general.click()
        XCTAssertTrue(element("settings-general-pane").waitForExistence(timeout: 5))
        XCTAssertFalse(element("settings-github").exists)
        XCTAssertFalse(element("github-credential-state").exists)
    }
}
