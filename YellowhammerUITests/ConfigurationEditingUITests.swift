import Foundation
import XCTest

/// The Project Window's Configuration tab driven against a fixture configuration directory (P14.3). A successful
/// save is not exercised here: the UI test runner is itself sandboxed, so the (unsandboxed) app under
/// test cannot write into the runner's own container — see
/// `SetupWizardUITests`'s stub-execution note for the same boundary. The round trip through
/// ``Config/Configuration/save(_:to:in:replacing:)`` is covered by
/// `ConfigurationEditingTests` in the `ConfigTests` package instead; this suite covers what the app
/// itself is responsible for: reading the Project's fields into the form, and showing a refusal in the
/// loader's own words without touching the file on disk.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class ConfigurationEditingUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var projectFileURL: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-config-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let projectsDirectory = configurationDirectory.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)

        try Self.machineTOML.write(
            to: configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory),
            atomically: true, encoding: .utf8
        )
        projectFileURL = projectsDirectory.appending(component: "demo.toml", directoryHint: .notDirectory)
        try Self.demoProjectTOML.write(to: projectFileURL, atomically: true, encoding: .utf8)

        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        app.openProjectWindow()
    }

    override func tearDown() async throws {
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory.deletingLastPathComponent())
    }

    func testProjectDetailShowsNameAndReadOnlySpecSource() throws {
        let name = app.textFields["project-name"] // glossary:ignore GL001
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "Demo")

        let specSource = app.staticTexts["project-spec-source"] // glossary:ignore GL001
        XCTAssertTrue(specSource.waitForExistence(timeout: 5))
        XCTAssertEqual(specSource.value as? String, "~/dev/demo-spec")

        let caption = app.staticTexts["project-spec-source-caption"] // glossary:ignore GL001
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertEqual(caption.value as? String, "read \u{2014} this Project never writes it")
    }

    func testInvalidBoundIsRefusedAndDiskIsUnchanged() throws {
        let onDiskBeforeSave = try String(contentsOf: projectFileURL, encoding: .utf8)

        let bound = app.textFields["bound-attempts_per_card"]
        XCTAssertTrue(bound.waitForExistence(timeout: 10))
        bound.click()
        // Select all and replace, rather than appending to whatever the loaded value already is.
        bound.typeKey("a", modifierFlags: .command)
        bound.typeText("0")

        let save = app.buttons["configuration-save"]
        XCTAssertTrue(save.isEnabled)
        save.click()

        let failure = app.staticTexts["configuration-save-failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        let message = (failure.value as? String) ?? ""
        XCTAssertTrue(message.contains("attempts_per_card"), message)
        XCTAssertTrue(message.contains("must be an integer >= 1"), message)

        let onDiskAfterSave = try String(contentsOf: projectFileURL, encoding: .utf8)
        XCTAssertEqual(onDiskBeforeSave, onDiskAfterSave)
    }

    private static let machineTOML = """
    [linear]
    credential = "keychain:linear"
    [github]
    credential = "keychain:github"

    [cli.claude]

    [[routing]]
    route = "claude/sonnet/medium"
    """

    private static let demoProjectTOML = """
    id = "demo"
    name = "Demo"
    linear_project = "DEMO"
    spec_source = "~/dev/demo-spec"

    [[repos]]
    name = "backend"
    path = "~/dev/demo-backend"
    role = "backend"
    check = "swift test"
    """
}
