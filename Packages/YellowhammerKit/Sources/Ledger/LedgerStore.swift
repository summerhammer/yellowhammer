import Darwin
import Domain
import Foundation
import GRDB

/// One machine's Ledger, outside every Project. Multiple writers from different invocations
/// of different Projects write concurrently without conflict. The Ledger holds only Probe Result
/// history per agent CLI; no Bounds, lane leases, Project roster, schedule or mode column.
public final class LedgerStore: Sendable {
    public let fileURL: URL
    private let queue: DatabaseQueue

    /// How long a connection waits for SQLite's lock before failing with `SQLITE_BUSY`. Many
    /// Projects' invocations write concurrently, and WAL mode serialises them on the lock without
    /// failure.
    static let busyTimeout: TimeInterval = 5

    private init(fileURL: URL, queue: DatabaseQueue) {
        self.fileURL = fileURL
        self.queue = queue
    }

    /// Returns `<configurationDirectory>/ledger.db` (spec G-3). The Ledger path is fixed: one per
    /// machine, outside every Project.
    public static func defaultFileURL(configurationDirectory: URL) -> URL {
        configurationDirectory.appending(components: "ledger.db", directoryHint: .notDirectory)
    }

    /// Returns `~/.config/yellowhammer/ledger.db` under the given home directory (spec G-3).
    public static func defaultFileURL(homeDirectory: URL) -> URL {
        let configurationDirectory = homeDirectory
            .appending(components: ".config", "yellowhammer", directoryHint: .isDirectory)
        return defaultFileURL(configurationDirectory: configurationDirectory)
    }

    /// The engine's open, for any Project invocation: creates the file and its parent directory
    /// on first use and migrates forward to the current schema. Multiple invocations open concurrently.
    /// WAL journal mode serialises writers without failing.
    public static func open(configurationDirectory: URL) throws -> LedgerStore {
        let fileURL = defaultFileURL(configurationDirectory: configurationDirectory)
        return try open(at: fileURL)
    }

    /// Convenience: `open(configurationDirectory:)` under `~/.config/yellowhammer`.
    public static func open(homeDirectory: URL) throws -> LedgerStore {
        try open(at: defaultFileURL(homeDirectory: homeDirectory))
    }

    /// Opens the Ledger at an explicit path. Internal so that tests can use fixture paths.
    static func open(at fileURL: URL) throws -> LedgerStore {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Many invocations, from different processes, may reach a fresh (or behind) file at once
        // (spec G-3). Each opens its own connection, so nothing before this lock is safe to race:
        // two openers can both hit SQLite's own lock while switching a brand-new file to WAL
        // ("database is locked"), and even past that, GRDB's migrator does not serialise DDL
        // across processes — two openers can both see no `grdb_migrations` table and both try
        // `CREATE TABLE probe_result`, and the loser fails with "table already exists" instead of
        // completing migrated. An exclusive flock on a sibling lock file, held for the connection's
        // WAL switch and its migration together, serialises every process through both: the first
        // one through does the real work, and everyone after finds nothing left to do.
        let queue = try withMigrationLock(for: fileURL) {
            var config = Configuration()
            config.foreignKeysEnabled = true
            config.busyMode = .timeout(busyTimeout)
            // Enable WAL journal mode for concurrent writers. Multiple Projects' invocations write
            // concurrently; WAL lets them serialise on SQLite's lock instead of failing with SQLITE_BUSY.
            config.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }

            let queue = try DatabaseQueue(path: fileURL.path, configuration: config)
            try LedgerMigrations.migrator.migrate(queue)
            return queue
        }

