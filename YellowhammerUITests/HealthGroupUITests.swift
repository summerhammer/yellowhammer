import Foundation
import XCTest

/// The Pulse's Health group, driven against a stub `yh` that prints staged `yh doctor --json` findings
/// (spec story app/land-on-the-sidebar-and-pulse). Covers that the group shows the stale Operator
/// identity, App Installation revoked and probe failure flags with `yh doctor`'s own messages, and no
/// other finding; that the two installation flags appear only on the Projects their installation
/// serves; and that such a flag opens Settings → Boards. The stub prints nothing unless it
/// is run as exactly `yh doctor --json`, so a run with `--fix`, `--yes` or `--probe` leaves the group
/// unread and fails the test.
///
/// The fixture has two App Installations: `acme` (revoked, stale Operator) serves `archive` and `owner`;
/// `scratch` (connected) serves `reader`.
///
/// XCTest, not Swift Testing: the `Testing` module is unavailable in a UI testing bundle.
@MainActor
final class HealthGroupUITests: XCTestCase {
    private var base: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        base = FileManager.default.temporaryDirectory
            .appending(component: "yellowhammer-health-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        let configurationDirectory = base.appending(component: "config", directoryHint: .isDirectory)
        let stubDirectory = base.appending(component: "stub", directoryHint: .isDirectory)
        try Self.writeConfiguration(in: configurationDirectory)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
        let stubURL = stubDirectory.appending(component: "yh.sh", directoryHint: .notDirectory)
        try Self.stub.write(to: stubURL, atomically: true, encoding: .utf8)

        app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-YellowhammerEngineStub", stubURL.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
    }

    override func tearDown() async throws {
        if testRun?.hasSucceeded == false {
            add(XCTAttachment(string: app.debugDescription))
            add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        }
        app.terminate()
        try? FileManager.default.removeItem(at: base)
    }

    func testHealthShowsYhDoctorFlagsAndNoOtherFinding() {
        let flags = app.descendants(matching: .any).matching(identifier: "health-flag")
        XCTAssertTrue(flags.firstMatch.waitForExistence(timeout: 15), "the Health group never read yh doctor")
        XCTAssertEqual(flags.count, 3)

        for text in [
            "Stale Operator identity", "App Installation revoked", "Probe failure",
            "the configured Operator identity usr-1 is no longer a candidate",
            "`codex` excluded from routing: probe failed"
        ] {
            XCTAssertTrue(shows(text), "missing \u{201C}\(text)\u{201D}")
        }
        XCTAssertFalse(shows("does not exist"), "a git finding is not a Health flag")
    }

    func testARevokedInstallationShowsOnItsOwnProjectsOnly() {
        let flags = app.descendants(matching: .any).matching(identifier: "health-flag")
        XCTAssertTrue(flags.firstMatch.waitForExistence(timeout: 15), "the Health group never read yh doctor")
        XCTAssertTrue(shows("App Installation revoked"), "archive uses acme, which is revoked")

        for (id, revoked) in [("owner", true), ("reader", false), ("archive", true)] {
            select(id)
            let expected = revoked ? 3 : 1
            XCTAssertTrue(waitForFlagCount(expected), "\(id) shows \(flags.count) flags, not \(expected)")
            XCTAssertEqual(shows("App Installation revoked"), revoked, "\(id)")
            XCTAssertEqual(shows("Stale Operator identity"), revoked, "\(id)")
            XCTAssertTrue(shows("Probe failure"), "a probe failure is machine-wide; \(id) must show it")
        }
    }

