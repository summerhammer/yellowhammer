import Foundation
import XCTest

/// The Pulse's Health group, driven against a stub `yh` that prints staged `yh doctor --json` findings
/// (spec story app/land-on-the-sidebar-and-pulse). Covers that the group shows the stale Operator
/// identity, Board Connection revoked, refused Code Hosting Connection and probe failure flags with
/// `yh doctor`'s own messages, and no other finding; that the installation and connection flags appear
/// only on the Projects they serve; and that such flags open Settings → Boards and Settings → Code Hosting.
/// The stub prints nothing unless it is run as exactly `yh doctor --json`, so a run with `--fix`, `--yes`
/// or `--probe` leaves the group unread and fails the test.
///
/// The fixture has two Board Connections: `acme` (revoked, stale Operator) serves `archive` and `owner`;
/// `scratch` (connected) serves `reader`. It also has two Code Hosting Connections: `github` (refused) serves
/// `archive` and `owner`; `secondary` (connected) serves `reader`.
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
        XCTAssertEqual(flags.count, 4)

        for text in [
            "Stale Operator identity", "Board Connection revoked", "Code Hosting Connection refused", "Probe failure",
            "the configured Operator identity usr-1 is no longer a candidate",
            "GitHub rejected the token in keychain:github",
            "`codex` excluded from routing: probe failed"
        ] {
            XCTAssertTrue(shows(text), "missing \u{201C}\(text)\u{201D}")
        }
        XCTAssertFalse(shows("does not exist"), "a git finding is not a Health flag")
    }

    func testARevokedInstallationShowsOnItsOwnProjectsOnly() {
        let flags = app.descendants(matching: .any).matching(identifier: "health-flag")
        XCTAssertTrue(flags.firstMatch.waitForExistence(timeout: 15), "the Health group never read yh doctor")
        XCTAssertTrue(shows("Board Connection revoked"), "archive uses acme, which is revoked")
        XCTAssertTrue(shows("Code Hosting Connection refused"), "archive uses github, which is refused")

        for (id, troubled) in [("owner", true), ("reader", false), ("archive", true)] {
            select(id)
            let expected = troubled ? 4 : 1
            XCTAssertTrue(waitForFlagCount(expected), "\(id) shows \(flags.count) flags, not \(expected)")
            XCTAssertEqual(shows("Board Connection revoked"), troubled, "\(id)")
            XCTAssertEqual(shows("Stale Operator identity"), troubled, "\(id)")
            XCTAssertEqual(shows("Code Hosting Connection refused"), troubled, "\(id)")
            XCTAssertTrue(shows("Probe failure"), "a probe failure is machine-wide; \(id) must show it")
        }
    }

    func testAnInstallationFlagOpensTheBoardsPane() {
        let revoked = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == 'health-flag' AND label BEGINSWITH 'Board Connection revoked'"
            ))
            .firstMatch
        XCTAssertTrue(revoked.waitForExistence(timeout: 15), "the Health group never read yh doctor")
        app.activate()
        revoked.click()
        let boards = app.descendants(matching: .any)["settings-boards-pane"].firstMatch
        XCTAssertTrue(boards.waitForExistence(timeout: 5), "the flag did not open Settings → Boards")
        XCTAssertTrue(app.descendants(matching: .any)["settings-linear-row-acme"].waitForExistence(timeout: 5))
    }

    func testARefusedCodeHostingConnectionFlagOpensTheCodeHostingPane() {
        let refused = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == 'health-flag' AND label BEGINSWITH 'Code Hosting Connection refused'"
            ))
            .firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 15), "the Health group never read yh doctor")
        app.activate()
        refused.click()
        let codeHosting = app.descendants(matching: .any)["settings-code-hosting-pane"].firstMatch
        XCTAssertTrue(codeHosting.waitForExistence(timeout: 5), "the flag did not open Settings → Code Hosting")
        XCTAssertTrue(app.descendants(matching: .any)["settings-code-hosting-row-github"].waitForExistence(timeout: 5))
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

    /// `yh doctor --json`'s last line: four flagged findings, passing ones, and a git failure, which is
    /// not a Health flag. The Linear and GitHub rows carry the connection and the Projects they serve,
    /// as `yh doctor` writes them. `yh doctor` exits 1 when any finding fails.
    private static let findings = [
        finding("configuration", "archive", "pass", "Project archive is valid"),
        finding("probes", "codex", "failure", "`codex` excluded from routing: probe failed"),
        finding("git", "archive", "failure", "Project archive repo archive does not exist"),
        finding("linear", "authorization", "failure", "the Linear installation was revoked or its sign-in expired",
                installation: "acme", projects: ["archive", "owner"]),
        finding("linear", "operator", "warning", "the configured Operator identity usr-1 is no longer a candidate",
                installation: "acme", projects: ["archive", "owner"]),
        finding("github", "credential", "failure",
                "Code Hosting Connection github: GitHub rejected the token in keychain:github: "
                    + "it is wrong, revoked or expired; replace it in Settings › Code Hosting",
                connection: "github", projects: ["archive", "owner"]),
        finding("linear", "authorization", "pass", "Linear authorization succeeded",
                installation: "scratch", projects: ["reader"]),
        finding("linear", "operator", "pass", "Operator identity usr-2 is a candidate",
                installation: "scratch", projects: ["reader"]),
        finding("github", "credential", "pass",
                "Code Hosting Connection secondary: The token belongs to octocat.",
                connection: "secondary", projects: ["reader"])
    ]

    private static func finding(
        _ check: String, _ subject: String, _ severity: String, _ message: String,
        installation: String? = nil, connection: String? = nil, projects: [String]? = nil
    ) -> String {
        var fields = [
            #""check":"\#(check)""#, #""message":"\#(message)""#,
            #""severity":"\#(severity)""#, #""subject":"\#(subject)""#
        ]
        if let installation { fields.append(#""installation":"\#(installation)""#) }
        if let connection { fields.append(#""connection":"\#(connection)""#) }
        if let projects {
            fields.append(#""projects":["# + projects.map { #""\#($0)""# }.joined(separator: ",") + "]")
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static let machineConfigTOML = """
        [board.linear.connections.acme]
        credential = "keychain:linear-acme"
        workspace = "workspace-1"
        yellowhammer_identity = "app-user-1"
        operator = "usr-1"

        [board.linear.connections.scratch]
        credential = "keychain:linear-scratch"
        workspace = "workspace-2"
        yellowhammer_identity = "app-user-2"
        operator = "usr-2"

        [code_hosting.github.connections.github]
        type = "keychain"
        credential = "keychain:github"

        [code_hosting.github.connections.secondary]
        type = "keychain"
        credential = "keychain:secondary"

        [cli.claude]

        [[routing]]
        route = "claude/sonnet"
        """

    private static func projectTOML(id: String, installation: String, connection: String) -> String {
        """
        id = "\(id)"
        name = "\(id.capitalized)"
        spec_source = "~/dev/spec"

        [code_hosting]
        connection = "\(connection)"

        [board.linear]
        connection = "\(installation)"
        project = "\(id.uppercased())"

        [[repos]]
        name = "\(id)"
        path = "~/dev/\(id)"
        role = "backend"
        check = "swift test"
        """
    }

    /// Two Board Connections, two Code Hosting Connections and three Projects: `acme` and `github` serve
    /// `archive` and `owner`, `scratch` and `secondary` serve `reader`. No Journals.
    private static func writeConfiguration(in directory: URL) throws {
        let projects = directory.appending(component: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let configFile = directory.appending(component: "config.toml")
        try machineConfigTOML.write(to: configFile, atomically: true, encoding: .utf8)
        for (id, installation, connection) in [
            ("archive", "acme", "github"),
            ("owner", "acme", "github"),
            ("reader", "scratch", "secondary")
        ] {
            try projectTOML(id: id, installation: installation, connection: connection)
                .write(to: projects.appending(component: "\(id).toml"), atomically: true, encoding: .utf8)
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
