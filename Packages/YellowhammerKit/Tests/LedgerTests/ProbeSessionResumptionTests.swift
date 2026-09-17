import Domain
import Foundation
import GRDB
import Testing

@testable import Ledger

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func makeResult(
    cli: String = "test-cli",
    probedAt: Date = epoch,
    findingResultFileOnCleanExit: ProbeFinding = .passed,
    findingUnattendedDispatch: ProbeFinding = .passed,
    findingProcessContainment: ProbeFinding = .passed,
    findingSessionResumption: ProbeFinding = .passed,
    adapterVersion: String = "1.0.0",
    cliVersion: String = "1.0.0",
    reason: String? = nil
) -> ProbeResult {
    ProbeResult(
        cli: cli,
        probedAt: probedAt,
        adapterVersion: adapterVersion,
        cliVersion: cliVersion,
        findingResultFileOnCleanExit: findingResultFileOnCleanExit,
        findingUnattendedDispatch: findingUnattendedDispatch,
        findingProcessContainment: findingProcessContainment,
        findingSessionResumption: findingSessionResumption,
        reason: reason
    )
}

// MARK: - v2 migration

@Test("The v2 migration is registered and applied on a fresh open")
func v2MigrationApplied() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let applied = try store.appliedMigrations()
    #expect(applied == ["v1-probe-result-history", "v2-probe-session-resumption"])
    #expect(LedgerStore.migrationIdentifiers == ["v1-probe-result-history", "v2-probe-session-resumption"])
}

@Test("openReadOnly still succeeds once fully migrated through v2")
func openReadOnlyStillCorrectAfterV2() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()
    _ = try store.record(makeResult())

    let readOnly = try LedgerStore.openReadOnly(at: store.fileURL)
    let latest = try readOnly.latestProbeResult(cli: "test-cli")
    #expect(latest?.findingSessionResumption == .passed)
}

@Test("A v1-only row reads back with findingSessionResumption == .notRun once migrated to v2")
func v1RowReadsBackAsNotRun() async throws {
    let fixture = try LedgerFixture()

    // Open a bare DatabaseQueue and migrate only to v1, bypassing LedgerStore.open (which would
    // migrate all the way to the current schema).
    let directory = fixture.directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = LedgerStore.defaultFileURL(configurationDirectory: directory)
    let queue = try DatabaseQueue(path: fileURL.path)
    try LedgerMigrations.migrator.migrate(queue, upTo: "v1-probe-result-history")

    try await queue.write { db in
        try db.execute(
            sql: """
            INSERT INTO probe_result
            (cli, probed_at, adapter_version, cli_version,
             finding_result_file_on_clean_exit, finding_unattended_dispatch,
             finding_process_containment, verdict, reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "legacy-cli", LedgerStore.timestamp(epoch), "1.0.0", "1.0.0", "passed", "passed", "passed",
                "passed", nil
            ]
        )
    }

    // Now open normally: this migrates the v1-only store the rest of the way to v2.
    let store = try fixture.open()
    let latest = try store.latestProbeResult(cli: "legacy-cli")
    #expect(latest?.findingSessionResumption == .notRun)
    #expect(latest?.verdict == .passed)
}

@Test("findingSessionResumption round-trips through record and read")
func findingSessionResumptionRoundTrips() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let failedResumption = makeResult(cli: "resumption-cli", findingSessionResumption: .failed, reason: "no resume")
    _ = try store.record(failedResumption)

    let latest = try store.latestProbeResult(cli: "resumption-cli")
    #expect(latest?.findingSessionResumption == .failed)
    // Session resumption does not gate the verdict.
    #expect(latest?.verdict == .passed)
}

// MARK: - Drift

@Test("Drift is detected when a previously passing target regresses")
func driftDetectedOnRegression() async throws {
    let previous = makeResult(adapterVersion: "1", cliVersion: "1.0.0")
    let current = makeResult(
        findingUnattendedDispatch: .failed, adapterVersion: "1", cliVersion: "1.1.0", reason: "regressed"
    )

    let drift = try #require(current.drift(since: previous))
    #expect(drift.regressions == [ProbeTarget.unattendedDispatch])
    #expect(drift.previousCLIVersion == "1.0.0")
    #expect(drift.currentCLIVersion == "1.1.0")
}

@Test("No drift when nothing regressed")
func noDriftWhenNothingRegressed() async throws {
    let previous = makeResult()
    let current = makeResult(cliVersion: "1.1.0")

    #expect(current.drift(since: previous) == nil)
}

@Test("No drift when the target was already not passing in the previous result")
func noDriftWhenPreviousWasNotPassing() async throws {
    let previous = makeResult(findingSessionResumption: .failed, reason: "already broken")
    let current = makeResult(findingSessionResumption: .notRun)

    #expect(current.drift(since: previous) == nil)
}

// MARK: - Route target eligibility

@Test("A never-probed CLI is excluded, naming the probe command")
func eligibilityNeverProbed() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let eligibility = try store.routeTargetEligibility(cli: "ghost-cli")
    guard case .excluded(let reason) = eligibility else {
        Issue.record("expected .excluded, got \(eligibility)")
        return
    }
    #expect(reason.contains("ghost-cli"))
    #expect(reason.contains("yh probe ghost-cli"))
}

@Test("A CLI whose latest Probe Result failed is excluded, surfacing its reason")
func eligibilityFailedSurfacesReason() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()
    _ = try store.record(makeResult(
        cli: "bad-cli", findingUnattendedDispatch: .failed, reason: "no interactive dispatch"
    ))

    let eligibility = try store.routeTargetEligibility(cli: "bad-cli")
    #expect(eligibility == .excluded(reason: "no interactive dispatch"))
}

@Test("A CLI whose latest Probe Result passed is offered")
func eligibilityPassedIsOffered() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()
    _ = try store.record(makeResult(cli: "good-cli"))

    #expect(try store.routeTargetEligibility(cli: "good-cli") == .offered)
}

@Test("The latest row wins: a failed row followed by a passed row is offered")
func eligibilityLatestRowWins() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()
    _ = try store.record(makeResult(
        cli: "flaky-cli", probedAt: epoch, findingUnattendedDispatch: .failed, reason: "was broken"
    ))
    _ = try store.record(makeResult(cli: "flaky-cli", probedAt: epoch.addingTimeInterval(60)))

    #expect(try store.routeTargetEligibility(cli: "flaky-cli") == .offered)
}
