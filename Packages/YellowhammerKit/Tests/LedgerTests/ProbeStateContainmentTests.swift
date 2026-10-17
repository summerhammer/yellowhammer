import Domain
import Foundation
import GRDB
import Testing

@testable import Ledger

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let allFindings: [ProbeFinding] = [.passed, .failed, .notRun]

private func makeResult(
    cli: String = "test-cli",
    findingSessionResumption: ProbeFinding = .passed,
    findingStateContainment: ProbeFinding = .passed,
    cliVersion: String = "1.0.0",
    reason: String? = nil
) -> ProbeResult {
    ProbeResult(
        cli: cli,
        probedAt: epoch,
        adapterVersion: "1",
        cliVersion: cliVersion,
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        findingSessionResumption: findingSessionResumption,
        findingStateContainment: findingStateContainment,
        reason: reason
    )
}

// MARK: - v3 migration

@Test("The v3 migration is registered after v2 and applied on a fresh open")
func v3MigrationApplied() throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let expected = ["v1-probe-result-history", "v2-probe-session-resumption", "v3-probe-state-containment"]
    #expect(try store.appliedMigrations() == expected)
    #expect(LedgerStore.migrationIdentifiers == expected)
}

@Test("An existing v2 store migrates to v3, and its rows read back with state containment not run")
func v2StoreMigratesAndReadsNotRun() async throws {
    let fixture = try LedgerFixture()
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    let fileURL = LedgerStore.defaultFileURL(configurationDirectory: fixture.directory)

    // Build a store exactly as a v2 build left it, with one row it recorded.
    do {
        let queue = try DatabaseQueue(path: fileURL.path)
        try LedgerMigrations.migrator.migrate(queue, upTo: "v2-probe-session-resumption")
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO probe_result
                (cli, probed_at, adapter_version, cli_version,
                 finding_result_file_on_clean_exit, finding_unattended_dispatch,
                 finding_process_containment, finding_session_resumption, verdict, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "legacy-cli", LedgerStore.timestamp(epoch), "1", "1.0.0", "passed", "passed", "passed",
                    "passed", "passed", nil
                ]
            )
        }
    }

    // Opening normally migrates the v2 store the rest of the way.
    let store = try fixture.open()
    #expect(try store.appliedMigrations().last == "v3-probe-state-containment")
    let latest = try #require(try store.latestProbeResult(cli: "legacy-cli"))
    #expect(latest.findingStateContainment == .notRun)
    #expect(latest.findingSessionResumption == .passed)
    #expect(latest.verdict == .passed)

    // The read-only opener the app uses reads the migrated row the same way.
    let readOnly = try LedgerStore.openReadOnly(at: store.fileURL)
    #expect(try readOnly.latestProbeResult(cli: "legacy-cli")?.findingStateContainment == .notRun)
}

@Test("The v3 column refuses a value that is not a finding")
func v3ColumnChecksItsValue() throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    #expect(throws: (any Error).self) {
        try store.write { db in
            try db.execute(
                sql: """
                INSERT INTO probe_result
                (cli, probed_at, adapter_version, cli_version,
                 finding_result_file_on_clean_exit, finding_unattended_dispatch,
                 finding_process_containment, finding_session_resumption, finding_state_containment,
                 verdict, reason)
                VALUES ('bad-cli', ?, '1', '1', 'passed', 'passed', 'passed', 'passed', 'leaky', 'passed', NULL)
                """,
                arguments: [LedgerStore.timestamp(epoch)]
            )
        }
    }
}

@Test("findingStateContainment round-trips through record and read", arguments: allFindings)
func findingStateContainmentRoundTrips(finding: ProbeFinding) throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let reason: String? = finding == .passed ? nil : "state containment: config readable"
    _ = try store.record(makeResult(cli: "state-cli", findingStateContainment: finding, reason: reason))

    let latest = try #require(try store.latestProbeResult(cli: "state-cli"))
    #expect(latest.findingStateContainment == finding)
}

// MARK: - Verdict and drift

@Test("The verdict ignores state containment", arguments: allFindings)
func verdictIgnoresStateContainment(finding: ProbeFinding) {
    #expect(makeResult(findingStateContainment: finding).verdict == .passed)
}

@Test("A failed state containment leaves a CLI offered as a route target")
func failedStateContainmentStaysOffered() throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()
    _ = try store.record(
        makeResult(cli: "agy", findingStateContainment: .failed, reason: "state containment: config readable")
    )

    #expect(try store.routeTargetEligibility(cli: "agy") == .offered)
}

@Test("drift(since:) reports a state containment regression")
func driftReportsStateContainmentRegression() throws {
    let previous = makeResult(findingStateContainment: .passed)
    let current = makeResult(
        findingStateContainment: .failed, cliVersion: "1.1.0", reason: "state containment: keychain readable"
    )

    let drift = try #require(current.drift(since: previous))
    #expect(drift.regressions == [.stateContainment])
    #expect(ProbeTarget.stateContainment.description == "state containment")
}

@Test("No drift when state containment was never measured before")
func noDriftFromNotRunStateContainment() {
    let previous = makeResult(findingStateContainment: .notRun)
    let current = makeResult(findingStateContainment: .failed, reason: "state containment: config readable")

    #expect(current.drift(since: previous) == nil)
}
