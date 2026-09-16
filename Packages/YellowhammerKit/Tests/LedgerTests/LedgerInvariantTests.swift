import Foundation
import GRDB
import Testing

@testable import Ledger

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test("Two results recorded at the same second: latest tiebreak uses id DESC")
func tiebreakOnSameSecond() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let sameProbedAt = epoch
    let result1 = ProbeResult(
        cli: "test-cli",
        probedAt: sameProbedAt,
        adapterVersion: "1.0.0",
        cliVersion: "1.0.0",
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        reason: nil
    )

    let result2 = ProbeResult(
        cli: "test-cli",
        probedAt: sameProbedAt,
        adapterVersion: "2.0.0",
        cliVersion: "2.0.0",
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        reason: nil
    )

    _ = try store.record(result1)
    _ = try store.record(result2)

    // Latest should be the second one recorded (higher id)
    let latest = try store.latestProbeResult(cli: "test-cli")
    #expect(latest?.adapterVersion == "2.0.0")

    // History should have both, second first
    let history = try store.probeResults(cli: "test-cli")
    #expect(history.count == 2)
    #expect(history[0].adapterVersion == "2.0.0")
    #expect(history[1].adapterVersion == "1.0.0")
}

@Test("A mixed-findings result records and reads back as failed")
func mixedFindingsIsFailedVerdict() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    let mixed = ProbeResult(
        cli: "mixed-cli",
        probedAt: epoch,
        adapterVersion: "1.0.0",
        cliVersion: "1.0.0",
        findingResultFileOnCleanExit: .failed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        reason: "Result file finding failed"
    )

    let recorded = try store.record(mixed)
    #expect(recorded.verdict == .failed)

    let retrieved = try store.latestProbeResult(cli: "mixed-cli")
    #expect(retrieved?.verdict == .failed)
    #expect(retrieved?.findingResultFileOnCleanExit == .failed)
    #expect(retrieved?.findingUnattendedDispatch == .passed)
}

@Test("A hand-written row with disagreeing verdict is refused on read")
func disagreeingVerdictThrowsUnreadable() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    // Insert a valid row first
    let valid = ProbeResult(
        cli: "test-cli",
        probedAt: epoch,
        adapterVersion: "1.0.0",
        cliVersion: "1.0.0",
        findingResultFileOnCleanExit: .passed,
        findingUnattendedDispatch: .passed,
        findingProcessContainment: .passed,
        reason: nil
    )
    _ = try store.record(valid)

    // Now inject a row with disagreeing verdict using raw SQL
    try store.write { db in
        try db.execute(
            sql: """
            INSERT INTO probe_result
            (cli, probed_at, adapter_version, cli_version,
             finding_result_file_on_clean_exit, finding_unattended_dispatch,
             finding_process_containment, verdict, reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "test-cli",
                LedgerStore.timestamp(epoch.addingTimeInterval(60)),
                "1.0.0",
                "1.0.0",
                "failed",
                "failed",
                "failed",
                "passed",  // Disagreeing verdict (should be failed)
                nil
            ]
        )
    }

    // Attempting to read should fail
    do {
        _ = try store.latestProbeResult(cli: "test-cli")
        Issue.record("Should have thrown probeResultUnreadable")
    } catch let error as LedgerError {
        guard case .probeResultUnreadable = error else {
            Issue.record("Wrong error type")
            return
        }
    }
}

@Test("A failed verdict without a reason is rejected at the store level")
func failedWithoutReasonIsRejected() async throws {
    let fixture = try LedgerFixture()
    let store = try fixture.open()

    // Try to insert a failed verdict without a reason using raw SQL
    do {
        try store.write { db in
            try db.execute(
                sql: """
                INSERT INTO probe_result
                (cli, probed_at, adapter_version, cli_version,
                 finding_result_file_on_clean_exit, finding_unattended_dispatch,
                 finding_process_containment, verdict, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "bad-cli",
                    LedgerStore.timestamp(epoch),
                    "1.0.0",
                    "1.0.0",
                    "failed",
                    "passed",
                    "passed",
                    "failed",
                    nil  // No reason with failed verdict
                ]
            )
        }
        Issue.record("Should have been rejected by CHECK constraint")
    } catch let error as DatabaseError {
        // The table's CHECK constraint, not some other failure on the way to it.
        #expect(error.resultCode == .SQLITE_CONSTRAINT)
    }
}
