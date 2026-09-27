import Foundation
import XCTest

/// The Setup wizard driven end to end against a stub `yh`, since the real `yh setup` needs a live Linear
/// workspace and the Keychain (P14.2). The stub answers `--print-choices` with a canned choices line and,
/// for `--init`, echoes every argument it was run with (as `argv: <arg>`) so the test can assert on the
/// app's argument-building contract without touching Linear or an account.
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
final class SetupWizardUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var app: XCUIApplication!
    /// Real, unsandboxed `/tmp` paths (never inside the UI test runner's own container, which the
    /// app-spawned stub cannot write into): the stub's only cross-invocation state, for the
    /// ports-busy-then-retry scenario.
    private var installedMarker: URL!
    private var attemptsMarker: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-setup-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)

        let stubURL = try Self.writeStub(in: stubDirectory)
        let uniqueSuffix = UUID().uuidString
        installedMarker = URL(filePath: "/tmp/yh-uitest-installed-\(uniqueSuffix)")
        attemptsMarker = URL(filePath: "/tmp/yh-uitest-attempts-\(uniqueSuffix)")

        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-YellowhammerEngineStub", stubURL.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launchEnvironment = [
            "YH_STUB_INSTALLED_MARKER": installedMarker.path(percentEncoded: false),
            "YH_STUB_ATTEMPTS_MARKER": attemptsMarker.path(percentEncoded: false)
        ]
    }

    /// `portsBusyFirst`: the stub's first `--install-linear` attempt reports every port busy; the
    /// second (a Retry) installs, matching OQ94's "setup stops before the browser" then a fresh attempt.
    private func launchApp(portsBusyFirst: Bool = false) {
        if portsBusyFirst {
            app.launchEnvironment["YH_STUB_PORTS_BUSY_FIRST"] = "1"
        }
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: installedMarker)
        try? FileManager.default.removeItem(at: attemptsMarker)
    }

    func testWizardDrivesSetupToCompletion() throws {
        launchApp()
        let setup = try enterLinearAndPickOperator()
        let continueButton = setup.buttons["setup-continue"]

        // Step 3: Agent CLIs and Routing Table.
        let claudeToggle = setup.checkBoxes["claude"]
        XCTAssertTrue(claudeToggle.waitForExistence(timeout: 5))
        claudeToggle.click()
        let route = setup.textFields["setup-route"]
        route.click()
        route.typeText("claude/sonnet/medium")
        continueButton.click()

        // Step 4: Project (declared by default, since no Project is configured).
        let projectID = setup.textFields["setup-project-id"]
        XCTAssertTrue(projectID.waitForExistence(timeout: 5))
        clickAndType(projectID, "demo")
        clickAndType(setup.textFields["setup-linear-project-id"], "proj-1")
        clickAndType(setup.textFields["setup-repo-name"].firstMatch, "backend")
        clickAndType(setup.textFields["setup-repo-role"].firstMatch, "spec")
        clickAndType(setup.textFields["setup-repo-path"].firstMatch, "~/dev/backend")
        // The check field sits below the fold at this window size: scroll the form to it first.
        let check = setup.textFields["setup-repo-check"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        setup.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -1000)
        clickAndType(check, "none")
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.click()

        // Step 5: Scheduled jobs — "Install" is the default selection.
        XCTAssertTrue(setup.radioButtons.firstMatch.waitForExistence(timeout: 5))
        continueButton.click()

        // Step 6: Review and run.
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.click()

        let success = setup.staticTexts["setup-success"]
        XCTAssertTrue(success.waitForExistence(timeout: 10))

        let notificationLines = setup.staticTexts.matching(identifier: "setup-notification-status")
        XCTAssertEqual(notificationLines.count, 1)

        let log = setup.staticTexts["setup-run-log"]
        XCTAssertTrue(log.exists)
        let recorded = argv(in: (log.value as? String) ?? "")
        XCTAssertTrue(recorded.contains("--init"))
        XCTAssertEqual(value(after: "--operator", in: recorded), "user-op")
        XCTAssertEqual(value(after: "--project", in: recorded), "demo") // glossary:ignore GL001
        XCTAssertEqual(value(after: "--repo", in: recorded), "backend,spec,~/dev/backend,none")
        XCTAssertTrue(recorded.contains("--install-jobs"))
    }

    func testOperatorStepContinueIsDisabledUntilACandidateIsPicked() throws {
        launchApp()
        openSetupWindow()
        let setup = app.windows["Setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))

        try enterLinearStep(in: setup)
        let continueButton = setup.buttons["setup-continue"]

        let operatorPicker = setup.popUpButtons["setup-operator-picker"]
        XCTAssertTrue(operatorPicker.waitForExistence(timeout: 10))
        XCTAssertFalse(continueButton.isEnabled)

        operatorPicker.click()
        setup.menuItems["Operator Person (operator)"].click()
        XCTAssertTrue(continueButton.isEnabled)
    }

    /// P17.7: an installed attempt shows the workspace name and enables Continue.
    func testLinearInstalledShowsWorkspaceNameAndEnablesContinue() throws {
        launchApp()
        openSetupWindow()
        let setup = app.windows["Setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))

        let installButton = setup.buttons["setup-linear-install"]
        XCTAssertTrue(installButton.waitForExistence(timeout: 10))
        installButton.click()

        let installed = setup.staticTexts["setup-linear-installed"]
        XCTAssertTrue(installed.waitForExistence(timeout: 10))
        XCTAssertTrue((installed.value as? String ?? installed.label).contains("Acme"))
        XCTAssertTrue(setup.buttons["setup-continue"].isEnabled)
    }

    /// P17.7, OQ94: all three ports busy stops before the browser and offers Retry; a Retry re-runs
    /// the attempt, which the stub then reports installed.
    func testLinearPortsBusyThenRetryInstalls() throws {
        launchApp(portsBusyFirst: true)
        openSetupWindow()
        let setup = app.windows["Setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))

        let installButton = setup.buttons["setup-linear-install"]
        XCTAssertTrue(installButton.waitForExistence(timeout: 10))
        installButton.click()

        let portsBusy = setup.staticTexts["setup-linear-ports-busy"]
        XCTAssertTrue(portsBusy.waitForExistence(timeout: 10))
        let retryButton = setup.buttons["setup-linear-retry"]
        XCTAssertTrue(retryButton.exists)
        retryButton.click()

        let installed = setup.staticTexts["setup-linear-installed"]
        XCTAssertTrue(installed.waitForExistence(timeout: 10))
    }

    /// Opens the Setup window and drives it through the Linear step and the Operator identity step,
    /// picking the stub's one candidate. Shared by both tests.
    private func enterLinearAndPickOperator() throws -> XCUIElement {
        openSetupWindow()
        let setup = app.windows["Setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        try enterLinearStep(in: setup)

        let continueButton = setup.buttons["setup-continue"]
        let operatorPicker = setup.popUpButtons["setup-operator-picker"]
        XCTAssertTrue(operatorPicker.waitForExistence(timeout: 10))
        operatorPicker.click()
        setup.menuItems["Operator Person (operator)"].click()
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.click()
        return setup
    }

    private func enterLinearStep(in setup: XCUIElement) throws {
        // The stub's `doctor --check linear --json` answers "no Installation" first (see
        // `writeStub`), so the browser-install button appears once the check completes.
        let installButton = setup.buttons["setup-linear-install"]
        XCTAssertTrue(installButton.waitForExistence(timeout: 10))
        installButton.click()

        let installed = setup.staticTexts["setup-linear-installed"]
        XCTAssertTrue(installed.waitForExistence(timeout: 10))

        let continueButton = setup.buttons["setup-continue"]
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.click()
    }

    /// Every `argv: <arg>` line the stub echoed, in order.
    private func argv(in log: String) -> [String] {
        log.split(separator: "\n")
            .filter { $0.hasPrefix("argv: ") }
            .map { String($0.dropFirst("argv: ".count)) }
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func openSetupWindow() {
        let button = app.buttons["open-setup"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
    }

    /// Clicks a text field and types into it. A short pause first lets the Project step's live
    /// validation text (which appears and disappears as fields fill in) finish reflowing the Form —
    /// otherwise a click can land on a row that has since moved.
    private func clickAndType(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        field.click()
        field.typeText(text)
    }

    /// A `sh` script, read (never exec'd) by `/bin/sh`. `--print-choices` answers with a canned
    /// ``SetupChoices`` JSON line and nothing else, so the wizard's "last non-empty line" decode still
    /// works. `--init` first drains the stdin secret line, then echoes every argument as `argv: <arg>`
    /// and prints "Setup complete." The stub writes no file.
    private static func writeStub(in directory: URL) throws -> URL {
        let script = "#!/bin/sh\nshift\ncase \"$1\" in\n"
            + printChoicesCase + initCase + checkCase + installLinearCase
            + "  *)\n    exit 1\n    ;;\nesac\n"
        let stubURL = directory.appending(component: "yh.sh", directoryHint: .notDirectory)
        try script.write(to: stubURL, atomically: true, encoding: .utf8)
        return stubURL
    }

    private static let printChoicesCase = """
          --print-choices)
            echo '{"operatorCandidates":[{"id":"user-op","name":"operator","displayName":"Operator Person"}],\
        "configuredOperator":null,"teams":[{"id":"team-1","key":"ENG","name":"Engineering"}],\
        "cliAdapters":["claude","codex"]}'
            exit 0
            ;;

        """

    private static let initCase = """
          --init)
            read -r _
            for arg in "$@"; do
              echo "argv: $arg"
            done
            echo "Setup complete."
            exit 0
            ;;

        """

    /// `yh doctor --check linear --json`: "installed" once the install marker exists, else "not
    /// installed" — the app's Linear step polls this on appearing.
    private static let checkCase = """
          --check)
            if [ -f "$YH_STUB_INSTALLED_MARKER" ]; then
              echo '[{"check":"linear","subject":"authorization","severity":"pass","message":"ok"}]'
            else
              echo '[{"check":"linear","subject":"installation","severity":"failure","message":"no pair"}]'
            fi
            exit 0
            ;;

        """

    /// `yh setup --install-linear --events json`: the first attempt reports every port busy when
    /// `YH_STUB_PORTS_BUSY_FIRST` is set (a Retry test); every later attempt installs.
    private static let installLinearCase = """
          --install-linear)
            count_file="$YH_STUB_ATTEMPTS_MARKER"
            count=0
            [ -f "$count_file" ] && count=$(cat "$count_file")
            count=$((count + 1))
            echo "$count" > "$count_file"
            echo '{"event":"adminStatement","text":"An admin must approve."}'
            if [ "$count" -eq 1 ] && [ -n "$YH_STUB_PORTS_BUSY_FIRST" ]; then
              echo '{"event":"portsBusy","ports":[{"port":44837,"pid":123,"command":"Fugu"}],"text":"all busy"}'
              echo '{"event":"failed","reason":"portsBusy","text":"all busy"}'
              exit 1
            fi
            echo '{"event":"browserOpened","url":"https://linear.app/oauth/authorize"}'
            echo '{"event":"awaitingApproval"}'
            echo '{"event":"installed","workspaceName":"Acme"}'
            touch "$YH_STUB_INSTALLED_MARKER"
            exit 0
            ;;

        """
}
