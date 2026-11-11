import Domain
import Foundation
import GRDB
import Testing

@testable import Ledger

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let allFindings: [ProbeFinding] = [.passed, .failed, .notRun]

private func makeResult(
    cli: String = "test-cli",
    findingSessionNaming: ProbeFinding = .passed,
    reason: String? = nil
) -> ProbeResult {
    ProbeResult(
        cli: cli,
        probedAt: epoch,
        adapterVersion: "1",
        cliVersion: "1.0.0",
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        findingSessionResumption: .passed,
        findingStateContainment: .passed,
        findingSessionNaming: findingSessionNaming,
        reason: reason
    )
}

@Test("The v5 migration remains registered and applied on a fresh open")
func v5MigrationApplied() throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    #expect(try store.appliedMigrations().contains("v5-probe-session-naming"))
    #expect(LedgerStore.migrationIdentifiers.contains("v5-probe-session-naming"))
}

@Test("findingSessionNaming round-trips through record and read", arguments: allFindings)
func findingSessionNamingRoundTrips(finding: ProbeFinding) throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    _ = try store.record(makeResult(cli: "naming-cli", findingSessionNaming: finding))

    let latest = try #require(try store.latestProbeResult(cli: "naming-cli"))
    #expect(latest.findingSessionNaming == finding)
    #expect(try store.probeResults(cli: "naming-cli").first?.findingSessionNaming == finding)
}

@Test("A row recorded before v5 reads back with session naming not run")
func v4RowReadsNotRun() async throws {
    let fixture = try LedgerFixture()
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    let fileURL = LedgerStore.defaultFileURL(configurationDirectory: fixture.directory)

    do {
        let queue = try DatabaseQueue(path: fileURL.path)
        try LedgerMigrations.migrator.migrate(queue, upTo: "v4-probe-prompt-run-id")
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO probe_result
                (cli, probed_at, adapter_version, cli_version,
                 finding_result_file_on_clean_exit, finding_unattended_dispatch,
                 finding_process_containment, finding_session_resumption, finding_state_containment,
                 verdict, reason)
                VALUES ('legacy-cli', ?, '1', '1.0.0', 'passed', 'passed', 'passed', 'passed', 'passed', 'passed', NULL)
                """,
                arguments: [LedgerStore.timestamp(epoch)]
            )
        }
    }

    let store = try fixture.open()
    #expect(try store.appliedMigrations().contains("v5-probe-session-naming"))
    let latest = try #require(try store.latestProbeResult(cli: "legacy-cli"))
    #expect(latest.findingSessionNaming == .notRun)
    #expect(latest.verdict == .passed)
}

@Test("The v5 column refuses a value that is not a finding")
func v5ColumnChecksItsValue() throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    #expect(throws: (any Error).self) {
        try store.write { db in
            try db.execute(
                sql: """
                INSERT INTO probe_result
                (cli, probed_at, adapter_version, cli_version,
                 finding_result_file_on_clean_exit, finding_unattended_dispatch,
                 finding_process_containment, finding_session_resumption, finding_session_naming,
                 verdict, reason)
                VALUES ('bad-cli', ?, '1', '1', 'passed', 'passed', 'passed', 'passed', 'nameless', 'passed', NULL)
                """,
                arguments: [LedgerStore.timestamp(epoch)]
            )
        }
    }
}

@Test("The verdict ignores session naming", arguments: allFindings)
func verdictIgnoresSessionNaming(finding: ProbeFinding) {
    #expect(makeResult(findingSessionNaming: finding).verdict == .passed)
}

@Test("A failed session naming leaves a CLI offered as a route target")
func failedSessionNamingStaysOffered() throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()
    _ = try store.record(makeResult(cli: "codex", findingSessionNaming: .failed, reason: "session naming: none"))

    #expect(try store.routeTargetEligibility(cli: "codex") == .offered)
}

@Test("drift(since:) reports a session naming regression")
func driftReportsSessionNamingRegression() throws {
    let previous = makeResult(findingSessionNaming: .passed)
    let current = makeResult(findingSessionNaming: .failed, reason: "session naming: none")

    let drift = try #require(current.drift(since: previous))
    #expect(drift.regressions == [.sessionNaming])
    #expect(ProbeTarget.sessionNaming.description == "session naming")
    #expect(current.finding(for: .sessionNaming) == .failed)
}

@Test("A session naming that was never passed is not a regression")
func notRunSessionNamingIsNotARegression() {
    #expect(makeResult(findingSessionNaming: .notRun).drift(since: makeResult(findingSessionNaming: .notRun)) == nil)
}
