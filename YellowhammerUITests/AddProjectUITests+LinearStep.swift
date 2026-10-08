import Foundation
import XCTest

/// The Add Project wizard's Linear step (roadmap L3.2): choosing the Linear workspace (a Board Connection
/// in `config.toml`'s registry), connecting one in place, and the Operator identity of a freshly connected
/// entry. Split from `AddProjectUITests` to keep both under SwiftLint's length limits.
///
/// Whether a workspace row is selected is read from its effect, not from the row's own selected trait: with
/// a workspace chosen, the Linear project block replaces "Choose the Linear workspace first." and its
/// `setup-linear-project-id` field appears. Tests that rely on it never select another workspace first.
extension AddProjectUITests {
    /// Zero installations is a valid machine file: the Linear step then goes straight to connecting.
    static let noInstallationMachineTOML = """
    [code_hosting.github.connections.github]
    type = "keychain"
    credential = "keychain:github"

    [cli.claude]

    [[routing]]
    route = "claude/sonnet/medium"
    """

    /// One workspace with an Operator identity, a declared agent CLI and a route.
    static let readyMachineTOML = """
    [board.linear.connections.acme]
    credential = "keychain:linear"
    workspace = "workspace-1"
    yellowhammer_identity = "app-user-1"
    operator = "user-op"
    [code_hosting.github.connections.github]
    type = "keychain"
    credential = "keychain:github"

    [cli.claude]

    [[routing]]
    route = "claude/sonnet/medium"
    """

    static let twoInstallationsMachineTOML = """
    [board.linear.connections.acme]
    credential = "keychain:linear-acme"
    workspace = "workspace-1"
    yellowhammer_identity = "app-user-1"
    operator = "user-op"
    [board.linear.connections.scratch]
    credential = "keychain:linear-scratch"
    workspace = "workspace-2"
    yellowhammer_identity = "app-user-2"
    operator = "user-op"
    [code_hosting.github.connections.github]
    type = "keychain"
    credential = "keychain:github"

    [cli.claude]

    [[routing]]
    route = "claude/sonnet/medium"
    """

    // MARK: - Helpers

    /// The argument vectors the stub recorded, one per run.
    func recordedArguments() -> [String] {
        let contents = (try? String(contentsOf: argvLog, encoding: .utf8)) ?? ""
        return contents.split(separator: "\n").map(String.init)
    }

    func waitForRecorded(_ predicate: (String) -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recordedArguments().contains(where: predicate) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return recordedArguments().contains(where: predicate)
    }

    /// Opens the sheet and its Linear step.
    @discardableResult
    func openLinearStep() -> XCUIElement {
        let sheet = openAddProjectSheet()
        let step = element("setup-step-board")
        XCTAssertTrue(step.waitForExistence(timeout: 10))
        step.click()
        return sheet
    }

