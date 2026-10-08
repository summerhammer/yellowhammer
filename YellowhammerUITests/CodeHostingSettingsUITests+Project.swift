import Foundation
import XCTest

extension CodeHostingSettingsUITests {
    func testProjectConnectionPickerRefusesThenSavesThroughTheEngine() throws {
        try writeFixture(connections: Self.defaultConnections + [Self.ghReportConnection])
        try appendToMachine(Self.ghConnectionTOML)
        app.launchEnvironment["YH_STUB_CODE_HOSTING_CHANGE_REFUSED_CONNECTION"] = "company-a"
        app.launchEnvironment["YH_STUB_CODE_HOSTING_CHANGE_GATES"] = "1"
        app.launchEnvironment["YH_STUB_GATE_DIR"] = gateDirectory.path(percentEncoded: false)
        showCodeHostingSettings()
        element("settings-project-alpha").click()
        let name = app.textFields["project-name"] // glossary:ignore GL001
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Edited Alpha")
        let picker = element("project-code-hosting-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.click()
        let refused = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "company-a ·")).firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 5))
        refused.click()
        element("project-code-hosting-change").click()
        let failure = element("project-code-hosting-failure")
        XCTAssertTrue(waitUntil { failure.exists && text(of: failure).contains("refused push permission") })
        XCTAssertTrue(waitForRecorded("project set-code-hosting-connection alpha company-a"))

        let project = configurationDirectory.appending(component: "projects/alpha.toml")
        XCTAssertEqual(try String(contentsOf: project, encoding: .utf8), Self.alphaProjectTOML)
        picker.click()
        let gh = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "gh ·")).firstMatch
        XCTAssertTrue(gh.waitForExistence(timeout: 5))
        gh.click()
        element("project-code-hosting-change").click()
        XCTAssertTrue(waitForRecorded("project set-code-hosting-connection alpha gh"))
        // The engine owns this edit; the gate prevents the app reload until the fixture agrees.
        try Self.alphaProjectTOML.replacingOccurrences(of: "connection = \"github\"", with: "connection = \"gh\"")
            .write(to: project, atomically: true, encoding: .utf8)
        openGate("code-hosting-changed")
        XCTAssertTrue(waitUntil { !failure.exists && text(of: picker).contains("gh") })
        XCTAssertTrue(try String(contentsOf: project, encoding: .utf8).contains("connection = \"gh\""))
        XCTAssertEqual(name.value as? String, "Edited Alpha")
        XCTAssertTrue(app.buttons["configuration-save"].isEnabled)
    }
}
