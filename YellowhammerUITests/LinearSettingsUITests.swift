import Foundation
import XCTest

/// The Settings window's Boards pane driven against the shared stub `yh` (`EngineStub`): the Linear
/// workspaces list (roadmap L3.1) — connecting another workspace (P17.7/P17.9), re-connecting, removing
/// and changing one workspace's Operator identity. The stub's run
/// environment and `/tmp` markers follow `AddProjectUITests`; it also appends each `--install-linear`
/// `config` argument vector to `YH_STUB_ARGV_LOG`, so a test can assert on what the app ran.
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

    /// Launches, waits for the main window, opens Settings with Cmd+, and shows the Boards section.
    private func showBoardsSettings(
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
        // The application menu's Settings item, not Cmd+,: a synthesized shortcut was dropped once while
        // the app settled, and the menu item is the same command.
        app.menuBars.menuBarItems["Yellowhammer"].click()
        app.menuBars.menuItems["Settings\u{2026}"].click()
        let boards = element("settings-boards")
        XCTAssertTrue(boards.waitForExistence(timeout: 5))
        boards.click()
        XCTAssertTrue(element("settings-boards-pane").waitForExistence(timeout: 5))
    }

    /// The argument vectors the stub recorded for `--install-linear` and `config`, one per run.
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
        showBoardsSettings()
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
        showBoardsSettings()
        installLocally()
        XCTAssertTrue(element("setup-linear-installed").waitForExistence(timeout: 10))
        XCTAssertTrue(element("setup-linear-install").waitForExistence(timeout: 5))
        XCTAssertTrue(element("setup-linear-request-remote").exists)
    }

    func testPortsBusyThenRetryInstalls() {
        showBoardsSettings(portsBusyFirst: true)
        installLocally()
        XCTAssertTrue(element("setup-linear-ports-busy").waitForExistence(timeout: 10))
        let retry = element("setup-linear-retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.click()
        XCTAssertTrue(element("setup-linear-installed").waitForExistence(timeout: 10))
    }

    func testRemoteApprovalShowsTheLinkThenInstalls() {
        showBoardsSettings()
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
        showBoardsSettings(relayUnreachable: true)
        let request = element("setup-linear-request-remote")
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.click()

        XCTAssertTrue(element("setup-linear-failed").waitForExistence(timeout: 10))
        XCTAssertTrue(element("setup-linear-retry").exists)
        installLocally()
        XCTAssertTrue(element("setup-linear-installed").waitForExistence(timeout: 10))
    }
}

// MARK: - The Linear workspaces list (roadmap L3.1)

extension LinearSettingsUITests {
    /// Two App Installations; Project `alpha` uses `acme`, none uses `scratch`, whose Operator identity is
    /// not one of the stub's candidates.
    private static let twoInstallationsTOML = """
    [board.linear.installations.acme]
    credential = "keychain:linear-acme"
    workspace = "workspace-1"
    app_user = "app-user-1"
    operator = "user-op"

    [board.linear.installations.scratch]
    credential = "keychain:linear-scratch"
    workspace = "workspace-2"
    app_user = "app-user-2"
    operator = "user-old"

    [github]
    credential = "keychain:github"

    [cli.claude]

    [[routing]]
    route = "claude/sonnet/medium"
    """

    private static let alphaProjectTOML = """
    id = "alpha"
    name = "Alpha"
    spec_source = "~/dev/alpha-spec"

    [board.linear]
    installation = "acme"
    project = "ALPHA"

    [[repos]]
    name = "backend"
    path = "~/dev/alpha-backend"
    role = "backend"
    check = "swift test"
    """

    /// `yh doctor --check linear --json`'s rows for the two installations: `acme` authorizes and has its
    /// workspace name; `scratch` was revoked, so Linear gave no name for it.
    private static let twoInstallationsDoctorRows = """
    [{"check":"linear","installation":"acme","message":"ok","projects":["alpha"],"severity":"pass",\
    "subject":"authorization","workspace":"workspace-1","workspaceName":"Acme Corp"},\
    {"check":"linear","installation":"scratch","message":"installation scratch: revoked","projects":[],\
    "severity":"failure","subject":"authorization","workspace":"workspace-2"}]
    """