    func testAnInstallationFlagOpensTheBoardsPane() {
        let revoked = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == 'health-flag' AND label BEGINSWITH 'App Installation revoked'"
            ))
            .firstMatch
        XCTAssertTrue(revoked.waitForExistence(timeout: 15), "the Health group never read yh doctor")
        app.activate()
        revoked.click()
        let boards = app.descendants(matching: .any)["settings-boards-pane"].firstMatch
        XCTAssertTrue(boards.waitForExistence(timeout: 5), "the flag did not open Settings → Boards")
        XCTAssertTrue(app.descendants(matching: .any)["settings-linear-row-acme"].waitForExistence(timeout: 5))
    }

    private func select(_ id: String) {
        let row = app.descendants(matching: .any)["sidebar-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "sidebar-\(id) is missing")
        // Another app's window can hold focus under a busy runner; XCUITest clicks only a frontmost app.
        app.activate()
        row.click()
    }

    private func waitForFlagCount(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let flags = app.descendants(matching: .any).matching(identifier: "health-flag")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if flags.count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return flags.count == count
    }

    /// Whether any element's label or value holds `text`: selectable text is exposed by its value.
    private func shows(_ text: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch.exists
    }

    /// `yh doctor --json`'s last line: three flagged findings, passing ones, and a git failure, which is
    /// not a Health flag. The Linear rows carry the installation and the Projects it serves, as `yh doctor`
    /// writes them. `yh doctor` exits 1 when any finding fails.
    private static let findings = [
        finding("configuration", "archive", "pass", "Project archive is valid"),
        finding("probes", "codex", "failure", "`codex` excluded from routing: probe failed"),
        finding("git", "archive", "failure", "Project archive repo archive does not exist"),
        finding("linear", "authorization", "failure", "the Linear installation was revoked or its sign-in expired",
                installation: "acme", projects: ["archive", "owner"]),
        finding("linear", "operator", "warning", "the configured Operator identity usr-1 is no longer a candidate",
                installation: "acme", projects: ["archive", "owner"]),
        finding("linear", "authorization", "pass", "Linear authorization succeeded",
                installation: "scratch", projects: ["reader"]),
        finding("linear", "operator", "pass", "Operator identity usr-2 is a candidate",
                installation: "scratch", projects: ["reader"])
    ]

    private static func finding(
        _ check: String, _ subject: String, _ severity: String, _ message: String,
        installation: String? = nil, projects: [String]? = nil
    ) -> String {
        var fields = [
            #""check":"\#(check)""#, #""message":"\#(message)""#,
            #""severity":"\#(severity)""#, #""subject":"\#(subject)""#
        ]
        if let installation { fields.append(#""installation":"\#(installation)""#) }
        if let projects {
            fields.append(#""projects":["# + projects.map { #""\#($0)""# }.joined(separator: ",") + "]")
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Two App Installations and three Projects: `acme` serves `archive` and `owner`, `scratch` serves
    /// `reader`. No Journals.
    private static func writeConfiguration(in directory: URL) throws {
        let projects = directory.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try """
        [board.linear.installations.acme]
        credential = "keychain:linear-acme"
        workspace = "workspace-1"
        app_user = "app-user-1"
        operator = "usr-1"

        [board.linear.installations.scratch]
        credential = "keychain:linear-scratch"
        workspace = "workspace-2"
        app_user = "app-user-2"
        operator = "usr-2"

        [github]
        credential = "keychain:github"

        [cli.claude]

        [[routing]]
        route = "claude/sonnet"
        """.write(to: directory.appending(component: "config.toml"), atomically: true, encoding: .utf8)
        for (id, installation) in [("archive", "acme"), ("owner", "acme"), ("reader", "scratch")] {
            try """
            id = "\(id)"
            name = "\(id.capitalized)"
            spec_source = "~/dev/spec"

            [board.linear]
            installation = "\(installation)"
            project = "\(id.uppercased())"

            [[repos]]
            name = "\(id)"
            path = "~/dev/\(id)"
            role = "backend"
            check = "swift test"
            """.write(to: projects.appending(component: "\(id).toml"), atomically: true, encoding: .utf8)
        }
    }

    /// A `sh` script, read (never exec'd) by `/bin/sh`. The JSON sits in single quotes, so the shell
    /// prints its backticks verbatim.
    private static let stub = """
    #!/bin/sh
    [ "$#" -eq 2 ] && [ "$1" = doctor ] && [ "$2" = --json ] || exit 2
    echo '[\(findings.joined(separator: ","))]'
    exit 1
    """
}
