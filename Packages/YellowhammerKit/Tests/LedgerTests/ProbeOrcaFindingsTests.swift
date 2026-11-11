import Domain
import Foundation
import GRDB
@testable import Ledger
import Testing

@Suite("Orca Probe Ledger findings")
struct ProbeOrcaFindingsTests {
    private func result(_ orca: OrcaProbeFindings) -> ProbeResult {
        ProbeResult(
            cli: "codex", probedAt: Date(timeIntervalSince1970: 1_800_000_000), adapterVersion: "4", cliVersion: "1",
            findingResultFileOnCleanExit: .passed, findingUnattendedDispatch: .passed,
            findingProcessContainment: .passed, findingSessionResumption: .passed,
            findingStateContainment: .passed, orca: orca, reason: nil
        )
    }

    @Test("Every Orca observation and its evidence round trips without gating routing or drift")
    func roundTrip() throws {
        let fixture = try LedgerFixture()
        let store = try fixture.open()
        let orca = OrcaProbeFindings(
            tabRecognition: .init(.failed, detail: "no matching agent"),
            sessionHistory: .init(.passed, detail: "exact cwd"),
            sessionName: .init(.failed, detail: "first prompt used"),
            foreignTurnMarker: .init(.notRun, detail: "unsupported"),
            tabCloseContainment: .init(.passed), hookTraffic: .init(.notRun, detail: "not observed")
        )
        let recorded = try store.record(result(orca))
        #expect(try store.latestProbeResult(cli: "codex")?.orca == orca)
        #expect(try store.probeResults(cli: "codex").first?.orca == orca)
        #expect(recorded.verdict == .passed)
        #expect(try store.routeTargetEligibility(cli: "codex") == .offered)
        #expect(recorded.drift(since: result(.init(tabRecognition: .init(.passed)))) == nil)
        #expect(try store.appliedMigrations().last == "v6-probe-orca-observations")
    }

    @Test("A v5 row migrates with Orca observations unconfirmed")
    func legacyRow() throws {
        let fixture = try LedgerFixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let file = LedgerStore.defaultFileURL(configurationDirectory: fixture.directory)
        do {
            let queue = try DatabaseQueue(path: file.path)
            try LedgerMigrations.migrator.migrate(queue, upTo: "v5-probe-session-naming")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO probe_result
                    (cli, probed_at, adapter_version, cli_version, finding_result_file_on_clean_exit,
                     finding_unattended_dispatch, finding_process_containment, verdict)
                    VALUES ('codex', '2027-01-15T08:00:00Z', '4', '1', 'passed', 'passed', 'passed', 'passed')
                    """)
            }
        }
        let store = try fixture.open()
        let legacy = try #require(try store.latestProbeResult(cli: "codex"))
        #expect(legacy.orca.observations.allSatisfy { $0.1.finding == .notRun })
        #expect(legacy.verdict == .passed)
    }
}
