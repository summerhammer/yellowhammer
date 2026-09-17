import Domain
import Foundation
import Testing

@testable import Ledger

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func createPassedProbeResult(
    cli: String,
    probedAt: Date = epoch,
    adapterVersion: String = "1.0.0",
    cliVersion: String = "1.0.0"
) -> ProbeResult {
    ProbeResult(
        cli: cli,
        probedAt: probedAt,
        adapterVersion: adapterVersion,
        cliVersion: cliVersion,
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        findingSessionResumption: .notRun,
        reason: nil
    )
}

private func createFailedProbeResult(
    cli: String,
    probedAt: Date = epoch,
    adapterVersion: String = "1.0.0",
    cliVersion: String = "1.0.0",
    failingFinding: ProbeFinding = .failed,
    reason: String = "Probe failed"
) -> ProbeResult {
    ProbeResult(
        cli: cli,
        probedAt: probedAt,
        adapterVersion: adapterVersion,
        cliVersion: cliVersion,
        findingResultFileOnCleanExit: failingFinding == .failed ? .failed : .passed,
        findingUnattendedDispatch: failingFinding == .failed ? .failed : .passed,
        findingProcessContainment: failingFinding == .failed ? .failed : .passed,
        findingSessionResumption: .notRun,
        reason: reason
    )
}

@Test("ADR-003: The Ledger schema has exactly one table: probe_result")
func schemaHasExactlyOneTable() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let tableNames = try store.tableNames()
    #expect(tableNames == ["probe_result"])
}

@Test("Create-on-first-use at the default path under a fake home directory")
func createOnFirstUseAtDefaultPath() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appending(component: "yh-ledger-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configDir = tempDir.appending(components: ".config", "yellowhammer", directoryHint: .isDirectory)
    let expectedPath = configDir.appending(components: "ledger.db", directoryHint: .notDirectory)

    let store = try LedgerStore.open(configurationDirectory: configDir)
    #expect(store.fileURL == expectedPath)
    #expect(FileManager.default.fileExists(atPath: expectedPath.path))
}

@Test("Path is <config>/ledger.db with no Project component")
func pathIsConfigLedgerDB() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let expected = fixture.directory.appending(components: "ledger.db", directoryHint: .notDirectory)
    #expect(store.fileURL == expected)
}

@Test("Record and read back: recorded value equals value read back (timestamp flooring)")
func recordAndReadBackTimestampFlooring() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let now = Date(timeIntervalSince1970: 1_800_000_000.6) // 0.6 seconds, should floor to .0
    let storedNow = LedgerStore.stored(now)

    let result = ProbeResult(
        cli: "test-cli",
        probedAt: now,
        adapterVersion: "1.0.0",
        cliVersion: "2.0.0",
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        findingSessionResumption: .notRun,
        reason: nil
    )

    let recorded = try store.record(result)

    #expect(recorded.probedAt == storedNow)
    #expect(recorded.probedAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) == 0)

    let latest = try store.latestProbeResult(cli: "test-cli")
    #expect(latest == recorded)
}

@Test("Record several Probe Results for two different CLIs")
func recordMultipleCLIs() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let cli1Result1 = createPassedProbeResult(cli: "cli-1", adapterVersion: "1.0.0", cliVersion: "1.0.0")
    let cli1Result2 = ProbeResult(
        cli: "cli-1",
        probedAt: epoch.addingTimeInterval(60),
        adapterVersion: "1.1.0",
        cliVersion: "1.0.1",
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        findingSessionResumption: .notRun,
        reason: nil
    )
    let cli2Result1 = createPassedProbeResult(cli: "cli-2", adapterVersion: "2.0.0", cliVersion: "2.0.0")

    _ = try store.record(cli1Result1)
    _ = try store.record(cli1Result2)
    _ = try store.record(cli2Result1)

    let cli1Latest = try store.latestProbeResult(cli: "cli-1")
    #expect(cli1Latest?.adapterVersion == "1.1.0")

    let cli2Latest = try store.latestProbeResult(cli: "cli-2")
    #expect(cli2Latest?.adapterVersion == "2.0.0")
}

@Test("latestProbeResult(cli:) returns the newest for that CLI and is unaffected by the other CLI's rows")
func latestIsUnaffectedByOtherCLI() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let cli1 = createPassedProbeResult(cli: "cli-1", adapterVersion: "1.0.0")
    let cli2First = createPassedProbeResult(cli: "cli-2", adapterVersion: "2.0.0")
    let cli2Second = ProbeResult(
        cli: "cli-2",
        probedAt: epoch.addingTimeInterval(120),
        adapterVersion: "2.1.0",
        cliVersion: "2.0.1",
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        findingSessionResumption: .notRun,
        reason: nil
    )

    _ = try store.record(cli1)
    _ = try store.record(cli2First)
    _ = try store.record(cli2Second)

    let cli1Latest = try store.latestProbeResult(cli: "cli-1")
    #expect(cli1Latest?.adapterVersion == "1.0.0")

    let cli2Latest = try store.latestProbeResult(cli: "cli-2")
    #expect(cli2Latest?.adapterVersion == "2.1.0")
}

