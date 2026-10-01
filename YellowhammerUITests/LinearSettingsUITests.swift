import Foundation
import XCTest

/// The Settings window's General pane driven against the shared stub `yh` (`EngineStub`): the Linear
/// install (P17.7/P17.9, now from Settings) and the Operator identity (P18.16). The stub's run
/// environment and `/tmp` markers follow `AddProjectUITests`; it also appends each `--install-linear`
/// argument vector to `YH_STUB_ARGV_LOG`, so a test can assert on what the app ran.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class LinearSettingsUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var app: XCUIApplication!
    private var installedMarker: URL!
    private var attemptsMarker: URL!
    private var argvLog: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-linear-settings-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
        let stubURL = try EngineStub.write(in: stubDirectory)
        let uniqueSuffix = UUID().uuidString
        installedMarker = URL(filePath: "/tmp/yh-uitest-installed-\(uniqueSuffix)")
        attemptsMarker = URL(filePath: "/tmp/yh-uitest-attempts-\(uniqueSuffix)")
        argvLog = URL(filePath: "/tmp/yh-uitest-argv-\(uniqueSuffix)")

        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-YellowhammerEngineStub", stubURL.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launchEnvironment = [
            "YH_STUB_INSTALLED_MARKER": installedMarker.path(percentEncoded: false),
            "YH_STUB_ATTEMPTS_MARKER": attemptsMarker.path(percentEncoded: false),
            "YH_STUB_ARGV_LOG": argvLog.path(percentEncoded: false)
        ]
    }

    override func tearDown() async throws {
        if testRun?.hasSucceeded == false {
            add(XCTAttachment(string: app.debugDescription))
            add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        }
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
        for marker in [installedMarker, attemptsMarker, argvLog] {
            if let marker { try? FileManager.default.removeItem(at: marker) }
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    /// Launches, waits for the main window, opens Settings with Cmd+, and shows the General section.
    private func showGeneralSettings(
        portsBusyFirst: Bool = false,
        relayUnreachable: Bool = false,
        waitingFor readyID: String? = "overview-onboarding"
    ) {
        if portsBusyFirst { app.launchEnvironment["YH_STUB_PORTS_BUSY_FIRST"] = "1" }
        if relayUnreachable { app.launchEnvironment["YH_STUB_RELAY_UNREACHABLE"] = "1" }
        app.launch()
        if let readyID {
            XCTAssertTrue(element(readyID).waitForExistence(timeout: 10))
        } else {
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        }
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let general = element("settings-general")
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        general.click()
        XCTAssertTrue(element("settings-general-pane").waitForExistence(timeout: 5))
    }

    /// The argument vectors the stub recorded for `--install-linear`, one per attempt.
    private func recordedArguments() -> [String] {
        let contents = (try? String(contentsOf: argvLog, encoding: .utf8)) ?? ""
        return contents.split(separator: "\n").map(String.init)
    }

    private func installLocally() {
        let install = element("setup-linear-install")
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        install.click()
    }

    func testLocalInstallShowsTheWorkspaceNameAndRunsTheLocalArguments() {
        showGeneralSettings()
        installLocally()
        let installed = element("setup-linear-installed")
        XCTAssertTrue(installed.waitForExistence(timeout: 10))
        XCTAssertTrue(text(of: installed).contains("Acme"))

        let recorded = recordedArguments()
        XCTAssertEqual(recorded.count, 1)
        let line = recorded.first ?? ""
        XCTAssertTrue(line.contains("setup --install-linear --events json"), line)
        XCTAssertFalse(line.contains("--linear-credential"), line)
        XCTAssertFalse(line.contains("--remote"), line)
    }

    func testInstalledOffersToInstallAgainOrRequestApproval() {
        showGeneralSettings()
        installLocally()
        XCTAssertTrue(element("setup-linear-installed").waitForExistence(timeout: 10))
        XCTAssertTrue(element("setup-linear-install").waitForExistence(timeout: 5))
        XCTAssertTrue(element("setup-linear-request-remote").exists)
    }

    func testPortsBusyThenRetryInstalls() {
        showGeneralSettings(portsBusyFirst: true)
        installLocally()
        XCTAssertTrue(element("setup-linear-ports-busy").waitForExistence(timeout: 10))
        let retry = element("setup-linear-retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.click()
        XCTAssertTrue(element("setup-linear-installed").waitForExistence(timeout: 10))
    }

    func testRemoteApprovalShowsTheLinkThenInstalls() {
        showGeneralSettings()
        let request = element("setup-linear-request-remote")
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.click()

        let link = element("setup-linear-approval-link")
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertTrue(text(of: link).contains("https://app.yellowhammer.dev/install/test-session"))
        XCTAssertTrue(element("setup-linear-awaiting-remote").exists)

        let installed = element("setup-linear-installed")
        XCTAssertTrue(installed.waitForExistence(timeout: 15))
        XCTAssertTrue(text(of: installed).contains("scratch"))
        XCTAssertTrue(recordedArguments().first?.contains("--remote") ?? false)
    }

    func testRelayUnreachableOffersRetryAndLocalInstall() {
        showGeneralSettings(relayUnreachable: true)
        let request = element("setup-linear-request-remote")
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.click()

        XCTAssertTrue(element("setup-linear-failed").waitForExistence(timeout: 10))
        XCTAssertTrue(element("setup-linear-retry").exists)
        installLocally()
        XCTAssertTrue(element("setup-linear-installed").waitForExistence(timeout: 10))
    }

    /// The configured Operator identity shows, and "Choose…" reads the candidates through `yh`.
    func testOperatorIdentityShowsTheConfiguredIdAndOffersCandidates() throws {
        try """
        [linear]
        credential = "keychain:linear"
        operator = "user-op"
        [github]
        credential = "keychain:github"

        [cli.claude]

        [[routing]]
        route = "claude/sonnet"
        """.write(to: configurationDirectory.appending(component: "config.toml"), atomically: true, encoding: .utf8)
        showGeneralSettings(waitingFor: nil)

        let configured = element("settings-operator-configured")
        XCTAssertTrue(configured.waitForExistence(timeout: 10))
        let ids = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'user-op' OR label CONTAINS 'user-op'"))
        XCTAssertTrue(ids.firstMatch.waitForExistence(timeout: 5))

        let choose = element("settings-operator-choose")
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        XCTAssertTrue(element("settings-operator-picker").waitForExistence(timeout: 10))
    }
}
