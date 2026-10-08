import Foundation
import XCTest

/// The wizard uses the registry and engine push verdicts; connecting survives cancellation.
extension AddProjectUITests {
    func testCodeHostingPreselectsGitHubCLIAndCanSelectAnExistingTokenConnection() throws {
        try writeCodeHostingReport(connections: [
            CodeHostingSettingsUITests.githubReportConnection, CodeHostingSettingsUITests.ghReportConnection
        ])
        try launchApp(machine: Self.readyMachineTOML + "\n" + CodeHostingSettingsUITests.ghConnectionTOML)
        _ = openAddProjectSheet()
        visitCodeHostingStep(connection: nil)
        XCTAssertTrue(waitForRecorded { $0.contains("check-code-hosting-credential --connection gh") })

        let picker = element("setup-code-hosting-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        let option = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "github ·")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.click()
        XCTAssertTrue(waitForRecorded { $0.contains("check-code-hosting-credential --connection github") })
    }

    func testConnectingDuringWizardThenCancellingKeepsTheRegistryConnection() throws {
        try writeCodeHostingReport(connections: [CodeHostingSettingsUITests.githubReportConnection])
        app.launchEnvironment["YH_STUB_CODE_HOSTING_GATES"] = "1"
        try launchApp(machine: Self.readyMachineTOML)
        let sheet = openAddProjectSheet()
        visitCodeHostingStep()
        element("setup-code-hosting-connect-another").click()
        let connect = element("settings-code-hosting-connect-gh")
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.click()
        XCTAssertTrue(waitForRecorded { $0.contains("config connect-code-hosting gh --gh-cli") })

        // The gated fixture makes the same persistent edit the engine makes before reporting success.
        try appendToMachine(CodeHostingSettingsUITests.ghConnectionTOML)
        try writeCodeHostingReport(connections: [
            CodeHostingSettingsUITests.githubReportConnection, CodeHostingSettingsUITests.ghReportConnection
        ])
        openGate("code-hosting")
        XCTAssertTrue(waitForRecorded { $0.contains("check-code-hosting-credential --connection gh") })
        sheet.buttons["setup-cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        XCTAssertTrue(try String(contentsOf: machineFile, encoding: .utf8).contains("connections.gh"))

        _ = openAddProjectSheet()
        visitCodeHostingStep(connection: nil)
        XCTAssertTrue(waitForRecorded { $0.contains("check-code-hosting-credential --connection gh") })
        XCTAssertFalse(recordedArguments().contains { $0.contains("remove-code-hosting-connection gh") })
    }

    func testPushRefusalForAWorkingRepoBlocksAddProject() throws {
        let refusalFile = configurationDirectory.deletingLastPathComponent().appending(component: "refused-repo")
        try Self.pickedFolder.write(to: refusalFile, atomically: true, encoding: .utf8)
        app.launchEnvironment["YH_STUB_CODE_HOSTING_REFUSED_REPO_FILE"] = refusalFile.path(percentEncoded: false)
        try writeSharedSpecProject()
        try launchApp(machine: Self.readyMachineTOML)
        let sheet = openAddProjectSheet()
        typeName("Demo")
        element("setup-step-repos").click()
        sheet.buttons["setup-add-repo"].click()
        let check = sheet.textFields["setup-repo-check"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        check.click()
        check.typeText("swift test")
        element("setup-step-board").click()
        fillLinearStep(in: sheet, installation: "acme")
        element("setup-step-specSource").click()
        element("setup-spec-choice-path").click()
        let sharedSpec = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "/tmp/acme-spec")).firstMatch
        XCTAssertTrue(sharedSpec.waitForExistence(timeout: 5))
        sharedSpec.click()
        visitCodeHostingStep()
        let refusal = app.staticTexts.matching(
            NSPredicate(
                format: "value CONTAINS %@ OR label CONTAINS %@",
                "refused push permission", "refused push permission"
            )
        ).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForRecorded {
            $0.contains("--connection github") && $0.contains("--github-repo \(Self.pickedFolder)")
        })
        element("setup-step-bounds").click()
        sheet.buttons["setup-continue"].click()
        element("setup-step-jobs").click()
        let add = sheet.buttons["setup-add-project"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(add.isEnabled)
        XCTAssertFalse(recordedArguments().contains { $0.contains("setup --init") })

        // The same complete draft becomes addable only when the engine grants push permission.
        try FileManager.default.removeItem(at: refusalFile)
        visitCodeHostingStep(connection: nil)
        let passing = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "the token can push"))
            .firstMatch
        XCTAssertTrue(passing.waitForExistence(timeout: 10))
        element("setup-step-jobs").click()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isEnabled)
    }

    /// This test reads a fixture Project only; keep it in the runner's writable container.
    private func writeSharedSpecProject() throws {
        let projects = configurationDirectory.appending(component: "projects")
        try FileManager.default.removeItem(at: projects)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try CodeHostingSettingsUITests.alphaProjectTOML
            .replacingOccurrences(of: "~/dev/alpha-spec", with: "/tmp/acme-spec")
            .write(to: projects.appending(component: "alpha.toml"), atomically: true, encoding: .utf8)
    }

    private func writeCodeHostingReport(connections: [String]) throws {
        let file = configurationDirectory.deletingLastPathComponent().appending(component: "hosting-report.json")
        app.launchEnvironment["YH_STUB_CODE_HOSTING_REPORT_FILE"] = file.path(percentEncoded: false)
        try CodeHostingSettingsUITests.report(connections, offer: CodeHostingSettingsUITests.availableOffer)
            .write(to: file, atomically: true, encoding: .utf8)
    }
}
