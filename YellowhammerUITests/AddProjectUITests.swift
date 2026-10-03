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
/// works across the container boundary. The stub itself writes nothing, for the same reason: a file its
/// child process (also inside the runner's container by inheritance) tried to create would hit the same
/// wall, so every result crosses back to the test only via the stub's stdout, which the app streams into
/// the wizard's own run log.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class AddProjectUITests: XCTestCase {
    private var configurationDirectory: URL!
    var app: XCUIApplication!
    /// Real, unsandboxed `/tmp` paths (never inside the UI test runner's own container, which the
    /// app-spawned stub cannot write into): the stub's only cross-invocation state, for the
    /// ports-busy-then-retry scenario.
    private var installedMarker: URL!
    private var attemptsMarker: URL!
    private var checkedMarker: URL!

    /// The one folder every pick returns. It need not exist: the stub `yh` never reads it.
    static let pickedFolder = "/tmp/acme-backend"

    /// A machine file with every machine-wide prerequisite but the Linear installation: an Operator
    /// identity, and a declared agent CLI with a route.
    private static let readyMachineTOML = """
    [linear]
    credential = "keychain:linear"
    operator = "user-op"
    [github]
    credential = "keychain:github"

    [cli.claude]

    [[routing]]
    route = "claude/sonnet/medium"
    """

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-setup-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)

        let stubURL = try EngineStub.write(in: stubDirectory)
        let uniqueSuffix = UUID().uuidString
        installedMarker = URL(filePath: "/tmp/yh-uitest-installed-\(uniqueSuffix)")
        attemptsMarker = URL(filePath: "/tmp/yh-uitest-attempts-\(uniqueSuffix)")
        checkedMarker = URL(filePath: "/tmp/yh-uitest-checked-\(uniqueSuffix)")

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
            "YH_STUB_CHECKED_MARKER": checkedMarker.path(percentEncoded: false)
        ]
    }

    /// `machineReady`: writes ``readyMachineTOML``, so only the Linear installation can be missing.
    /// `linearInstalled`: the stub's `doctor --check linear` reports an installation from the start.
    /// `linearInstalledOnce`: only its first `doctor --check linear` reports one; the installation is
    /// revoked after that.
    /// `portsBusyFirst`: the stub's first `--install-linear` attempt reports every port busy; the
    /// second (a Retry) installs, matching OQ94's "setup stops before the browser" then a fresh attempt.
    /// `relayUnreachable`: a `--remote` attempt fails with `relayUnreachable` instead of issuing a link
    /// (roadmap P17.9).
    private func launchApp(
        machineReady: Bool = false, linearInstalled: Bool = false, linearInstalledOnce: Bool = false,
        portsBusyFirst: Bool = false, relayUnreachable: Bool = false
    ) throws {
        if machineReady {
            try Self.readyMachineTOML.write(
                to: configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory),
                atomically: true, encoding: .utf8
            )
        }
        if linearInstalled {
            app.launchEnvironment["YH_STUB_LINEAR_INSTALLED"] = "1"
        }
        if linearInstalledOnce {
            app.launchEnvironment["YH_STUB_LINEAR_INSTALLED_ONCE"] = "1"
        }
        if portsBusyFirst {
            app.launchEnvironment["YH_STUB_PORTS_BUSY_FIRST"] = "1"
        }
        if relayUnreachable {
            app.launchEnvironment["YH_STUB_RELAY_UNREACHABLE"] = "1"
        }
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: installedMarker)
        try? FileManager.default.removeItem(at: attemptsMarker)
        try? FileManager.default.removeItem(at: checkedMarker)
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
        // The onboarding button opens the Add Project sheet, which offers the Linear installation first.
        app.buttons["open-setup"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.buttons["setup-linear-install"].waitForExistence(timeout: 10))
    }

    /// Cancelling the sheet closes it and leaves no Project file behind.
    func testCancelClosesTheSheetAndWritesNoProjectFile() throws {
        try launchApp(machineReady: true, linearInstalled: true)
        let sheet = openAddProjectSheet()
        XCTAssertTrue(element("setup-step-project").waitForExistence(timeout: 10))
        typeName("Demo")
        sheet.buttons["setup-cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        let projects = configurationDirectory.appending(component: "projects", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: projects.path(percentEncoded: false))) ?? []
        XCTAssertTrue(files.filter { $0.hasSuffix(".toml") }.isEmpty)
    }

    /// Each time the sheet opens, it starts a fresh session: it checks the Linear installation again, so
    /// a revocation made while it was closed shows up, and it keeps no draft and no step from the last
    /// time it was open (issue #218).
    func testReopeningTheSheetStartsAFreshSession() throws {
        try launchApp(machineReady: true, linearInstalledOnce: true)
        var sheet = openAddProjectSheet()
        XCTAssertTrue(element("setup-step-project").waitForExistence(timeout: 10))
        typeName("Demo")
        element("setup-step-repos").click()
        XCTAssertTrue(sheet.buttons["setup-add-repo"].waitForExistence(timeout: 5))
        sheet.buttons["setup-cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        // The installation was revoked while the sheet was closed: reopening finds it missing.
        sheet = openAddProjectSheet()
        let install = sheet.buttons["setup-linear-install"]
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        XCTAssertFalse(element("setup-step-project").exists)

        // Installed again, the hub opens on the Project step with an empty name.
        install.click()
        let name = app.textFields["setup-project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "")
    }

    /// The Settings window's Sidebar offers Add Project too.
    func testAddProjectFromSettingsOpensTheSheet() throws {
        try launchApp()
        let sheet = openAddProjectSheetFromSettings()
        XCTAssertTrue(sheet.buttons["setup-linear-install"].waitForExistence(timeout: 10))
        sheet.buttons["setup-cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    }

    // MARK: - Readiness

    /// A Mac with nothing set up blocks Add Project: one row per missing prerequisite, the Linear one
    /// fixed in place and the other two sent to Settings. Installing Linear clears only its own row.
    func testReadinessBlocksAddProjectUntilEveryPrerequisiteIsPresent() throws {
        try launchApp()
        let sheet = openAddProjectSheet()
        XCTAssertTrue(sheet.buttons["setup-linear-install"].waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.buttons["setup-open-settings-operatorIdentity"].exists)
        XCTAssertTrue(sheet.buttons["setup-open-settings-agentCLIRoute"].exists)
        XCTAssertFalse(element("setup-step-project").exists)
        XCTAssertFalse(sheet.buttons["setup-add-project"].isEnabled)

        sheet.buttons["setup-linear-install"].click()
        XCTAssertTrue(sheet.buttons["setup-linear-install"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(sheet.buttons["setup-open-settings-operatorIdentity"].exists)
        XCTAssertTrue(sheet.buttons["setup-open-settings-agentCLIRoute"].exists)
        XCTAssertFalse(element("setup-step-project").exists)
        XCTAssertFalse(sheet.buttons["setup-add-project"].isEnabled)
    }

    /// P17.7: with only the Linear installation missing, installing it in place opens the hub.
    func testInstallingLinearInPlaceOpensTheHub() throws {
        try launchApp(machineReady: true)
        let sheet = openAddProjectSheet()

        let installButton = sheet.buttons["setup-linear-install"]
        XCTAssertTrue(installButton.waitForExistence(timeout: 10))
        XCTAssertFalse(sheet.buttons["setup-open-settings-operatorIdentity"].exists)
        XCTAssertFalse(sheet.buttons["setup-open-settings-agentCLIRoute"].exists)
        installButton.click()

        XCTAssertTrue(element("setup-step-project").waitForExistence(timeout: 10))
    }

    /// P17.7, OQ94: all three ports busy stops before the browser and offers Retry; a Retry re-runs
    /// the attempt, which the stub then reports installed.
    func testLinearPortsBusyThenRetryInstalls() throws {
        try launchApp(machineReady: true, portsBusyFirst: true)
        let sheet = openAddProjectSheet()

        let installButton = sheet.buttons["setup-linear-install"]
        XCTAssertTrue(installButton.waitForExistence(timeout: 10))
        installButton.click()

        let portsBusy = sheet.staticTexts["setup-linear-ports-busy"]
        XCTAssertTrue(portsBusy.waitForExistence(timeout: 10))
        let retryButton = sheet.buttons["setup-linear-retry"]
        XCTAssertTrue(retryButton.exists)
        retryButton.click()

        XCTAssertTrue(element("setup-step-project").waitForExistence(timeout: 10))
    }

    /// P17.9: requesting remote approval shows the approval link and a waiting indicator, then opens the
    /// hub once the stub reports `installed`.
    func testLinearRemoteApprovalShowsLinkThenInstalls() throws {
        try launchApp(machineReady: true)
        let sheet = openAddProjectSheet()

        let requestButton = sheet.buttons["setup-linear-request-remote"]
        XCTAssertTrue(requestButton.waitForExistence(timeout: 10))
        requestButton.click()

        let link = sheet.staticTexts["setup-linear-approval-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        let linkText = link.value as? String ?? link.label
        XCTAssertTrue(linkText.contains("https://app.yellowhammer.dev/install/test-session"))
        // A `ProgressView`, not a static text: matched by identifier across element types.
        XCTAssertTrue(
            sheet.descendants(matching: .any)["setup-linear-awaiting-remote"].waitForExistence(timeout: 10)
        )

        XCTAssertTrue(element("setup-step-project").waitForExistence(timeout: 10))
    }

    /// P17.9: a relay the Mac cannot reach offers both a retry and a local sign-in; the local sign-in
    /// installs.
    func testLinearRelayUnreachableOffersRetryAndLocalSignIn() throws {
        try launchApp(machineReady: true, relayUnreachable: true)
        let sheet = openAddProjectSheet()

        let requestButton = sheet.buttons["setup-linear-request-remote"]
        XCTAssertTrue(requestButton.waitForExistence(timeout: 10))
        requestButton.click()

        let retryButton = sheet.buttons["setup-linear-retry"]
        let installButton = sheet.buttons["setup-linear-install"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 10))
        XCTAssertTrue(installButton.exists)

        installButton.click()

        XCTAssertTrue(element("setup-step-project").waitForExistence(timeout: 10))
    }

    // MARK: - Adding a Project

    func testWizardDrivesSetupToCompletion() throws {
        try launchApp(machineReady: true, linearInstalled: true)
        driveHubToCompletion(in: openAddProjectSheet())
    }

    func testWizardAddsAProjectFromTheSettingsSidebar() throws {
        try launchApp(machineReady: true, linearInstalled: true)
        driveHubToCompletion(in: openAddProjectSheetFromSettings())
    }

    /// A Mac whose machine file is ready but has no Project yet shows the onboarding view, whose button
    /// opens the same sheet.
    func testWizardAddsAProjectFromOnboarding() throws {
        try launchApp(machineReady: true, linearInstalled: true)
        let onboarding = app.buttons["open-setup"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10))
        onboarding.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        driveHubToCompletion(in: sheet)
    }
}
