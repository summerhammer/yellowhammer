import Domain
import Testing

@testable import Pulse

private func project(_ id: String) -> ProjectID {
    guard let value = ProjectID(rawValue: id) else { preconditionFailure("bad id \(id)") }
    return value
}

private let demo = project("demo")

/// One `yh doctor --json` row.
private struct Finding {
    let check: String
    let subject: String
    let severity: String
    let message: String
    let projects: [String]?

    init(_ check: String, _ subject: String, _ severity: String, _ message: String, projects: [String]? = nil) {
        self.check = check
        self.subject = subject
        self.severity = severity
        self.message = message
        self.projects = projects
    }

    var row: DoctorFindingRow {
        DoctorFindingRow(check: check, subject: subject, severity: severity, message: message, projects: projects)
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
         "the Linear installation was revoked or its sign-in expired; re-run the Linear step", projects: ["demo"]),
        Finding("linear", "operator", "warning",
                "the configured Operator identity usr-1 is no longer a candidate", projects: ["demo"]),
        Finding("probes", "gemini", "failure", "`gemini` has never been probed; run `yh probe gemini`")
    ])

    let flags = try #require(HealthFlag.read(doctorOutput: output, project: demo))

    #expect(flags.map(\.kind) == [.staleOperatorIdentity, .appInstallationRevoked, .probeFailure, .probeFailure])
    #expect(flags[0].detail == "the configured Operator identity usr-1 is no longer a candidate")
    #expect(flags[2].detail == "`codex` excluded from routing: probe failed")
    #expect(Set(flags.map(\.id)).count == flags.count)
}

@Test("A missing Linear Installation token pair is flagged as revoked")
func missingInstallation() throws {
    let output = doctorOutput([
        Finding("linear", "connection", "failure", "no Board Connection token pair found", projects: ["demo"])
    ])

    let flags = try #require(HealthFlag.read(doctorOutput: output, project: demo))

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

    #expect(HealthFlag.read(doctorOutput: output, project: demo) == [])
}

@Test("Output without the findings array is not read, rather than read as no flags")
func unreadableOutput() {
    #expect(HealthFlag.read(doctorOutput: [], project: demo) == nil)
    let notJSON = ["[FAIL] git: Project demo repo app does not exist", ""]
    #expect(HealthFlag.read(doctorOutput: notJSON, project: demo) == nil)
}

@Test("Only the last non-empty line is the findings array")
func lastLine() throws {
    let findings = doctorOutput([Finding("probes", "codex", "failure", "probe failed")])
    let output = ["some earlier line"] + findings + ["", " "]

    let flags = try #require(HealthFlag.read(doctorOutput: output, project: demo))

    #expect(flags.map(\.kind) == [.probeFailure])
}

@Test("Each Project sees only its own installation's flags, plus the machine-wide probe failures")
func perProjectFlags() throws {
    let acme = "the acme installation (workspace Acme) was revoked"
    let scratch = "the scratch installation (workspace Scratch): Operator identity usr-9 is no longer a candidate"
    let rows = [
        DoctorFindingRow(check: "linear", subject: "authorization", severity: "failure", message: acme,
                         installation: "acme", workspaceName: "Acme", projects: ["a", "b"]),
        DoctorFindingRow(check: "linear", subject: "operator", severity: "warning", message: scratch,
                         installation: "scratch", workspaceName: "Scratch", projects: ["c"]),
        DoctorFindingRow(check: "linear", subject: "authorization", severity: "failure",
                         message: "the old installation was revoked", installation: "old", projects: []),
        DoctorFindingRow(check: "linear", subject: "operator", severity: "warning",
                         message: "no projects field", projects: nil),
        DoctorFindingRow(check: "probes", subject: "codex", severity: "failure", message: "codex probe failed"),
        DoctorFindingRow(check: "linear", subject: "project", severity: "failure",
                         message: "Project d names a missing installation", projects: ["d"])
    ]
    let probe = HealthFlag(kind: .probeFailure, detail: "codex probe failed")

    #expect(HealthFlag.flags(in: rows, for: project("a")) ==
            [HealthFlag(kind: .appInstallationRevoked, detail: acme), probe])
    #expect(HealthFlag.flags(in: rows, for: project("b")) ==
            [HealthFlag(kind: .appInstallationRevoked, detail: acme), probe])
    #expect(HealthFlag.flags(in: rows, for: project("c")) ==
            [HealthFlag(kind: .staleOperatorIdentity, detail: scratch), probe])
    #expect(HealthFlag.flags(in: rows, for: project("d")) == [probe])
    #expect(HealthFlag.flags(in: rows, for: project("z")) == [probe])
}

@Test("An installation row with no projects field is dropped, not broadcast")
func nilProjectsDropped() {
    let rows = [DoctorFindingRow(check: "linear", subject: "connection", severity: "failure", message: "x")]
    #expect(HealthFlag.flags(in: rows, for: demo) == [])
}

@Test("A flag opens where its fix lives")
func destinations() {
    #expect(HealthFlag(kind: .staleOperatorIdentity, detail: "").destination == .linearWorkspaces)
    #expect(HealthFlag(kind: .appInstallationRevoked, detail: "").destination == .linearWorkspaces)
    #expect(HealthFlag(kind: .probeFailure, detail: "").destination == .settings)
}