    private func writeTwoInstallations() throws {
        try Self.twoInstallationsTOML.write(
            to: configurationDirectory.appending(component: "config.toml"), atomically: true, encoding: .utf8
        )
        let projects = configurationDirectory.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Self.alphaProjectTOML.write(
            to: projects.appending(component: "alpha.toml"), atomically: true, encoding: .utf8
        )
        app.launchEnvironment["YH_STUB_DOCTOR_ROWS"] = Self.twoInstallationsDoctorRows
    }

    func testTwoWorkspacesAreListedWithTheirNamesOperatorsAndProjects() throws {
        try writeTwoInstallations()
        showBoardsSettings(waitingFor: nil)

        let acme = element("settings-linear-workspace-acme")
        XCTAssertTrue(acme.waitForExistence(timeout: 10))
        // The workspace name read live through yh doctor; the local name stands in where none was read.
        let deadline = Date().addingTimeInterval(10)
        while !text(of: acme).contains("Acme Corp"), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(text(of: acme).contains("Acme Corp"), text(of: acme))
        let scratch = element("settings-linear-workspace-scratch")
        XCTAssertTrue(scratch.exists)
        XCTAssertTrue(text(of: scratch).contains("scratch"), text(of: scratch))

        XCTAssertTrue(text(of: element("settings-linear-operator-acme")).contains("user-op"))
        XCTAssertTrue(text(of: element("settings-linear-operator-scratch")).contains("user-old"))
        XCTAssertTrue(text(of: element("settings-linear-projects-acme")).contains("alpha"))
        let status = element("settings-linear-status-scratch")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: status).contains("revoked"), text(of: status))
        // Connecting another workspace stays on offer beside the list.
        XCTAssertTrue(element("setup-linear-install").exists)
    }

    func testReconnectRunsTheInstallForThatWorkspaceOnly() throws {
        try writeTwoInstallations()
        showBoardsSettings(waitingFor: nil)

        let reconnect = element("settings-linear-reconnect-scratch")
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10))
        reconnect.click()
        let progress = element("settings-linear-reconnect-progress-scratch")
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertTrue(element("setup-linear-installed").waitForExistence(timeout: 10))

        let recorded = recordedArguments()
        XCTAssertEqual(recorded.count, 1, "\(recorded)")
        let line = recorded.first ?? ""
        XCTAssertTrue(line.contains("setup --install-linear --events json --installation scratch"), line)
        XCTAssertFalse(line.contains("--remote"), line)
    }

    /// `acme`'s doctor rows with its authorization refused, or unreachable, by Linear (OQ121's live check).
    private static func acmeAuthorizationRows(_ state: String, message: String) -> String {
        """
        [{"check":"linear","installation":"acme","message":"\(message)","projects":["alpha"],\
        "severity":"failure","subject":"authorization","workspace":"workspace-1","authorization":"\(state)"},\
        {"check":"linear","installation":"scratch","message":"ok","projects":[],\
        "severity":"pass","subject":"authorization","workspace":"workspace-2","authorization":"authorized"}]
        """
    }

    func testRemoveIsDisabledWhileAProjectUsesTheWorkspace() throws {
        try writeTwoInstallations()
        showBoardsSettings(waitingFor: nil)

        let remove = element("settings-linear-remove-acme")
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        XCTAssertFalse(remove.isEnabled)
        // The disabled reason is the refusal, naming the Project.
        let blocked = element("settings-linear-remove-blocked-acme")
        XCTAssertTrue(blocked.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: blocked).contains("alpha"), text(of: blocked))
        // acme still authorizes, so nothing overrides the refusal.
        XCTAssertTrue(element("settings-linear-status-acme").waitForExistence(timeout: 10))
        XCTAssertFalse(element("settings-linear-remove-anyway-acme").exists)
        // An unused workspace is still removable.
        XCTAssertTrue(element("settings-linear-remove-scratch").isEnabled)
    }

    func testRemoveAnywayRunsTheOrphanRemovalWhenLinearRefusesTheWorkspace() throws {
        try writeTwoInstallations()
        app.launchEnvironment["YH_STUB_DOCTOR_ROWS"] = Self.acmeAuthorizationRows(
            "refused", message: "installation acme: revoked"
        )
        showBoardsSettings(waitingFor: nil)

        let anyway = element("settings-linear-remove-anyway-acme")
        XCTAssertTrue(anyway.waitForExistence(timeout: 10))
        XCTAssertFalse(element("settings-linear-remove-acme").isEnabled)
        anyway.click()
        // The confirmation states the undo under this exact local name before anything runs.
        let undoText = "yh setup --installation-name acme"
        let predicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", undoText, undoText)
        let undo = app.staticTexts.matching(predicate)
        XCTAssertTrue(undo.firstMatch.waitForExistence(timeout: 5))
        let confirm = app.sheets.buttons["Remove Anyway"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        XCTAssertTrue(element("settings-linear-removed").waitForExistence(timeout: 10))
        XCTAssertTrue(
            recordedArguments().contains("config remove-installation acme --orphan-projects --yes"),
            "\(recordedArguments())"
        )
    }

    func testRemoveAnywayIsNotOfferedWhenLinearIsUnreachable() throws {
        try writeTwoInstallations()
        app.launchEnvironment["YH_STUB_DOCTOR_ROWS"] = Self.acmeAuthorizationRows(
            "unreachable", message: "installation acme: Linear could not be reached"
        )
        showBoardsSettings(waitingFor: nil)

        let status = element("settings-linear-status-acme")
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(text(of: status).contains("could not be reached"), text(of: status))
        XCTAssertFalse(element("settings-linear-remove-anyway-acme").exists)
        XCTAssertFalse(element("settings-linear-remove-acme").isEnabled)
    }

    func testConnectAnotherPassesTheLocalName() {
        showBoardsSettings()
        let field = element("setup-linear-installation-name")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("acme-two")
        installLocally()
        XCTAssertTrue(element("setup-linear-installed").waitForExistence(timeout: 10))

        let line = recordedArguments().first ?? ""
        XCTAssertTrue(line.contains("setup --install-linear --events json --installation-name acme-two"), line)
    }

    func testRemoveOfAnUnusedWorkspaceSaysItStaysInstalledInLinear() throws {
        try writeTwoInstallations()
        showBoardsSettings(waitingFor: nil)

        let remove = element("settings-linear-remove-scratch")
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.click()
        let confirm = app.sheets.buttons["Remove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        let removed = element("settings-linear-removed")
        XCTAssertTrue(removed.waitForExistence(timeout: 10))
        XCTAssertTrue(text(of: removed).contains("stays installed"), text(of: removed))
        XCTAssertTrue(recordedArguments().contains("config remove-installation scratch"), "\(recordedArguments())")
    }

    /// "Change Operator…" reads that workspace's candidates and saves through `yh config operator`.
    func testChangeOperatorRecordsConfigOperatorForThatInstallation() throws {
        try writeTwoInstallations()
        showBoardsSettings(waitingFor: nil)

        let choose = element("settings-linear-operator-choose-scratch")
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.click()
        let picker = app.popUpButtons["settings-linear-operator-picker-scratch"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.click()
        let candidate = app.menuItems["Operator Person (operator)"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        candidate.click()
        let save = element("settings-linear-operator-save-scratch")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.click()

        let deadline = Date().addingTimeInterval(10)
        while !recordedArguments().contains("config operator --installation scratch user-op"), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(
            recordedArguments().contains("config operator --installation scratch user-op"), "\(recordedArguments())"
        )
    }
}
