import Foundation
import XCTest

/// The Pulse's Health group, driven against a stub `yh` that prints staged `yh doctor --json` findings
/// (spec story app/land-on-the-sidebar-and-pulse). Covers that the group shows the stale Operator
/// identity, App Installation revoked and probe failure flags with `yh doctor`'s own messages, and no
/// other finding. The stub prints nothing unless it is run as exactly `yh doctor --json`, so a run with
/// `--fix`, `--yes` or `--probe` leaves the group unread and fails the test.
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
        try OverviewWindowUITests.writeConfiguration(in: configurationDirectory)
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

    /// Whether any element's label or value holds `text`: selectable text is exposed by its value.
    private func shows(_ text: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch.exists
    }

    /// `yh doctor --json`'s last line: three flagged findings, a passing one, and a git failure, which
    /// is not a Health flag. `yh doctor` exits 1 when any finding fails.
    private static let findings = [
        finding("configuration", "archive", "pass", "Project archive is valid"),
        finding("probes", "codex", "failure", "`codex` excluded from routing: probe failed"),
        finding("git", "archive", "failure", "Project archive repo archive does not exist"),
        finding("linear", "authorization", "failure", "the Linear installation was revoked or its sign-in expired"),
        finding("linear", "operator", "warning", "the configured Operator identity usr-1 is no longer a candidate")
    ]

    private static func finding(_ check: String, _ subject: String, _ severity: String, _ message: String) -> String {
        #"{"check":"\#(check)","message":"\#(message)","severity":"\#(severity)","subject":"\#(subject)"}"#
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
