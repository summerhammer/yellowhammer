import Domain
import Foundation
import GRDB
import Testing

@testable import Ledger

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func makeResult(cli: String = "run-cli", promptRunID: String? = nil) -> ProbeResult {
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
        reason: nil,
        promptRunID: promptRunID
    )
}

@Test("promptRunID round-trips through record, latest and history")
func promptRunIDRoundTrips() throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let recorded = try store.record(makeResult(promptRunID: "0a1b2c3d-run"))

    #expect(recorded.promptRunID == "0a1b2c3d-run")
    #expect(try store.latestProbeResult(cli: "run-cli")?.promptRunID == "0a1b2c3d-run")
    #expect(try store.probeResults(cli: "run-cli").first?.promptRunID == "0a1b2c3d-run")
}

@Test("A result written without a promptRunID reads back nil")
func promptRunIDDefaultsToNil() throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    _ = try store.record(makeResult())

    #expect(try store.latestProbeResult(cli: "run-cli")?.promptRunID == nil)
}

@Test("An existing v3 store migrates to v4, and its rows read back with no promptRunID")
func v3StoreMigratesAndReadsNil() async throws {
    let fixture = try LedgerFixture()
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    let fileURL = LedgerStore.defaultFileURL(configurationDirectory: fixture.directory)

    // Build a store exactly as a v3 build left it, with one row it recorded.
    do {
        let queue = try DatabaseQueue(path: fileURL.path)
        try LedgerMigrations.migrator.migrate(queue, upTo: "v3-probe-state-containment")
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
    #expect(try store.appliedMigrations().last == "v4-probe-prompt-run-id")
    let latest = try #require(try store.latestProbeResult(cli: "legacy-cli"))
    #expect(latest.promptRunID == nil)
    #expect(latest.findingStateContainment == .passed)
}
