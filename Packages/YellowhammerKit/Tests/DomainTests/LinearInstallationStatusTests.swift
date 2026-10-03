import Domain
import Testing

struct LinearInstallationStatusTests {
    private func row(
        _ subject: String, _ severity: String, _ message: String = "m", installation: String? = nil,
        workspaceName: String? = nil
    ) -> DoctorFindingRow {
        DoctorFindingRow(
            check: "linear", subject: subject, severity: severity, message: message,
            installation: installation, workspaceName: workspaceName
        )
    }

    @Test("A named installation passes on its own authorization pass")
    func namedPass() {
        let rows = [row("authorization", "pass", installation: "acme")]
        #expect(LinearInstallationStatus.interpret(rows, installation: "acme") == .connected)
    }

    @Test("A named installation reports its authorization failure's message")
    func namedAuthorizationFailure() {
        let rows = [row("authorization", "failure", "revoked", installation: "acme")]
        #expect(
            LinearInstallationStatus.interpret(rows, installation: "acme")
                == .authorizationFailed(message: "revoked")
        )
    }

    @Test("A named installation with a failed installation row has no token pair")
    func namedNoTokenPair() {
        let rows = [row("installation", "failure", "no pair", installation: "acme")]
        #expect(LinearInstallationStatus.interpret(rows, installation: "acme") == .noTokenPair(message: "no pair"))
    }

    @Test("Info rows are not faults")
    func infoOnly() {
        let rows = [row("installation", "info", "unused", installation: "acme")]
        #expect(LinearInstallationStatus.interpret(rows, installation: "acme") == .unknown)
    }

    @Test("Rows of another installation are ignored")
    func otherInstallationIgnored() {
        let rows = [
            row("authorization", "failure", "revoked", installation: "other"),
            row("authorization", "pass", installation: "acme")
        ]
        #expect(LinearInstallationStatus.interpret(rows, installation: "acme") == .connected)
        #expect(LinearInstallationStatus.interpret(rows, installation: "third") == .unknown)
    }

    @Test("Without a name the first authorization row decides, and none means no token pair")
    func unnamedRule() {
        let pass = [row("installation", "info"), row("authorization", "pass"), row("authorization", "failure")]
        #expect(LinearInstallationStatus.interpret(pass, installation: nil) == .connected)
        let fail = [row("authorization", "failure", "bad")]
        #expect(LinearInstallationStatus.interpret(fail, installation: nil) == .authorizationFailed(message: "bad"))
        let none = [row("installation", "failure", "no pair")]
        #expect(LinearInstallationStatus.interpret(none, installation: nil) == .noTokenPair(message: ""))
    }

    @Test("The workspace name comes from any row of the installation")
    func workspaceNameLookup() {
        let rows = [
            row("installation", "info", installation: "acme"),
            row("authorization", "pass", installation: "acme", workspaceName: "Acme Inc"),
            row("authorization", "pass", installation: "other", workspaceName: "Other")
        ]
        #expect(LinearInstallationStatus.workspaceName(in: rows, installation: "acme") == "Acme Inc")
        #expect(LinearInstallationStatus.workspaceName(in: rows, installation: "none") == nil)
    }

    @Test("The label falls back to the local name, never blank")
    func labelFallback() {
        #expect(LinearInstallationStatus.label(workspaceName: "Acme Inc", localName: "acme") == "Acme Inc")
        #expect(LinearInstallationStatus.label(workspaceName: nil, localName: "acme") == "acme")
        #expect(LinearInstallationStatus.label(workspaceName: "  ", localName: "acme") == "acme")
    }

    @Test("Messages: connected has copy, failures carry the doctor's text, unknown has none")
    func messages() {
        #expect(LinearInstallationStatus.connected.message == "Connected.")
        #expect(LinearInstallationStatus.authorizationFailed(message: "x").message == "x")
        #expect(LinearInstallationStatus.noTokenPair(message: "").message == nil)
        #expect(LinearInstallationStatus.unknown.message == nil)
    }
}
