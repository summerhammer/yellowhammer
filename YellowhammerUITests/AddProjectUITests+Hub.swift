import Foundation
import XCTest

/// `AddProjectUITests`' hub drive and its small helpers, split out to keep the suite under SwiftLint's
/// length limits.
extension AddProjectUITests {
    /// Fills every step through the hub, in an order no linear wizard would take, then confirms and runs
    /// setup and checks the `yh setup --init` argument vector. `beforeAdding` runs on the filled hub, just
    /// before Add Project; `checkArguments` gets the recorded argument vector. `installation` is the Linear
    /// workspace the Linear step chooses; `choosesInstallation: false` skips the click when a test already
    /// selected it (a workspace just connected in the step is selected by the wizard).
    func driveHubToCompletion(
        in sheet: XCUIElement, installation: String = "acme", choosesInstallation: Bool = true,
        linearProject: String = "proj-1", // glossary:ignore GL001
        beforeAdding: () -> Void = {}, checkArguments: ([String]) -> Void = { _ in }
    ) {
        XCTAssertTrue(element("setup-step-project").waitForExistence(timeout: 10))
        let addProject = sheet.buttons["setup-add-project"]
        // A fresh sheet continues to the next step rather than adding.
        XCTAssertFalse(addProject.exists)
        XCTAssertTrue(sheet.buttons["setup-continue"].exists)

        // Project: the id follows the name.
        element("setup-step-project").click()
        typeName("Demo")
        let projectID = element("setup-project-id")
        XCTAssertTrue(projectID.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: projectID).contains("demo"))

        // Repos before the Linear project: any step can be opened.
        element("setup-step-repos").click()
        let addRepo = sheet.buttons["setup-add-repo"]
        XCTAssertTrue(addRepo.waitForExistence(timeout: 5))
        addRepo.click()
        XCTAssertTrue(sheet.textFields["setup-repo-check"].firstMatch.waitForExistence(timeout: 5))

        // Linear workspace, then the Linear project: an existing one, by id.
        element("setup-step-board").click()
        fillLinearStep(in: sheet, installation: choosesInstallation ? installation : nil)

        // Spec Source: the picked Repo becomes the spec, which declares its Check "none".
        element("setup-step-specSource").click()
        let specRepoChoice = element("setup-spec-choice-repo")
        XCTAssertTrue(specRepoChoice.waitForExistence(timeout: 5))
        specRepoChoice.click()
        let specRepo = element("setup-spec-repo-acme-backend")
        XCTAssertTrue(specRepo.waitForExistence(timeout: 5))
        specRepo.click()

        // Bounds and the Schedule are complete at their defaults, but only once opened: until then the
        // footer offers to continue, not to add.
        XCTAssertFalse(addProject.exists && addProject.isEnabled)
        element("setup-step-bounds").click()
        let continueButton = sheet.buttons["setup-continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.click()
        beforeAdding()
        XCTAssertTrue(addProject.waitForEnabled(timeout: 5))
        addProject.click()
        let confirm = app.buttons["setup-confirm-add"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        let success = element("setup-success")
        XCTAssertTrue(success.waitForExistence(timeout: 10))
        let done = app.buttons["setup-done"]
        XCTAssertTrue(done.exists)
        XCTAssertFalse(app.buttons["setup-cancel"].exists)

        let notificationLines = app.staticTexts.matching(identifier: "setup-notification-status")
        XCTAssertEqual(notificationLines.count, 1)

        let log = app.staticTexts["setup-run-log"]
        XCTAssertTrue(log.exists)
        let recorded = argv(in: (log.value as? String) ?? "")
        assertProjectArguments(
            recorded, installation: installation, linearProject: linearProject // glossary:ignore GL001
        )
        checkArguments(recorded)

        done.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    }

    /// On the open Linear step: chooses the workspace (when `installation` is given), then types an existing
    /// Linear project's id.
    func fillLinearStep(in sheet: XCUIElement, installation: String?) {
        if let installation {
            let row = element("setup-linear-installation-\(installation)")
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.click()
        }
        let linearID = sheet.textFields["setup-linear-project-id"]
        XCTAssertTrue(linearID.waitForExistence(timeout: 5))
        linearID.click()
        linearID.typeText("proj-1")
    }

    /// The story's "completing the wizard adds the new Project's row to the main window's Sidebar … and to
    /// the Settings window's own Project sidebar". Opening Settings through the menu brings an open
    /// Settings window forward rather than opening another.
    func assertProjectRowInBothSidebars(_ id: String) {
        XCTAssertTrue(element("sidebar-\(id)").waitForExistence(timeout: 10), "no main window Sidebar row")
        app.menuBars.menuBarItems["Yellowhammer"].click()
        app.menuBars.menuItems["Settings\u{2026}"].click()
        XCTAssertTrue(
            element("settings-project-\(id)").waitForExistence(timeout: 10), "no Settings window sidebar row"
        )
    }

    /// The Project the hub drive declares, and nothing machine-wide.
    func assertProjectArguments(
        _ recorded: [String], installation: String, linearProject: String
    ) { // glossary:ignore GL001
        XCTAssertTrue(recorded.contains("--init"))
        XCTAssertEqual(value(after: "--installation", in: recorded), installation)
        XCTAssertEqual(value(after: "--project", in: recorded), "demo") // glossary:ignore GL001
        XCTAssertEqual(value(after: "--project-name", in: recorded), "Demo") // glossary:ignore GL001
        XCTAssertEqual(value(after: "--linear-project", in: recorded), linearProject) // glossary:ignore GL001
        XCTAssertEqual(value(after: "--repo", in: recorded), "acme-backend,spec,\(Self.pickedFolder),none")
        XCTAssertTrue(recorded.contains("--install-jobs"))
        // The sheet sets nothing machine-wide: setup keeps the configured Operator, CLIs and routes.
        for flag in ["--operator", "--cli", "--route", "--fallback"] {
            XCTAssertFalse(recorded.contains(flag), "\(flag) was passed")
        }
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    func typeName(_ name: String) {
        let field = app.textFields["setup-project-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(name)
    }

    /// Every `argv: <arg>` line the stub echoed, in order.
    func argv(in log: String) -> [String] {
        log.split(separator: "\n")
            .filter { $0.hasPrefix("argv: ") }
            .map { String($0.dropFirst("argv: ".count)) }
    }

    func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Opens the Add Project sheet from the main window Sidebar's "+" and returns it.
    @discardableResult
    func openAddProjectSheet() -> XCUIElement {
        let button = app.buttons["sidebar-add-project"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        return sheet
    }

    /// Opens the Add Project sheet from the Settings window Sidebar's "+" and returns it.
    func openAddProjectSheetFromSettings() -> XCUIElement {
        XCTAssertTrue(app.descendants(matching: .any)["overview-onboarding"].waitForExistence(timeout: 10))
        // The application menu's Settings item, not Cmd+,: a synthesized shortcut was dropped once while
        // the app settled, and the menu item is the same command.
        app.menuBars.menuBarItems["Yellowhammer"].click()
        app.menuBars.menuItems["Settings\u{2026}"].click()
        let add = app.descendants(matching: .any)["settings-add-project"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        return sheet
    }
}

private extension XCUIElement {
    /// Waits for the element to become enabled, polling: `isEnabled` has no expectation of its own.
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return exists && isEnabled
    }
}
