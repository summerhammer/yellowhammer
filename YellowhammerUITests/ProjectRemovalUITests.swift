import Foundation
import XCTest

/// Settings → a Project's pane → *Remove Project…*, driven against the shared stub `yh` (`EngineStub`'s
/// `remove` case). It reuses `OverviewWindowUITests`' fixture: three Projects (`archive`, `owner`, `reader`)
/// and one refused Project file. The stub appends each `yh` argument vector to `YH_STUB_ARGV_LOG`, and its
/// run waits on the `project-removed` gate: the real `yh` deletes `projects/<id>.toml`, but the stub cannot
/// write the runner's container, so the test deletes that file itself and then opens the gate.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class ProjectRemovalUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var gateDirectory: URL!
    private var argvLog: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-project-removal-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        gateDirectory = base.appending(component: "gates", directoryHint: .isDirectory)
        let stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        try OverviewWindowUITests.writeConfiguration(in: configurationDirectory)
        try FileManager.default.createDirectory(at: gateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
        let stubURL = try EngineStub.write(in: stubDirectory)
        argvLog = URL(filePath: "/tmp/yh-uitest-argv-\(UUID().uuidString)")

        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-YellowhammerEngineStub", stubURL.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launchEnvironment = [
            "YH_STUB_ARGV_LOG": argvLog.path(percentEncoded: false),
            "YH_STUB_GATE_DIR": gateDirectory.path(percentEncoded: false)
        ]
    }

    override func tearDown() async throws {
        if testRun?.hasSucceeded == false {
            add(XCTAttachment(string: app.debugDescription))
            add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        }
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
        if let argvLog { try? FileManager.default.removeItem(at: argvLog) }
    }

    // MARK: Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    /// Polls `condition` until it holds or `timeout` passes.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// The argument vectors the stub recorded, one per run.
    private func recordedArguments() -> [String] {
        let contents = (try? String(contentsOf: argvLog, encoding: .utf8)) ?? ""
        return contents.split(separator: "\n").map(String.init)
    }

    private func removalRuns() -> [String] {
        recordedArguments().filter { $0.hasPrefix("project remove") } // glossary:ignore GL001
    }

    /// Lets a stub run waiting on the gate `name` finish (`EngineStub.waitForGate`).
    private func openGate(_ name: String) {
        let gate = gateDirectory.appending(component: name, directoryHint: .notDirectory)
        XCTAssertTrue(FileManager.default.createFile(atPath: gate.path(percentEncoded: false), contents: nil))
    }

    /// What `yh project remove archive` ends with: the Project's file is gone.
    private func deleteArchiveProjectFile() throws {
        try FileManager.default.removeItem(
            at: configurationDirectory.appending(components: "projects", "archive.toml", directoryHint: .notDirectory)
        )
    }

    /// Launches, opens Settings, shows `archive`'s pane and opens the removal sheet.
    private func openRemovalSheet() {
        app.launch()
        XCTAssertTrue(element("sidebar-archive").waitForExistence(timeout: 10))
        app.activate()
        // The application menu's Settings item, not Cmd+,: a synthesized shortcut was dropped once while the
        // app settled, and the menu item is the same command.
        app.menuBars.menuBarItems["Yellowhammer"].click()
        app.menuBars.menuItems["Settings\u{2026}"].click()
        let row = element("settings-project-archive")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(element("settings-project-pane-archive").waitForExistence(timeout: 5))
        let remove = element("settings-project-remove")
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(remove.isEnabled, "the stub stands in for yh, so the removal is available")
        remove.click()
        XCTAssertTrue(element("settings-project-remove-sheet").waitForExistence(timeout: 5))
    }

    /// Replaces the confirmation field's text with `value`.
    private func type(_ value: String) {
        let field = element("settings-project-remove-confirm-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(value)
    }

    /// Types the Project's id and confirms.
    private func confirmRemoval() {
        type("archive")
        let confirm = element("settings-project-remove-confirm")
        XCTAssertTrue(waitUntil { confirm.isEnabled }, "typing the id never enabled the button")
        confirm.click()
    }

    /// Writes `projects/orphan.toml`: strict load refuses it (its installation is not in config.toml) and
    /// the lenient load `yh project remove` uses accepts it.
    private func writeOrphanProjectFile() throws {
        try """
        id = "orphan"
        name = "Orphan"
        spec_source = "~/dev/spec"

        [board.linear]
        installation = "gone"
        project = "ORPHAN"

        [[repos]]
        name = "orphan"
        path = "~/dev/orphan"
        role = "backend"
        check = "swift test"
        """.write(
            to: configurationDirectory.appending(components: "projects", "orphan.toml", directoryHint: .notDirectory),
            atomically: true, encoding: .utf8
        )
    }

    /// Launches, opens Settings and shows Refused Files.
    private func openRefusedFiles() {
        app.launch()
        XCTAssertTrue(element("sidebar-archive").waitForExistence(timeout: 10))
        app.activate()
        app.menuBars.menuBarItems["Yellowhammer"].click()
        app.menuBars.menuItems["Settings\u{2026}"].click()
        let row = element("settings-refused-files")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(element("settings-refused-file-0").waitForExistence(timeout: 5))
    }

    // MARK: Tests

    func testRemoveIsConfirmedByTypingTheProjectID() {
        openRemovalSheet()
        let confirm = element("settings-project-remove-confirm")
        XCTAssertFalse(confirm.isEnabled, "nothing is typed yet")

        type("archiv")
        XCTAssertFalse(confirm.isEnabled, "a wrong id must not enable the button")
        type("owner")
        XCTAssertFalse(confirm.isEnabled, "another Project's id must not enable the button")

        type("archive")
        XCTAssertTrue(waitUntil { confirm.isEnabled }, "the right id never enabled the button")

        element("settings-project-remove-cancel").click()
        XCTAssertTrue(element("settings-project-remove-sheet").waitForNonExistence(timeout: 5))
        XCTAssertTrue(removalRuns().isEmpty, "Cancel ran yh: \(recordedArguments())")
        XCTAssertTrue(element("settings-project-archive").exists, "Cancel removed the Project")
    }

    func testRemoveRunsYhAndDropsTheProjectFromBothSidebars() throws {
        openRemovalSheet()
        confirmRemoval()

        XCTAssertTrue(
            waitUntil(timeout: 10) { !removalRuns().isEmpty },
            "yh never ran: \(recordedArguments())"
        )
        XCTAssertEqual(removalRuns(), ["project remove archive --yes"]) // glossary:ignore GL001
        // yh's lines show while it runs, and the sheet cannot be cancelled.
        XCTAssertTrue(element("settings-project-remove-output").waitForExistence(timeout: 5))
        XCTAssertFalse(element("settings-project-remove-cancel").exists)
        XCTAssertTrue(element("settings-project-archive").exists, "the Project is listed until yh is done")

        try deleteArchiveProjectFile()
        openGate("project-removed")

        XCTAssertTrue(element("settings-project-remove-sheet").waitForNonExistence(timeout: 10))
        XCTAssertTrue(element("settings-general-pane").waitForExistence(timeout: 5))
        XCTAssertTrue(element("settings-project-archive").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("settings-project-owner").exists)
        XCTAssertTrue(element("sidebar-archive").waitForNonExistence(timeout: 5), "the main window still lists archive")
        XCTAssertTrue(element("sidebar-owner").exists)
    }

    func testRefusedRemovalShowsYhsLinesAndOffersTryAgain() {
        app.launchEnvironment["YH_STUB_PROJECT_REMOVE_REFUSE"] = "1"
        openRemovalSheet()
        confirmRemoval()

        let failure = element("settings-project-remove-failure")
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertTrue(text(of: failure).contains("holds"), text(of: failure))
        XCTAssertTrue(element("settings-project-remove-retry").exists)
        XCTAssertEqual(removalRuns().count, 1)

        element("settings-project-remove-close").click()
        XCTAssertTrue(element("settings-project-remove-sheet").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("settings-project-archive").exists, "a refused removal must keep the Project")
        XCTAssertTrue(element("sidebar-archive").exists)
    }

    func testRefusedFileRemovalIsOfferedOnlyWhereYhWouldAct() throws {
        try writeOrphanProjectFile()
        openRefusedFiles()

        // broken.toml sorts first and is malformed, so yh refuses it too.
        XCTAssertTrue(element("settings-refused-unremovable-0").exists)
        XCTAssertFalse(element("settings-refused-remove-broken").exists)
        let remove = element("settings-refused-remove-orphan")
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(remove.isEnabled, "the stub stands in for yh, so the removal is available")
        remove.click()
        XCTAssertTrue(element("settings-project-remove-sheet").waitForExistence(timeout: 5))

        type("orphan")
        let confirm = element("settings-project-remove-confirm")
        XCTAssertTrue(waitUntil { confirm.isEnabled }, "typing the id never enabled the button")
        confirm.click()

        XCTAssertTrue(
            waitUntil(timeout: 10) { removalRuns().contains("project remove orphan --yes") }, // glossary:ignore GL001
            "yh never ran: \(recordedArguments())"
        )
        try FileManager.default.removeItem(
            at: configurationDirectory.appending(components: "projects", "orphan.toml", directoryHint: .notDirectory)
        )
        openGate("project-removed")

        XCTAssertTrue(element("settings-project-remove-sheet").waitForNonExistence(timeout: 10))
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("settings-refused-file-0").exists, "broken is still refused")
        XCTAssertTrue(element("settings-refused-unremovable-0").exists, "the Operator stays on Refused Files")
    }
}
