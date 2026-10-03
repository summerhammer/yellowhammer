import Domain
import Testing

@testable import Pulse

/// One `yh doctor --json` row.
private struct Finding {
    let check: String
    let subject: String
    let severity: String
    let message: String

    init(_ check: String, _ subject: String, _ severity: String, _ message: String) {
        self.check = check
        self.subject = subject
        self.severity = severity
        self.message = message
    }

    var row: DoctorFindingRow {
        DoctorFindingRow(check: check, subject: subject, severity: severity, message: message)
    }
}

/// `yh doctor --json`'s last line, with one row per finding given.
private func doctorOutput(_ findings: [Finding]) -> [String] {
    [DoctorFindingRow.encodeLine(findings.map(\.row))]
}

@Test("Health reads the three flags from yh doctor's findings, in flag order, each with its message")
func healthFlags() throws {
    let output = doctorOutput([
        Finding("probes", "codex", "failure", "`codex` excluded from routing: probe failed"),
        Finding("probes", "claude", "pass", "`claude` is offered as a route target"),
        Finding("linear", "authorization", "failure",
         "the Linear installation was revoked or its sign-in expired; re-run the Linear step"),
        Finding("linear", "operator", "warning", "the configured Operator identity usr-1 is no longer a candidate"),
        Finding("probes", "gemini", "failure", "`gemini` has never been probed; run `yh probe gemini`")
    ])

    let flags = try #require(HealthFlag.read(doctorOutput: output))

    #expect(flags.map(\.kind) == [.staleOperatorIdentity, .appInstallationRevoked, .probeFailure, .probeFailure])
    #expect(flags[0].detail == "the configured Operator identity usr-1 is no longer a candidate")
    #expect(flags[2].detail == "`codex` excluded from routing: probe failed")
    #expect(Set(flags.map(\.id)).count == flags.count)
}

@Test("A missing Linear Installation token pair is flagged as revoked")
func missingInstallation() throws {
    let output = doctorOutput([Finding("linear", "installation", "failure", "no Linear Installation token pair found")])

    let flags = try #require(HealthFlag.read(doctorOutput: output))

    #expect(flags.map(\.kind) == [.appInstallationRevoked])
}

@Test("Findings that are none of the three flags raise no flag")
func otherFindings() throws {
    let output = doctorOutput([
        Finding("configuration", "demo", "pass", "Project demo is valid"),
        Finding("git", "demo", "failure", "Project demo repo app at /nonexistent does not exist"),
        Finding("launchd", "demo", "warning", "no LaunchAgent installed for Project demo"),
        Finding("linear", "authorization", "failure", "Linear could not be reached"),
        Finding("linear", "authorization", "pass", "Linear authorization succeeded"),
        Finding("linear", "operator", "pass", "Operator identity usr-1 is a candidate")
    ])

    #expect(HealthFlag.read(doctorOutput: output) == [])
}

@Test("Output without the findings array is not read, rather than read as no flags")
func unreadableOutput() {
    #expect(HealthFlag.read(doctorOutput: []) == nil)
    #expect(HealthFlag.read(doctorOutput: ["[FAIL] git: Project demo repo app does not exist", ""]) == nil)
}

@Test("Only the last non-empty line is the findings array")
func lastLine() throws {
    let findings = doctorOutput([Finding("probes", "codex", "failure", "probe failed")])
    let output = ["some earlier line"] + findings + ["", " "]

    let flags = try #require(HealthFlag.read(doctorOutput: output))

    #expect(flags.map(\.kind) == [.probeFailure])
}
