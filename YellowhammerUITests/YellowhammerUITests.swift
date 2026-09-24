import Foundation
import XCTest

/// The Project Selector and the deep link, driven through the running app against a fixture
/// configuration directory (OQ52 Face 2; ooux/nav-flow → Multi-Project Navigation).
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class ProjectScopeUITests: XCTestCase {
    private var configurationDirectory: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        configurationDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        try Self.writeConfiguration(in: configurationDirectory)
        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        try? FileManager.default.removeItem(at: configurationDirectory)
    }

    func testSelectorListsConfiguredProjectNamesAndNothingElse() {
        let selector = app.popUpButtons["project-selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        XCTAssertEqual(selector.value as? String, "Owner")

        selector.click()
        let items = selector.menuItems
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5))
        // Exactly the configured names, in name order: no badge, roll-up word or count beside any.
        XCTAssertEqual(items.allElementsBoundByIndex.map(\.title), ["Owner", "Reader", "Reader Two"])
        for item in items.allElementsBoundByIndex {
            XCTAssertFalse(item.images.firstMatch.exists, "\(item.title) carries an image")
        }

        items["Reader Two"].click()
        XCTAssertTrue(app.windows["Reader Two"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["reader2"].exists)
    }

    /// A link that launches the app: `XCUIApplication.open(_:)` relaunches it by URL. A link to the
    /// already-running app cannot be driven from here — LaunchServices does not route a URL to an
    /// instance XCUITest launched, and starts a second one instead.
    func testDeepLinkLaunchOpensTheNamedProject() throws {
        XCTAssertTrue(app.windows["Owner"].waitForExistence(timeout: 10))

        app.open(try XCTUnwrap(URL(string: "yellowhammer://project/reader")))

        XCTAssertTrue(app.windows["Reader"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["reader"].exists)
    }

    private static func writeConfiguration(in directory: URL) throws {
        let projects = directory.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try """
        [linear]
        credential = "keychain:linear"
        client_id = "yellowhammer-client-id"
        [github]
        credential = "keychain:github"

        [cli.claude]

        [[routing]]
        route = "claude/sonnet"
        """.write(to: directory.appending(component: "config.toml"), atomically: true, encoding: .utf8)
        // File order differs from name order on purpose; the selector sorts by name.
        for (id, name) in [("reader2", "Reader Two"), ("owner", "Owner"), ("reader", "Reader")] {
            try """
            id = "\(id)"
            name = "\(name)"
            linear_project = "\(id.uppercased())"
            spec_source = "~/dev/spec"

            [[repos]]
            name = "\(id)"
            path = "~/dev/\(id)"
            role = "backend"
            check = "swift test"
            """.write(to: projects.appending(component: "\(id).toml"), atomically: true, encoding: .utf8)
        }
    }
}