        return LedgerStore(fileURL: fileURL, queue: queue)
    }

    /// Runs `body` (opening the connection and migrating it) while holding an exclusive `flock` on
    /// `<fileURL>.lock`, so concurrent openers from different processes — each with their own
    /// connection — serialise on both the WAL switch and the migration instead of racing SQLite's
    /// own locking and schema DDL. If the lock file cannot be created or locked, `body` still runs
    /// directly: a single process's own open remains safe on its own, just not against a sibling
    /// process racing it.
    private static func withMigrationLock<T>(for fileURL: URL, _ body: () throws -> T) throws -> T {
        let lockPath = fileURL.path + ".lock"
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            return try body()
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            return try body()
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// The app's open: read-only, never migrates. Throws LedgerError.schemaNewerThanKnown if the store has
    /// migrations this build does not know, and LedgerError.schemaBehind if not fully migrated (only the
    /// engine migrates). Throws LedgerError.missing if the file does not exist (never creates a file).
    public static func openReadOnly(at fileURL: URL) throws -> LedgerStore {
        // Check file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LedgerError.missing(path: fileURL.path)
        }

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.readonly = true
        config.busyMode = .timeout(busyTimeout)

        let queue = try DatabaseQueue(path: fileURL.path, configuration: config)

        // Check schema state
        try queue.read { db in
            // Check if grdb_migrations table exists
            if try !db.tableExists("grdb_migrations") {
                throw LedgerError.schemaBehind(path: fileURL.path, pending: LedgerMigrations.migrationIdentifiers)
            }

            let appliedSet = try LedgerMigrations.migrator.appliedIdentifiers(db)
            let knownIdentifiers = LedgerMigrations.migrationIdentifiers

            // Check if there are unknown migrations
            let unknown = Array(appliedSet).filter { !knownIdentifiers.contains($0) }.sorted()
            if !unknown.isEmpty {
                throw LedgerError.schemaNewerThanKnown(path: fileURL.path, unknown: unknown)
            }

            // Check if there are pending migrations
            let pending = knownIdentifiers.filter { !appliedSet.contains($0) }
            if !pending.isEmpty {
                throw LedgerError.schemaBehind(path: fileURL.path, pending: pending)
            }
        }

        return LedgerStore(fileURL: fileURL, queue: queue)
    }

    /// Identifiers of the migrations this build knows, in order. Last one is the current schema version.
    public static var migrationIdentifiers: [String] {
        LedgerMigrations.migrationIdentifiers
    }

    /// Identifiers applied to this store, in order.
    public func appliedMigrations() throws -> [String] {
        try queue.read { db in
            let appliedSet = try LedgerMigrations.migrator.appliedIdentifiers(db)
            let knownIdentifiers = LedgerMigrations.migrationIdentifiers

            // Order by position in migrationIdentifiers, then unknown identifiers sorted
            let ordered = knownIdentifiers.filter { appliedSet.contains($0) }
            let unknown = Array(appliedSet).filter { !knownIdentifiers.contains($0) }.sorted()
            return ordered + unknown
        }
    }

    /// Table names present, sorted. For tests and `yh doctor`. Must be exactly ["probe_result"]
    /// per ADR-003: no machine-wide bounds, no lane leases, no lane reservations, no currency tracking.
    public func tableNames() throws -> [String] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                ORDER BY name
                """
            )
            return rows.compactMap { $0["name"] as? String }
        }
    }

    /// Record a new Probe Result for an agent CLI. One write transaction.
    public func record(_ probeResult: ProbeResult) throws -> ProbeResult {
        let storedProbedAt = LedgerStore.stored(probeResult.probedAt)
        let storedResult = ProbeResult(
            cli: probeResult.cli,
            probedAt: storedProbedAt,
            adapterVersion: probeResult.adapterVersion,
            cliVersion: probeResult.cliVersion,
            findingResultFileOnCleanExit: probeResult.findingResultFileOnCleanExit,
            findingUnattendedDispatch: probeResult.findingUnattendedDispatch,
            findingProcessContainment: probeResult.findingProcessContainment,
            findingSessionResumption: probeResult.findingSessionResumption,
            reason: probeResult.reason
        )

        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO probe_result
                (cli, probed_at, adapter_version, cli_version,
                 finding_result_file_on_clean_exit, finding_unattended_dispatch,
                 finding_process_containment, finding_session_resumption, verdict, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    storedResult.cli,
                    LedgerStore.timestamp(storedResult.probedAt),
                    storedResult.adapterVersion,
                    storedResult.cliVersion,
                    storedResult.findingResultFileOnCleanExit.rawValue,
                    storedResult.findingUnattendedDispatch.rawValue,
                    storedResult.findingProcessContainment.rawValue,
                    storedResult.findingSessionResumption.rawValue,
                    // Verdict is computed from findings; this materializes it for query efficiency.
                    storedResult.verdict.rawValue,
                    storedResult.reason
                ]
            )
        }

        return storedResult
    }

    /// The latest Probe Result for a given agent CLI, or nil if none has been recorded.
    /// Health is derived by callers from this plus its age; no health column is stored.
    /// Timestamps are floored to seconds, so a secondary id DESC sort breaks ties deterministically.
    public func latestProbeResult(cli: String) throws -> ProbeResult? {
        try queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT cli, probed_at, adapter_version, cli_version,
                       finding_result_file_on_clean_exit, finding_unattended_dispatch,
                       finding_process_containment, finding_session_resumption, verdict, reason
                FROM probe_result
                WHERE cli = ?
                ORDER BY probed_at DESC, id DESC
                LIMIT 1
                """,
                arguments: [cli]
            )

            guard let row = row else { return nil }
            return try decodeProbeResult(row)
        }
    }

    /// The full Probe Result history for a given agent CLI, newest first.
    /// Timestamps are floored to seconds, so a secondary id DESC sort breaks ties deterministically.
    public func probeResults(cli: String) throws -> [ProbeResult] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT cli, probed_at, adapter_version, cli_version,
                       finding_result_file_on_clean_exit, finding_unattended_dispatch,
                       finding_process_containment, finding_session_resumption, verdict, reason
                FROM probe_result
                WHERE cli = ?
                ORDER BY probed_at DESC, id DESC
                """,
                arguments: [cli]
            )

            return try rows.map(decodeProbeResult)
        }
    }

    /// Access for later steps: `read`/`write` closures over GRDB `Database`.
    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try queue.read(block)
    }

    /// Every write is one IMMEDIATE transaction (GRDB's default for writes), so multiple connections
    /// to the same file, from the same or different processes, serialise on SQLite's lock rather than
    /// interleave, thanks to WAL journal mode.
    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try queue.write(block)
    }

    // MARK: - Private Helpers

    private func decodeProbeResult(_ row: Row) throws -> ProbeResult {
        guard
            let cli = row["cli"] as? String,
            let probedAtText = row["probed_at"] as? String,
            let adapterVersion = row["adapter_version"] as? String,
            let cliVersion = row["cli_version"] as? String,
            let findingResultFileRawValue = row["finding_result_file_on_clean_exit"] as? String,
            let findingUnattendedRawValue = row["finding_unattended_dispatch"] as? String,
            let findingProcessRawValue = row["finding_process_containment"] as? String,
            let findingSessionResumptionRawValue = row["finding_session_resumption"] as? String,
            let storedVerdictRawValue = row["verdict"] as? String,
            let findingResultFile = ProbeFinding(rawValue: findingResultFileRawValue),
            let findingUnattended = ProbeFinding(rawValue: findingUnattendedRawValue),
            let findingProcess = ProbeFinding(rawValue: findingProcessRawValue),
            let findingSessionResumption = ProbeFinding(rawValue: findingSessionResumptionRawValue),
            let storedVerdict = ProbeVerdict(rawValue: storedVerdictRawValue)
        else {
            throw LedgerError.probeResultUnreadable
        }

        let probedAt = try LedgerStore.date(probedAtText) {
            LedgerError.probeResultUnreadable
        }

        let reason = row["reason"] as? String

        let result = ProbeResult(
            cli: cli,
            probedAt: probedAt,
            adapterVersion: adapterVersion,
            cliVersion: cliVersion,
            findingResultFileOnCleanExit: findingResultFile,
            findingUnattendedDispatch: findingUnattended,
            findingProcessContainment: findingProcess,
            findingSessionResumption: findingSessionResumption,
            reason: reason
        )

        // Cross-check: the stored verdict must match the verdict derived from findings.
        // A row with a disagreeing verdict was not written by this engine.
        if result.verdict != storedVerdict {
            throw LedgerError.probeResultUnreadable
        }

        return result
    }
}

extension LedgerStore {
    /// Whether a CLI's latest Probe Result offers it as a route target (spec: a CLI that fails the
    /// unattended dispatch or process containment probe, or never produces a result file on clean
    /// exit, is not offered — P7.6 owns probe-age/health, not this).
    public func routeTargetEligibility(cli: String) throws -> RouteTargetEligibility {
        guard let latest = try latestProbeResult(cli: cli) else {
            return .excluded(reason: "`\(cli)` has never been probed; run `yh probe \(cli)`")
        }
        switch latest.verdict {
        case .failed:
            // The store's invariant guarantees a failed verdict always carries a reason.
            return .excluded(reason: latest.reason ?? "probe failed")
        case .passed:
            return .offered
        }
    }
}
