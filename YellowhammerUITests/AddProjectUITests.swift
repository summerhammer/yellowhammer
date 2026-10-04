import Foundation
import XCTest

/// The Add Project sheet (the Hub4 Setup wizard) driven end to end against a stub `yh`, since the real
/// `yh setup` needs a live Linear workspace and the Keychain (P14.2, P18.17, H3.1). The stub answers
/// `--print-choices` with a canned choices line and, for `--init`, echoes every argument it was run with
/// (as `argv: <arg>`) so the test can assert on the app's argument-building contract without touching
/// Linear or an account. Folder picks come from `-YellowhammerFolderPickerStub`, not an `NSOpenPanel`.
///
/// The stub is a script read by `/bin/sh`, never exec'd directly: the UI test runner that writes it is
/// itself sandboxed, so a file it creates lives inside its own container, and the (unsandboxed) app under
/// test cannot exec anything there directly — `Process.run()` fails with EPERM regardless of permissions.
/// `/bin/sh`, a system binary, is what the app execs; `/bin/sh` then merely reads the stub file, which
/// works across the container boundary. The stub writes nothing into the runner's container, for the same
/// reason: a file its child process (also inside the runner's container by inheritance) tried to create
/// there would hit the same wall. Its results cross back via its stdout, which the app streams into the
/// wizard's own run log, and via real `/tmp` paths: the configuration's `projects` folder is a symlink
/// into `/tmp`, so the Project file the stub's `--init` writes reaches both sidebars.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class AddProjectUITests: XCTestCase {
    var configurationDirectory: URL!
    var app: XCUIApplication!
    /// Real, unsandboxed `/tmp` paths (never inside the UI test runner's own container, which the
    /// app-spawned stub cannot write into): the stub's only cross-invocation state, for the
    /// ports-busy-then-retry scenario.
    private var installedMarker: URL!
    private var attemptsMarker: URL!
    private var checkedMarker: URL!
    /// Where the stub's `--init` writes the Project file; the configuration's `projects` folder is a symlink
    /// to it, so the app finds the new Project where the real `yh setup --init` would put it.
    private var projectsDirectory: URL!
    /// The stub's argument log (`YH_STUB_ARGV_LOG`), one line per recorded `yh` call; set in every test.
    var argvLog: URL!
    /// `config/config.toml`, in the runner's container. The stub can read it but not write it, so the edits
    /// `yh` would make to it (a connected entry, a saved Operator identity) are made by the test, behind the
    /// stub's gates (`YH_STUB_GATE_DIR`, ``openGate(_:)``).
    var machineFile: URL!
    /// The stub's gate directory, in the runner's container.
    private var gateDirectory: URL!

    /// The one folder every pick returns. It need not exist: the stub `yh` never reads it.
    static let pickedFolder = "/tmp/acme-backend"

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-setup-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        gateDirectory = base.appending(component: "gates", directoryHint: .isDirectory)
        machineFile = configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gateDirectory, withIntermediateDirectories: true)

        let stubURL = try EngineStub.write(in: stubDirectory)
        let uniqueSuffix = UUID().uuidString
        installedMarker = URL(filePath: "/tmp/yh-uitest-installed-\(uniqueSuffix)")
        attemptsMarker = URL(filePath: "/tmp/yh-uitest-attempts-\(uniqueSuffix)")
        checkedMarker = URL(filePath: "/tmp/yh-uitest-checked-\(uniqueSuffix)")
        projectsDirectory = URL(filePath: "/tmp/yh-uitest-projects-\(uniqueSuffix)", directoryHint: .isDirectory)
        argvLog = URL(filePath: "/tmp/yh-uitest-argv-\(uniqueSuffix)")
        try FileManager.default.createSymbolicLink(
            at: configurationDirectory.appending(component: "projects", directoryHint: .isDirectory),
            withDestinationURL: projectsDirectory
        )

        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-YellowhammerEngineStub", stubURL.path(percentEncoded: false),
            "-YellowhammerFolderPickerStub", Self.pickedFolder,
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launchEnvironment = [
            "YH_STUB_INSTALLED_MARKER": installedMarker.path(percentEncoded: false),
            "YH_STUB_ATTEMPTS_MARKER": attemptsMarker.path(percentEncoded: false),
            "YH_STUB_CHECKED_MARKER": checkedMarker.path(percentEncoded: false),
            "YH_STUB_PROJECTS_DIR": projectsDirectory.path(percentEncoded: false),
            "YH_STUB_ARGV_LOG": argvLog.path(percentEncoded: false),
            "YH_STUB_GATE_DIR": gateDirectory.path(percentEncoded: false)
        ]
    }

    /// `machine`: the `config.toml` to start from (``readyMachineTOML`` and its siblings); nil is a Mac where
    /// Setup has never run, with no `config.toml`.
    /// `connectName`: the local name the stub's next connect reports (`YH_STUB_CONNECT_NAME`).
    /// `portsBusyFirst`: the stub's first `--install-linear` attempt reports every port busy; the
    /// second (a Retry) installs, matching OQ94's "setup stops before the browser" then a fresh attempt.
    /// `relayUnreachable`: a `--remote` attempt fails with `relayUnreachable` instead of issuing a link
    /// (roadmap P17.9).
    func launchApp(
        machine: String? = nil, connectName: String? = nil, portsBusyFirst: Bool = false,
        relayUnreachable: Bool = false
    ) throws {
        if let machine {
            try machine.write(to: machineFile, atomically: true, encoding: .utf8)
        }
        if let connectName {
            app.launchEnvironment["YH_STUB_CONNECT_NAME"] = connectName
        }
        if portsBusyFirst {
            app.launchEnvironment["YH_STUB_PORTS_BUSY_FIRST"] = "1"
        }
        if relayUnreachable {
            app.launchEnvironment["YH_STUB_RELAY_UNREACHABLE"] = "1"
        }
        app.launch()
    }

    /// Appends `text` to `config.toml` as its own lines, as the edit a gated stub run stands for.
    func appendToMachine(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: machineFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + text + "\n").utf8))
    }

    /// Lets a stub run waiting on the gate `name` finish (`EngineStub.waitForGate`).
    func openGate(_ name: String) {
        let gate = gateDirectory.appending(component: name, directoryHint: .notDirectory)
        XCTAssertTrue(FileManager.default.createFile(atPath: gate.path(percentEncoded: false), contents: nil))
    }

    override func tearDown() async throws {
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: installedMarker)
        try? FileManager.default.removeItem(at: attemptsMarker)
        try? FileManager.default.removeItem(at: checkedMarker)
        try? FileManager.default.removeItem(at: projectsDirectory)
        try? FileManager.default.removeItem(at: argvLog)
    }

    // MARK: - Opening and cancelling

    /// An empty configuration directory is a Mac where Setup has never run: the main window shows the
    /// onboarding view, not a configuration error (scope-windows-to-a-project, AC 3; issue #232).
    func testFreshInstallShowsTheOnboardingView() throws {
        try launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["overview-onboarding"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["open-setup"].exists)
        XCTAssertTrue(app.buttons["sidebar-add-project"].exists)
        XCTAssertFalse(app.staticTexts["Yellowhammer can\u{2019}t read its configuration."].exists)
        // The onboarding button opens the Add Project sheet, which asks for the agent CLI route first; the
        // Linear workspace is chosen later, in the Linear step.
        app.buttons["open-setup"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.buttons["setup-open-settings-agentCLIRoute"].waitForExistence(timeout: 10))
        XCTAssertFalse(sheet.buttons["setup-linear-install"].exists)
    }

    /// Cancelling the sheet closes it and leaves no Project file behind.
    func testCancelClosesTheSheetAndWritesNoProjectFile() throws {
        try launchApp(machine: Self.readyMachineTOML)
        let sheet = openAddProjectSheet()
        XCTAssertTrue(element("setup-step-project").waitForExistence(timeout: 10))
        typeName("Demo")
        sheet.buttons["setup-cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        let projects = configurationDirectory.appending(component: "projects", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: projects.path(percentEncoded: false))) ?? []
        XCTAssertTrue(files.filter { $0.hasSuffix(".toml") }.isEmpty)
    }

    /// Each time the sheet opens, it starts a fresh session: it keeps no draft and no step from the last
    /// time it was open (issue #218).
    func testReopeningTheSheetStartsAFreshSession() throws {
        try launchApp(machine: Self.readyMachineTOML)
        var sheet = openAddProjectSheet()
        XCTAssertTrue(element("setup-step-project").waitForExistence(timeout: 10))
        typeName("Demo")
        element("setup-step-repos").click()
        XCTAssertTrue(sheet.buttons["setup-add-repo"].waitForExistence(timeout: 5))
        sheet.buttons["setup-cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        // Reopened, the hub opens on the Project step with an empty name.
        sheet = openAddProjectSheet()
        let name = app.textFields["setup-project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "")
        XCTAssertTrue(sheet.buttons["setup-cancel"].exists)
    }

    /// The Settings window's Sidebar offers Add Project too.
    func testAddProjectFromSettingsOpensTheSheet() throws {
        try launchApp()
        let sheet = openAddProjectSheetFromSettings()
        XCTAssertTrue(sheet.buttons["setup-open-settings-agentCLIRoute"].waitForExistence(timeout: 10))
        sheet.buttons["setup-cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    }

    // MARK: - Readiness

    /// A Mac with nothing set up blocks Add Project on the agent CLI route alone: the Linear workspace and
    /// the Operator identity are chosen in the Linear step, so the panel has no row for them. The hub still
    /// shows its steps, locked, under a Prerequisites section.
    func testReadinessBlocksAddProjectUntilTheAgentCLIRouteIsPresent() throws {
        try launchApp()
        let sheet = openAddProjectSheet()
        XCTAssertTrue(sheet.buttons["setup-open-settings-agentCLIRoute"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("setup-readiness-linearInstallation").exists)
        XCTAssertFalse(element("setup-readiness-operatorIdentity").exists)
        XCTAssertFalse(sheet.buttons["setup-open-settings-operatorIdentity"].exists)
        XCTAssertFalse(sheet.buttons["setup-linear-install"].exists)
        XCTAssertTrue(element("setup-prerequisite-agentCLIRoute").exists)
        XCTAssertTrue(element("setup-step-project").exists)
        XCTAssertFalse(app.textFields["setup-project-name"].exists)
        XCTAssertFalse(sheet.buttons["setup-readiness-check-again"].exists)
        XCTAssertFalse(sheet.buttons["setup-add-project"].isEnabled)
    }

    // MARK: - Adding a Project

    func testWizardDrivesSetupToCompletion() throws {
        try launchApp(machine: Self.readyMachineTOML)
        driveHubToCompletion(in: openAddProjectSheet())
        assertProjectRowInBothSidebars("demo")
    }

    /// The Night window set in the sheet reaches `yh setup --init`; the fields left at their defaults do not.
    func testWizardPassesAnEditedNightWindow() throws {
        try launchApp(machine: Self.readyMachineTOML)
        let sheet = openAddProjectSheet()
        driveHubToCompletion(in: sheet) {
            element("setup-step-jobs").click()
            let nightStart = sheet.popUpButtons["setup-night-start"]
            XCTAssertTrue(nightStart.waitForExistence(timeout: 5))
            nightStart.click()
            sheet.menuItems["23:00"].click()
        } checkArguments: { recorded in
            XCTAssertEqual(value(after: "--night-start", in: recorded), "23:00")
            XCTAssertFalse(recorded.contains("--night-end"))
            XCTAssertFalse(recorded.contains("--build-every-minutes"))
        }
    }

    /// A Linear project `--print-choices` lists is picked in place of a pasted id.
    func testWizardPicksAListedLinearProject() throws {
        try launchApp(machine: Self.readyMachineTOML)
        let sheet = openAddProjectSheet()
        driveHubToCompletion(in: sheet, linearProject: "proj-listed") { // glossary:ignore GL001
            element("setup-step-linearProject").click()
            let listed = element("setup-linear-project-proj-listed")
            XCTAssertTrue(listed.waitForExistence(timeout: 5))
            listed.click()
        }
    }

    func testWizardAddsAProjectFromTheSettingsSidebar() throws {
        try launchApp(machine: Self.readyMachineTOML)
        driveHubToCompletion(in: openAddProjectSheetFromSettings())
        assertProjectRowInBothSidebars("demo")
    }

    /// A Mac whose machine file is ready but has no Project yet shows the onboarding view, whose button
    /// opens the same sheet.
    func testWizardAddsAProjectFromOnboarding() throws {
        try launchApp(machine: Self.readyMachineTOML)
        let onboarding = app.buttons["open-setup"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10))
        onboarding.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        driveHubToCompletion(in: sheet)
        assertProjectRowInBothSidebars("demo")
    }
}
