import Foundation
import XCTest

/// The Settings window's Recalibrate tab (P14.7) driven against a stub `yh`, modelled on `AgentCLIUITests`. Covers
/// that `yh recalibrate --project demo --json` is decoded and its Bounds shown with this Night's
/// proximity, and that confirming the dialog launches a rehearsal Night (`yh rehearse --project demo`)
/// without throwing, showing the started note with its log path.
///
/// Surviving the app quitting is `SetupEngine.launchDetached`'s whole point (P14.7's done-when), and
/// asserting it end-to-end is not exercised here: `xcodebuild test` attaches `testmanagerd` to the app
/// under test (visible in its test entitlements as `mach-lookup.global-name` for
/// `com.apple.dt.testmanagerd.runner`), and that supervision reaps a `posix_spawn`'d, `SETSID`-detached
/// grandchild within about a second regardless of whether the app itself quits — confirmed by dropping
/// the stub's `sleep` to zero, which still lost the process, while the identical spawn survives a real
/// `kill -9` of the app when launched outside `xcodebuild test` (see the PR description for the manual
/// repro). This is a stronger version of the same sandboxing boundary `ConfigurationEditingUITests` and
/// `AddProjectUITests` already work around, not a defect in `launchDetached`.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class RecalibrateUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var stubDirectory: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-recalibrate-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let projectsDirectory = configurationDirectory.appending(component: "projects", directoryHint: .isDirectory)
        stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)

        try Self.machineTOML.write(
            to: configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory),
            atomically: true, encoding: .utf8
        )
        // A Project declares its rehearsal context (OQ149) except in the test that asserts what one that
        // declares none is shown.
        try Self.demoProjectTOML(rehearsal: !name.contains("Unavailable")).write(
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
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let tab = app.descendants(matching: .any)["Recalibrate"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Settings did not open on the Project")
        tab.click()
        XCTAssertTrue(app.buttons["recalibrate-refresh"].waitForExistence(timeout: 10), "Recalibrate did not open")
    }

    override func tearDown() async throws {
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
    }

    func testRecalibrateShowsBoundValueAndProximity() throws {
        let value = app.textFields["recalibrate-value-review_rounds_max"]
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        XCTAssertEqual(value.value as? String, "2")

        let proximity = app.staticTexts["recalibrate-proximity-review_rounds_max"]
        XCTAssertTrue(proximity.waitForExistence(timeout: 5))
        XCTAssertEqual(proximity.value as? String, "2 of 3")
    }

    func testConfirmingLaunchesARehearsalNight() throws {
        let runButton = app.buttons["recalibrate-run-rehearsal"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 10))
        runButton.click()

        let confirm = app.buttons["recalibrate-confirm-rehearsal"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        // The started note (not the marker file below) is what this environment can prove: that
        // `launchDetached` didn't throw and computed the right log path. See the type doc for why the
        // spawned process's own survival is verified by hand instead.
        let started = app.staticTexts["recalibrate-rehearsal-started"]
        XCTAssertTrue(started.waitForExistence(timeout: 10))
        let startedText = (started.value as? String) ?? ""
        XCTAssertTrue(startedText.contains(stubDirectory.path(percentEncoded: false)), startedText)

        let showLog = app.buttons["recalibrate-show-log"]
        XCTAssertTrue(showLog.waitForExistence(timeout: 5))
    }

    /// A Project that declares no rehearsal context gets no *Run a rehearsal Night*: the button is
    /// disabled and says which declarations are missing, in `yh rehearse`'s words (OQ149).
    func testRehearsalUnavailableWithoutARehearsalContext() throws {
        let unavailable = app.staticTexts["recalibrate-rehearsal-unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        let text = (unavailable.value as? String) ?? unavailable.label
        XCTAssertTrue(text.contains("[board.linear] rehearsal_project"), text)
        XCTAssertTrue(text.contains("[rehearsal] journal"), text)
        XCTAssertFalse(app.buttons["recalibrate-run-rehearsal"].isEnabled)
    }

    private static let machineTOML = """
    [board.linear.connections.acme]
    credential = "keychain:linear"
    workspace = "workspace-1"
    yellowhammer_identity = "app-user-1"
    [github]
    credential = "keychain:github"

    [cli.claude]

    [[routing]]
    route = "claude/sonnet/medium"
    """

    /// With `rehearsal`, the Project also declares its rehearsal context: its own Linear project and a
    /// Journal outside `journals/` (the file need not exist).
    private static func demoProjectTOML(rehearsal: Bool) -> String {
        let rehearsalProject = rehearsal ? "rehearsal_project = \"DEMO-REHEARSAL\"\n" : ""
        let rehearsalTable = rehearsal ? "\n[rehearsal]\njournal = \"~/dev/demo-rehearsal.db\"\n" : ""
        return """
        id = "demo"
        name = "Demo"
        spec_source = "~/dev/demo-spec"

        [board.linear]
        connection = "acme"
        project = "DEMO"
        \(rehearsalProject)\(rehearsalTable)
        [[repos]]
        name = "backend"
        path = "~/dev/demo-backend"
        role = "backend"
        check = "swift test"
        """
    }

    /// The canned `yh recalibrate --json` line: `review_rounds_max` carries a Night's proximity (2 of
    /// its value 3); the rest carry no Night, which the model must show as "no Night recorded" without
    /// choking on the nulls.
    private static let recalibrateJSON = """
    {"project":"demo","night":{"nightStart":"2026-09-23T21:00:00Z","mode":"rehearsal","state":"settled"},\
    "bounds":[\
    {"name":"review_rounds_max","consequenceShape":"stops","consequence":"stops work on a Card",\
    "value":3,"proximity":2,"measure":"highest Rounds in an Attempt"},\
    {"name":"attempts_per_work_card","consequenceShape":"stops","consequence":"stops work on a Card",\
    "value":3,"proximity":null,"measure":null},\
    {"name":"overdue_nights_max","consequenceShape":"stops","consequence":"stops the Project",\
    "value":3,"proximity":null,"measure":null},\
    {"name":"reselections_max","consequenceShape":"stops","consequence":"stops work on a Card",\
    "value":3,"proximity":null,"measure":null},\
    {"name":"consecutive_refusals_max","consequenceShape":"stops","consequence":"stops the Project",\
    "value":3,"proximity":null,"measure":null},\
    {"name":"failed_adoptions_max","consequenceShape":"promotes","consequence":"promotes for review",\
    "value":3,"proximity":null,"measure":null}\
    ]}
    """

    /// A `sh` script, read (never exec'd) by `/bin/sh`: for `recalibrate` it echoes the canned JSON line
    /// above; `rehearse` is never actually reached under `xcodebuild test` (see the type doc), so it only
    /// needs to exit cleanly if it ever runs.
    private static func writeStub(in directory: URL) throws -> URL {
        let script = """
        #!/bin/sh
        case "$1" in
          recalibrate)
            echo '\(recalibrateJSON)'
            exit 0
            ;;
          rehearse)
            exit 0
            ;;
        esac
        """
        let stubURL = directory.appending(component: "yh.sh", directoryHint: .notDirectory)
        try script.write(to: stubURL, atomically: true, encoding: .utf8)
        return stubURL
    }
}
