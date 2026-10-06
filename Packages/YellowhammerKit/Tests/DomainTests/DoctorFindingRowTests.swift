import Domain
import Testing

@Suite("DoctorFindingRow, the yh doctor --json row")
struct DoctorFindingRowTests {
    private let full = DoctorFindingRow(
        check: "linear", subject: "authorization", severity: "pass", message: "m",
        installation: "work", workspace: "ws-1", workspaceName: "Acme", projects: ["alpha", "beta"]
    )
    private let base = DoctorFindingRow(check: "linear", subject: "authorization", severity: "pass", message: "m")

    @Test("A full row encodes with sorted keys")
    func fullRowEncodes() {
        #expect(DoctorFindingRow.encodeLine([full]) == """
            [{"check":"linear","installation":"work","message":"m","projects":["alpha","beta"],\
            "severity":"pass","subject":"authorization","workspace":"ws-1","workspaceName":"Acme"}]
            """)
    }

    @Test("A row with only the four base fields omits the optional keys")
    func baseRowEncodes() {
        #expect(DoctorFindingRow.encodeLine([base])
            == #"[{"check":"linear","message":"m","severity":"pass","subject":"authorization"}]"#)
    }

    @Test("decodeLastLine round-trips full and base rows")
    func roundTrips() {
        #expect(DoctorFindingRow.decodeLastLine([DoctorFindingRow.encodeLine([full, base])]) == [full, base])
    }

    @Test("decodeLastLine reads today's old four-field row")
    func decodesOldRow() {
        let line = #"[{"check":"linear","message":"m","severity":"pass","subject":"authorization"}]"#
        #expect(DoctorFindingRow.decodeLastLine([line]) == [base])
    }

    @Test("decodeLastLine skips trailing blank lines and ignores earlier ones")
    func skipsBlankLines() {
        let line = DoctorFindingRow.encodeLine([base])
        #expect(DoctorFindingRow.decodeLastLine(["noise", line, "", "  "]) == [base])
    }

    @Test("decodeLastLine is nil for a missing or non-JSON last line")
    func nilWhenUnreadable() {
        #expect(DoctorFindingRow.decodeLastLine([]) == nil)
        #expect(DoctorFindingRow.decodeLastLine([DoctorFindingRow.encodeLine([base]), "[FAIL] git: nope"]) == nil)
    }

    @Test("authorization encodes only when set and round-trips")
    func authorizationField() {
        var row = base
        row.authorization = "refused"
        #expect(DoctorFindingRow.encodeLine([row]) == """
            [{"authorization":"refused","check":"linear","message":"m",\
            "severity":"pass","subject":"authorization"}]
            """)
        #expect(DoctorFindingRow.decodeLastLine([DoctorFindingRow.encodeLine([row])]) == [row])
    }

    @Test("authorizationState prefers the authorization row, falls back to the connection row")
    func authorizationStateAccessor() {
        func row(_ subject: String, _ installation: String, _ state: String?) -> DoctorFindingRow {
            DoctorFindingRow(
                check: "linear", subject: subject, severity: "failure", message: "m",
                installation: installation, authorization: state
            )
        }
        let rows = [
            row("operator", "acme", nil), row("connection", "acme", "refused"),
            row("authorization", "globex", "unreachable"), row("authorization", "initech", "authorized")
        ]
        #expect(DoctorFindingRow.authorizationState(in: rows, installation: "acme") == .refused)
        #expect(DoctorFindingRow.authorizationState(in: rows, installation: "globex") == .unreachable)
        #expect(DoctorFindingRow.authorizationState(in: rows, installation: "initech") == .authorized)
        #expect(DoctorFindingRow.authorizationState(in: rows, installation: "nobody") == nil)
        #expect(DoctorFindingRow.authorizationState(in: [row("authorization", "x", "bogus")], installation: "x") == nil)
    }
}