@Test("History is newest-first")
func historyIsNewestFirst() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let result1 = createPassedProbeResult(cli: "test-cli", adapterVersion: "1.0.0")
    let result2 = ProbeResult(
        cli: "test-cli",
        probedAt: epoch.addingTimeInterval(60),
        adapterVersion: "1.1.0",
        cliVersion: "1.0.1",
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        findingSessionResumption: .notRun,
        reason: nil
    )
    let result3 = ProbeResult(
        cli: "test-cli",
        probedAt: epoch.addingTimeInterval(120),
        adapterVersion: "1.2.0",
        cliVersion: "1.0.2",
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        findingSessionResumption: .notRun,
        reason: nil
    )

    _ = try store.record(result1)
    _ = try store.record(result2)
    _ = try store.record(result3)

    let history = try store.probeResults(cli: "test-cli")
    #expect(history.count == 3)
    #expect(history[0].adapterVersion == "1.2.0")
    #expect(history[1].adapterVersion == "1.1.0")
    #expect(history[2].adapterVersion == "1.0.0")
}

@Test("A failing probe's verdict and its Operator-facing reason round-trip")
func failingProbeRoundTrips() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let failedResult = ProbeResult(
        cli: "bad-cli",
        probedAt: epoch,
        adapterVersion: "1.0.0",
        cliVersion: "1.0.0",
        findingResultFileOnCleanExit: .failed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        findingSessionResumption: .notRun,
        reason: "CLI does not generate result files on clean exit"
    )

    _ = try store.record(failedResult)

    let retrieved = try store.latestProbeResult(cli: "bad-cli")
    #expect(retrieved?.verdict == .failed)
    #expect(retrieved?.reason == "CLI does not generate result files on clean exit")
}

@Test("A failed CLI's latest result is distinguishable from a passing one")
func failedVsPassingDistinguishable() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let passedResult = createPassedProbeResult(cli: "good-cli")
    let failedResult = ProbeResult(
        cli: "bad-cli",
        probedAt: epoch,
        adapterVersion: "1.0.0",
        cliVersion: "1.0.0",
        findingResultFileOnCleanExit: .failed,
        findingUnattendedDispatch: .failed,
        findingProcessContainment: .failed,
        findingSessionResumption: .notRun,
        reason: "Multiple probe targets failed"
    )

    _ = try store.record(passedResult)
    _ = try store.record(failedResult)

    let goodLatest = try store.latestProbeResult(cli: "good-cli")
    #expect(goodLatest?.verdict == .passed)
    #expect(goodLatest?.reason == nil)

    let badLatest = try store.latestProbeResult(cli: "bad-cli")
    #expect(badLatest?.verdict == .failed)
    #expect(badLatest?.reason != nil)
}

@Test("Two concurrent writers from different processes both record Probe Results without conflict")
func concurrentWritersNoConflict() async throws {
    let fixture = try LedgerFixture()

    let result1 = createPassedProbeResult(cli: "cli-from-project-1", adapterVersion: "1.0.0")
    let result2 = ProbeResult(
        cli: "cli-from-project-2",
        probedAt: epoch.addingTimeInterval(1),
        adapterVersion: "2.0.0",
        cliVersion: "2.0.0",
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        findingSessionResumption: .notRun,
        reason: nil
    )

    // Simulate two processes by opening two separate store instances to the same file
    let store1 = try fixture.open()
    let store2 = try fixture.open()

    // Use concurrent task group to simulate real concurrency
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            _ = try store1.record(result1)
        }
        group.addTask {
            _ = try store2.record(result2)
        }
        try await group.waitForAll()
    }

    // Both results should be present
    let allResults1 = try store1.probeResults(cli: "cli-from-project-1")
    let allResults2 = try store1.probeResults(cli: "cli-from-project-2")

    #expect(allResults1.count == 1)
    #expect(allResults2.count == 1)
    #expect(allResults1[0].adapterVersion == "1.0.0")
    #expect(allResults2[0].adapterVersion == "2.0.0")
}

@Test("openReadOnly throws missing for an absent file and does not create one")
func openReadOnlyThrowsMissing() async throws {
    let nonexistentFile = FileManager.default.temporaryDirectory
        .appending(component: "nonexistent-ledger-\(UUID().uuidString).db", directoryHint: .notDirectory)

    do {
        _ = try LedgerStore.openReadOnly(at: nonexistentFile)
        Issue.record("Should have thrown missing")
    } catch let error as LedgerError {
        guard case .missing = error else {
            Issue.record("Wrong error type")
            return
        }
    }

    #expect(!FileManager.default.fileExists(atPath: nonexistentFile.path))
}

@Test("openReadOnly refuses a store with unknown applied migrations")
func openReadOnlyRefusesUnknownMigrations() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    // Write a fake unknown migration marker
    try store.write { db in
        // Insert a fake migration that this build doesn't know about
        try db.execute(
            sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
            arguments: ["v99-from-the-future"]
        )
    }

    // Now try to open read-only, should fail
    do {
        _ = try LedgerStore.openReadOnly(at: store.fileURL)
        Issue.record("Should have thrown schemaNewerThanKnown")
    } catch let error as LedgerError {
        guard case .schemaNewerThanKnown = error else {
            Issue.record("Wrong error type")
            return
        }
    }
}
