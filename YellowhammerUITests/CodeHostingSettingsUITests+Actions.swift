import Foundation
import XCTest

// The Code Hosting pane's actions: connect (the gh CLI, a pasted token, an import), replace a token, remove.
extension CodeHostingSettingsUITests {
    // MARK: Connecting

    func testConnectingTheGitHubCLIRunsItAndListsTheNewCard() throws {
        try writeFixture(offer: Self.availableOffer)
        enableGates()
        showCodeHostingSettings()

        let connect = element("settings-code-hosting-connect-gh")
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { connect.isEnabled })
        connect.click()

        // What `yh` does before it exits: add the entry, so the report and the file agree.
        try appendToMachine(Self.ghConnectionTOML)
        try writeReport(connections: Self.defaultConnections + [Self.ghReportConnection], offer: Self.unavailableOffer)
        openGate("code-hosting")

        XCTAssertTrue(element("settings-code-hosting-connected").waitForExistence(timeout: 10))
        XCTAssertTrue(waitForRecorded("config connect-code-hosting gh --gh-cli"), "\(recordedArguments())")
        XCTAssertTrue(element("settings-code-hosting-row-gh").waitForExistence(timeout: 10))
        XCTAssertTrue(text(of: element("settings-code-hosting-type-gh")).contains("gh CLI"))
    }

    func testConnectingAPastedTokenSendsItOnStandardInputOnly() throws {
        try writeFixture()
        enableGates()
        showCodeHostingSettings()

        let name = element("settings-code-hosting-name")
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("company-b")
        let token = "ghp_uitest_secret_token"
        let field = element("settings-code-hosting-token-field")
        field.click()
        field.typeText(token)
        element("settings-code-hosting-token-store").click()

        try appendToMachine(Self.companyBConnectionTOML)
        try writeReport(
            connections: Self.defaultConnections + [Self.companyBReportConnection], offer: Self.availableOffer
        )
        openGate("code-hosting")

        XCTAssertTrue(element("settings-code-hosting-row-company-b").waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForRecorded("config connect-code-hosting company-b --token-stdin"), "\(recordedArguments())"
        )
        XCTAssertFalse(recordedArguments().contains { $0.contains(token) }, "\(recordedArguments())")
        let remaining = (field.value as? String) ?? ""
        XCTAssertTrue(remaining.isEmpty || remaining == "GitHub token", remaining)
    }

    func testConnectingByImportRunsTheImportUnderTheTypedName() throws {
        try writeFixture()
        showCodeHostingSettings()

        let name = element("settings-code-hosting-name")
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeText("company-c")
        element("settings-code-hosting-import-gh").click()

        XCTAssertTrue(
            waitForRecorded("config connect-code-hosting company-c --from-gh"), "\(recordedArguments())"
        )
        XCTAssertTrue(element("settings-code-hosting-connected").waitForExistence(timeout: 10))
    }

    // MARK: Replacing

    func testReplacingATokenRunsTheReplaceForThatConnection() throws {
        try writeFixture()
        showCodeHostingSettings()

        let replace = element("settings-code-hosting-replace-company-a")
        XCTAssertTrue(replace.waitForExistence(timeout: 10))
        replace.click()
        let field = element("settings-code-hosting-replace-field-company-a")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("ghp_uitest_replacement_token")
        element("settings-code-hosting-replace-store-company-a").click()

        XCTAssertTrue(
            waitForRecorded("config replace-code-hosting-token company-a --token-stdin"), "\(recordedArguments())"
        )
        XCTAssertTrue(element("settings-code-hosting-replaced-company-a").waitForExistence(timeout: 10))
        XCTAssertFalse(recordedArguments().contains { $0.contains("ghp_uitest_replacement_token") })
    }

    // MARK: Removing

    func testRemovalYhRefusesShowsItsWordsAndKeepsTheCard() throws {
        try writeFixture()
        app.launchEnvironment["YH_STUB_CODE_HOSTING_REMOVE_REFUSE"] =
            "Code Hosting Connection \"github\" was not removed: selected by Projects alpha; "
            + "change their selection first"
        showCodeHostingSettings()

        removeConnection("github")

        let failure = element("settings-code-hosting-remove-failure-github")
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertTrue(text(of: failure).contains("alpha"), text(of: failure))
        XCTAssertTrue(waitForRecorded("config remove-code-hosting-connection github"), "\(recordedArguments())")
        XCTAssertTrue(element("settings-code-hosting-row-github").exists)
    }

    func testRemovingAnUnusedConnectionDropsItsCard() throws {
        try writeFixture()
        enableGates()
        showCodeHostingSettings()

        XCTAssertTrue(element("settings-code-hosting-row-company-a").waitForExistence(timeout: 10))
        removeConnection("company-a")

        // What `yh` does before it exits: remove the entry, so the report and the file agree.
        try Self.machineTOML(includingCompanyA: false).write(to: machineFile, atomically: true, encoding: .utf8)
        try writeReport(connections: [Self.githubReportConnection], offer: Self.availableOffer)
        openGate("code-hosting-removed")

        XCTAssertTrue(element("settings-code-hosting-removed").waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForRecorded("config remove-code-hosting-connection company-a"), "\(recordedArguments())"
        )
        XCTAssertTrue(waitUntil { !element("settings-code-hosting-row-company-a").exists })
    }
}
