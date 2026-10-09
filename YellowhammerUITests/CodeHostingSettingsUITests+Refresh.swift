import Foundation
import XCTest

extension CodeHostingSettingsUITests {
    func testRevisitingThePaneReadsChangedIdentityAndRegistry() throws {
        try writeFixture()
        try appendToMachine(Self.ghConnectionTOML)
        try writeReport(connections: Self.defaultConnections + [Self.ghReportConnection], offer: Self.availableOffer)
        showCodeHostingSettings()
        XCTAssertTrue(waitUntil { text(of: element("settings-code-hosting-connection-gh")).contains("octocat") })

        element("settings-general").click()
        try appendToMachine(Self.companyBConnectionTOML)
        let changedGH = Self.ghReportConnection.replacingOccurrences(of: "octocat", with: "new-account")
        try writeReport(
            connections: Self.defaultConnections + [changedGH, Self.companyBReportConnection],
            offer: Self.availableOffer
        )
        element("settings-code-hosting").click()
        XCTAssertTrue(waitUntil { text(of: element("settings-code-hosting-connection-gh")).contains("new-account") })
        XCTAssertTrue(element("settings-code-hosting-row-company-b").waitForExistence(timeout: 10))
    }

    func testReopeningSettingsReadsARevokedToken() throws {
        try writeFixture()
        showCodeHostingSettings()
        XCTAssertTrue(waitUntil { text(of: element("settings-code-hosting-connection-github")).contains("octocat") })
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil { !element("settings-code-hosting-pane").exists })
        try writeRevokedReport()
        app.menuBars.menuBarItems["Yellowhammer"].click()
        app.menuBars.menuItems["Settings\u{2026}"].click()
        // A Project request may preselect the Project on reopen.
        element("settings-code-hosting").click()
        assertRevokedToken()
    }

    func testAppActivationRefreshesTheVisiblePane() throws {
        try writeFixture()
        showCodeHostingSettings()
        XCTAssertTrue(waitUntil { text(of: element("settings-code-hosting-connection-github")).contains("octocat") })
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        try writeRevokedReport()
        app.activate()
        assertRevokedToken()
    }

    func testARefreshRequestedDuringARefusedActionRunsAfterItFinishes() throws {
        try writeFixture()
        enableGates()
        app.launchEnvironment["YH_STUB_CODE_HOSTING_REMOVE_REFUSE"] = "Selected by Project alpha."
        showCodeHostingSettings()
        XCTAssertTrue(waitUntil { text(of: element("settings-code-hosting-connection-github")).contains("octocat") })
        removeConnection("github")
        XCTAssertTrue(waitForRecorded("config remove-code-hosting-connection github"))
        element("settings-general").click()
        try writeRevokedReport()
        element("settings-code-hosting").click()
        openGate("code-hosting-removed")
        XCTAssertTrue(element("settings-code-hosting-remove-failure-github").waitForExistence(timeout: 10))
        assertRevokedToken()
    }

    func testAReportFailureClearsThePreviousHealthyIdentity() throws {
        try writeFixture()
        showCodeHostingSettings()
        XCTAssertTrue(waitUntil { text(of: element("settings-code-hosting-connection-github")).contains("octocat") })
        element("settings-general").click()
        try "invalid report".write(to: reportFile, atomically: true, encoding: .utf8)
        element("settings-code-hosting").click()
        XCTAssertTrue(waitUntil { text(of: element("settings-code-hosting-connection-github")) == "github" })
        XCTAssertTrue(element("settings-code-hosting-report-failure").waitForExistence(timeout: 10))
    }

    func testNavigationDoesNotCancelAnOverlappingReportRead() throws {
        try writeFixture()
        app.launchEnvironment["YH_STUB_GATE_DIR"] = gateDirectory.path(percentEncoded: false)
        app.launchEnvironment["YH_STUB_CODE_HOSTING_REPORT_GATE"] = "1"
        showCodeHostingSettings()
        XCTAssertTrue(waitForRecorded("config print-code-hosting-connections"))
        element("settings-general").click()
        element("settings-code-hosting").click()
        try writeRevokedReport()
        openGate("code-hosting-report")
        assertRevokedToken()
        XCTAssertTrue(waitUntil {
            recordedArguments().filter { $0 == "config print-code-hosting-connections" }.count >= 2
        }, "\(recordedArguments())")
    }

    private func writeRevokedReport() throws {
        let refused = """
        {"name":"github","type":"keychain","state":"refused",\
        "reason":"GitHub rejected the revoked token.","projects":["alpha"]}
        """
        try writeReport(connections: [refused, Self.companyAReportConnection], offer: Self.unavailableOffer)
    }

    private func assertRevokedToken() {
        XCTAssertTrue(waitUntil {
            text(of: element("settings-code-hosting-status-github")).contains("GitHub rejected the revoked token.")
        })
        XCTAssertEqual(text(of: element("settings-code-hosting-connection-github")), "github")
    }
}