    /// The workspace's row exists and is selected: the Linear project block is showing.
    func assertInstallationSelected(_ name: String, in sheet: XCUIElement) {
        XCTAssertTrue(element("setup-linear-installation-\(name)").waitForExistence(timeout: 15))
        XCTAssertTrue(sheet.textFields["setup-linear-project-id"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("setup-linear-choose-workspace-first").exists)
    }

    /// Chooses a listed workspace and waits for the Linear project block to appear.
    func selectInstallation(_ name: String, in sheet: XCUIElement) {
        let row = element("setup-linear-installation-\(name)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        assertInstallationSelected(name, in: sheet)
    }

    /// Finishes a connect the stub is running: once `--install-linear` was run, adds the entry `yh` would
    /// add to `config.toml` (no Operator identity yet), then lets the stub report it installed.
    func completeConnect(_ name: String) throws {
        XCTAssertTrue(waitForRecorded { $0.contains("--install-linear") }, "\(recordedArguments())")
        try appendToMachine("""
        [board.linear.connections.\(name)]
        credential = "keychain:linear-\(name)"
        workspace = "workspace-\(name)"
        yellowhammer_identity = "app-user-\(name)"
        """)
        openGate("install")
    }

    /// Picks the stub's only Operator candidate for a freshly connected workspace, which saves it. The
    /// candidate fetch starts by itself after a connect, so the picker appears without a click. The identity is written
    /// at the end of `config.toml`, which is the connected entry's table, as `yh config operator` would.
    func chooseOperator(for name: String) throws {
        let picker = app.popUpButtons["setup-linear-operator-picker-\(name)"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.click()
        let candidate = app.menuItems["Operator Person (operator)"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        candidate.click()
        let expected = "config operator --board-connection \(name) user-op"
        XCTAssertTrue(waitForRecorded { $0 == expected }, "\(recordedArguments())")
        try appendToMachine(#"operator = "user-op""#)
        openGate("operator")
        // The step shows the Operator row only while the selected entry has no identity.
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10))
    }

    // MARK: - Empty registry

    /// With no installation, the step shows the connect view at once: no "connect another" choice and no
    /// workspace row. Connecting selects the new entry and asks for its Operator identity; the hub then
    /// completes with `--board-connection acme`.
    func testEmptyRegistryGoesStraightToConnecting() throws {
        try launchApp(machine: Self.noInstallationMachineTOML)
        let sheet = openLinearStep()
        let install = sheet.buttons["setup-linear-install"]
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        XCTAssertFalse(sheet.buttons["setup-linear-connect-another"].exists)
        XCTAssertFalse(element("setup-linear-installation-acme").exists)
        XCTAssertFalse(sheet.textFields["setup-linear-project-id"].exists)

        install.click()
        try completeConnect("acme")
        assertInstallationSelected("acme", in: sheet)
        try chooseOperator(for: "acme")

        driveHubToCompletion(in: sheet, installation: "acme", choosesInstallation: false)
        assertProjectRowInBothSidebars("demo")
    }

    // MARK: - Choosing a listed workspace

    /// Both workspaces are listed and neither is preselected; choosing `scratch` reads its teams and Linear
    /// projects with `--board-connection scratch`, and the Project is added to it.
    func testChoosingAListedInstallation() throws {
        try launchApp(machine: Self.twoInstallationsMachineTOML)
        let sheet = openLinearStep()
        XCTAssertTrue(element("setup-linear-installation-acme").waitForExistence(timeout: 10))
        let scratch = element("setup-linear-installation-scratch")
        XCTAssertTrue(scratch.exists)
        XCTAssertTrue(element("setup-linear-choose-workspace-first").exists)
        XCTAssertFalse(sheet.textFields["setup-linear-project-id"].exists)
        XCTAssertFalse(recordedArguments().contains { $0.contains("--print-choices") })

        scratch.click()
        assertInstallationSelected("scratch", in: sheet)
        XCTAssertTrue(
            waitForRecorded { $0.contains("--print-choices") && $0.contains("--board-connection scratch") },
            "\(recordedArguments())"
        )

        driveHubToCompletion(in: sheet, installation: "scratch", choosesInstallation: false)
        assertProjectRowInBothSidebars("demo")
    }

    // MARK: - Connecting another

    /// "Connect another Linear workspace…" reveals the connect view; the new entry `beta` is listed and
    /// selected, and gets its Operator identity. Cancelling the sheet does not undo the connect: the reopened
    /// sheet lists it.
    func testConnectingAnotherSelectsItAndSurvivesCancel() throws {
        try launchApp(machine: Self.readyMachineTOML, connectName: "beta")
        var sheet = openLinearStep()
        XCTAssertTrue(element("setup-linear-installation-acme").waitForExistence(timeout: 10))
        XCTAssertFalse(sheet.buttons["setup-linear-install"].exists)
        let connectAnother = sheet.buttons["setup-linear-connect-another"]
        XCTAssertTrue(connectAnother.exists)
        connectAnother.click()
        let install = sheet.buttons["setup-linear-install"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        install.click()
        try completeConnect("beta")

        assertInstallationSelected("beta", in: sheet)
        try chooseOperator(for: "beta")

        sheet.buttons["setup-cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        sheet = openLinearStep()
        XCTAssertTrue(element("setup-linear-installation-beta").waitForExistence(timeout: 10))
        XCTAssertTrue(element("setup-linear-installation-acme").exists)
    }

    // MARK: - Connecting in the empty step

    /// P17.7, OQ94: all three ports busy stops before the browser and offers Retry; a Retry re-runs the
    /// attempt, which the stub then reports installed, and the new workspace is selected.
    func testLinearPortsBusyThenRetryInstalls() throws {
        try launchApp(machine: Self.noInstallationMachineTOML, portsBusyFirst: true)
        let sheet = openLinearStep()

        let installButton = sheet.buttons["setup-linear-install"]
        XCTAssertTrue(installButton.waitForExistence(timeout: 10))
        installButton.click()

        let portsBusy = sheet.staticTexts["setup-linear-ports-busy"]
        XCTAssertTrue(portsBusy.waitForExistence(timeout: 10))
        let retryButton = sheet.buttons["setup-linear-retry"]
        XCTAssertTrue(retryButton.exists)
        retryButton.click()
        try completeConnect("acme")

        assertInstallationSelected("acme", in: sheet)
    }

    /// P17.9: requesting remote approval shows the approval link and a waiting indicator, then the new
    /// workspace (`scratch`, the stub's remote default) is selected once the stub reports `installed`.
    func testLinearRemoteApprovalShowsLinkThenInstalls() throws {
        try launchApp(machine: Self.noInstallationMachineTOML)
        let sheet = openLinearStep()

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
        try completeConnect("scratch")

        assertInstallationSelected("scratch", in: sheet)
    }

    /// P17.9: a relay the Mac cannot reach offers both a retry and a local sign-in; the local sign-in
    /// installs, and the new workspace (`acme`) is selected.
    func testLinearRelayUnreachableOffersRetryAndLocalSignIn() throws {
        try launchApp(machine: Self.noInstallationMachineTOML, relayUnreachable: true)
        let sheet = openLinearStep()

        let requestButton = sheet.buttons["setup-linear-request-remote"]
        XCTAssertTrue(requestButton.waitForExistence(timeout: 10))
        requestButton.click()

        let retryButton = sheet.buttons["setup-linear-retry"]
        let installButton = sheet.buttons["setup-linear-install"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 10))
        XCTAssertTrue(installButton.exists)

        installButton.click()
        try completeConnect("acme")

        assertInstallationSelected("acme", in: sheet)
    }

    // MARK: - Verification of pasted Linear project id

    /// Typing an unlisted Linear project id shows "Not verified yet" and enables Verify;
    /// verifying it queries Linear via yh setup --print-choices --linear-project, shows
    /// the verified project name and team, and disables Verify.
    func testVerifyPastedLinearProjectID() throws {
        try launchApp(machine: Self.readyMachineTOML)
        let sheet = openLinearStep()
        selectInstallation("acme", in: sheet)

        let linearID = sheet.textFields["setup-linear-project-id"]
        XCTAssertTrue(linearID.waitForExistence(timeout: 10))
        let verifyButton = sheet.buttons["setup-linear-verify"]
        XCTAssertTrue(verifyButton.waitForExistence(timeout: 5))
        XCTAssertFalse(verifyButton.isEnabled)

        linearID.click()
        linearID.typeText("proj-1")
        XCTAssertTrue(verifyButton.isEnabled)
        XCTAssertTrue(element("setup-linear-result-unchecked").waitForExistence(timeout: 5))

        verifyButton.click()
        XCTAssertTrue(element("setup-linear-result-verified").waitForExistence(timeout: 10))
        XCTAssertFalse(verifyButton.isEnabled)
        XCTAssertTrue(
            waitForRecorded { $0.contains("--linear-project proj-1") },
            "\(recordedArguments())"
        )
    }

    /// Verifying an id not found in the workspace shows the not-found error and leaves Verify enabled.
    func testVerifyPastedLinearProjectIDNotFound() throws {
        try launchApp(machine: Self.readyMachineTOML)
        let sheet = openLinearStep()
        selectInstallation("acme", in: sheet)

        let linearID = sheet.textFields["setup-linear-project-id"]
        XCTAssertTrue(linearID.waitForExistence(timeout: 10))
        let verifyButton = sheet.buttons["setup-linear-verify"]

        linearID.click()
        linearID.typeText("proj-not-found")
        verifyButton.click()

        XCTAssertTrue(element("setup-linear-result-not-found").waitForExistence(timeout: 10))
        XCTAssertTrue(verifyButton.isEnabled)
    }

    /// Verifying an id where Yellowhammer lacks team membership shows the team-access error.
    func testVerifyPastedLinearProjectIDNoTeamAccess() throws {
        try launchApp(machine: Self.readyMachineTOML)
        let sheet = openLinearStep()
        selectInstallation("acme", in: sheet)

        let linearID = sheet.textFields["setup-linear-project-id"]
        XCTAssertTrue(linearID.waitForExistence(timeout: 10))
        let verifyButton = sheet.buttons["setup-linear-verify"]

        linearID.click()
        linearID.typeText("proj-no-access")
        verifyButton.click()

        XCTAssertTrue(element("setup-linear-result-no-team-access").waitForExistence(timeout: 10))
        XCTAssertTrue(verifyButton.isEnabled)
    }

    /// Editing the id un-verifies it; picking a listed Linear project is verified without clicking Verify.
    func testEditingLinearProjectIDUnverifiesAndPickingListedVerifies() throws {
        try launchApp(machine: Self.readyMachineTOML)
        let sheet = openLinearStep()
        selectInstallation("acme", in: sheet)

        // Picking a listed project counts as verified immediately
        let listedRow = element("setup-linear-project-proj-listed")
        XCTAssertTrue(listedRow.waitForExistence(timeout: 10))
        listedRow.click()

        let verifyButton = sheet.buttons["setup-linear-verify"]
        XCTAssertTrue(element("setup-linear-result-verified").waitForExistence(timeout: 5))
        XCTAssertFalse(verifyButton.isEnabled)

        // Editing the text field un-verifies
        let linearID = sheet.textFields["setup-linear-project-id"]
        linearID.click()
        linearID.typeText("-edited")
        XCTAssertTrue(element("setup-linear-result-unchecked").waitForExistence(timeout: 5))
        XCTAssertTrue(verifyButton.isEnabled)
    }
}
