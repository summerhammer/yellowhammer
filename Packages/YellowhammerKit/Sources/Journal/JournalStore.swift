import Domain
import Foundation
import GRDB

public final class JournalStore: Sendable {
    public let projectID: ProjectID
    public let fileURL: URL
    private let queue: DatabaseQueue

    private init(projectID: ProjectID, fileURL: URL, queue: DatabaseQueue) {
        self.projectID = projectID
        self.fileURL = fileURL
        self.queue = queue
    }

    /// Returns `~/.config/yellowhammer/journals/<id>.db` under the given home directory (spec G-3 / OQ52).
    public static func defaultFileURL(homeDirectory: URL, id: ProjectID) -> URL {
        homeDirectory.appending(
            components: ".config", "yellowhammer", "journals", "\(id.rawValue).db",
            directoryHint: .notDirectory
        )
    }

    /// Opens (creating the file and its parent directory on first use) and migrates forward to the current schema. The engine's open.
    public static func open(at fileURL: URL, projectID: ProjectID) throws -> JournalStore {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var config = Configuration()
        config.foreignKeysEnabled = true

        let queue = try DatabaseQueue(path: fileURL.path, configuration: config)

        try JournalMigrations.migrator.migrate(queue)

        return JournalStore(projectID: projectID, fileURL: fileURL, queue: queue)
    }

    /// Convenience: open(at: defaultFileURL(homeDirectory:id:), projectID: id)
    public static func open(homeDirectory: URL, projectID: ProjectID) throws -> JournalStore {
        let fileURL = defaultFileURL(homeDirectory: homeDirectory, id: projectID)
        return try open(at: fileURL, projectID: projectID)
    }

    /// The app's open: read-only, never migrates. Throws JournalError.schemaNewerThanKnown if the store has migrations this build does not know, and JournalError.schemaBehind if not fully migrated (only the engine migrates). Throws JournalError.missing if the file does not exist (never creates a file).
    public static func openReadOnly(at fileURL: URL, projectID: ProjectID) throws -> JournalStore {
        // Check file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw JournalError.missing(path: fileURL.path)
        }

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.readonly = true

        let queue = try DatabaseQueue(path: fileURL.path, configuration: config)

        // Check schema state
        try queue.read { db in
            // Check if grdb_migrations table exists
            if try !db.tableExists("grdb_migrations") {
                throw JournalError.schemaBehind(path: fileURL.path, pending: JournalMigrations.migrationIdentifiers)
            }

            let appliedSet = try JournalMigrations.migrator.appliedIdentifiers(db)
            let knownIdentifiers = JournalMigrations.migrationIdentifiers

            // Check if there are unknown migrations
            let unknown = Array(appliedSet).filter { !knownIdentifiers.contains($0) }.sorted()
            if !unknown.isEmpty {
                throw JournalError.schemaNewerThanKnown(path: fileURL.path, unknown: unknown)
            }

            // Check if there are pending migrations
            let pending = knownIdentifiers.filter { !appliedSet.contains($0) }
            if !pending.isEmpty {
                throw JournalError.schemaBehind(path: fileURL.path, pending: pending)
            }
        }

        return JournalStore(projectID: projectID, fileURL: fileURL, queue: queue)
    }

    /// Identifiers of the migrations this build knows, in order. Last one is the current schema version.
    public static var migrationIdentifiers: [String] {
        JournalMigrations.migrationIdentifiers
    }

    /// Identifiers applied to this store, in order.
    public func appliedMigrations() throws -> [String] {
        try queue.read { db in
            let appliedSet = try JournalMigrations.migrator.appliedIdentifiers(db)
            let knownIdentifiers = JournalMigrations.migrationIdentifiers

            // Order by position in migrationIdentifiers, then unknown identifiers sorted
            let ordered = knownIdentifiers.filter { appliedSet.contains($0) }
            let unknown = Array(appliedSet).filter { !knownIdentifiers.contains($0) }.sorted()
            return ordered + unknown
        }
    }

    /// Table names present, sorted. For tests and `yh doctor`.
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

    /// Access for later steps: `read`/`write` closures over GRDB `Database`.
    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try queue.read(block)
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try queue.write(block)
    }
}
