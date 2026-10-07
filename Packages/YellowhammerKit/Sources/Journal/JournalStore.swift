import Darwin
import Domain
import Foundation
import GRDB

/// One Project's Journal. The engine invocations for that Project are its only writers (they serialise
/// on SQLite's lock, and on a lock file while creating or migrating), and none opens another Project's.
/// The app opens a Journal read-only and never migrates it. The Journal records the Linear workspace it was created against and is never re-pointed at another.
public final class JournalStore: Sendable {
    public let projectID: ProjectID
    public let fileURL: URL
    /// Salts this Journal's Outbox client ids (``OutboxClientID/make(projectID:salt:key:)``): a random
    /// value fixed for the life of the Journal (`project_state.outbox_salt`), read once here so a reset
    /// Project's fresh Journal never recomputes an id that resolves to an issue archived under the
    /// previous one.
    public let outboxSalt: String
    /// The Linear workspace of the Board Connection this Journal was built against
    /// (`project_state.linear_workspace`), recorded when the Journal was created and read once here.
    public let linearWorkspace: BoardObjectID
    private let queue: DatabaseQueue

    /// How long a connection waits for SQLite's lock before failing with `SQLITE_BUSY`. The app reads
    /// while an Act writes, and an overlapping Act of the same Project stands down after one short
    /// transaction; neither holds the lock for long.
    static let busyTimeout: TimeInterval = 5

    private init(
        projectID: ProjectID,
        fileURL: URL,
        queue: DatabaseQueue,
        outboxSalt: String,
        linearWorkspace: BoardObjectID
    ) {
        self.projectID = projectID
        self.fileURL = fileURL
        self.queue = queue
        self.outboxSalt = outboxSalt
        self.linearWorkspace = linearWorkspace
    }

    /// The `project_state.linear_workspace` column, read once at open.
    private static func readLinearWorkspace(_ queue: DatabaseQueue) throws -> BoardObjectID {
        try queue.read { db in
            BoardObjectID(
                rawValue: try String.fetchOne(db, sql: "SELECT linear_workspace FROM project_state WHERE id = 1") ?? ""
            )
        }
    }

    private static func makeStore(
        projectID: ProjectID, fileURL: URL, queue: DatabaseQueue
    ) throws -> JournalStore {
        JournalStore(
            projectID: projectID,
            fileURL: fileURL,
            queue: queue,
            outboxSalt: try readOutboxSalt(queue),
            linearWorkspace: try readLinearWorkspace(queue)
        )
    }

    /// The `project_state.outbox_salt` column, read once at open.
    private static func readOutboxSalt(_ queue: DatabaseQueue) throws -> String {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT outbox_salt FROM project_state WHERE id = 1") ?? ""
        }
    }

    /// Returns `<configurationDirectory>/journals/<id>.db` (spec G-3 / OQ52). The Journal path is a
    /// function of the Project's id alone, and `ProjectID` admits only `[A-Za-z0-9_-]`, so it can name
    /// nothing outside the `journals` directory.
    public static func defaultFileURL(configurationDirectory: URL, id: ProjectID) -> URL {
        configurationDirectory.appending(components: "journals", "\(id.rawValue).db", directoryHint: .notDirectory)
    }

    /// Returns `~/.config/yellowhammer/journals/<id>.db` under the given home directory (spec G-3 / OQ52).
    public static func defaultFileURL(homeDirectory: URL, id: ProjectID) -> URL {
        let configurationDirectory = homeDirectory
            .appending(components: ".config", "yellowhammer", directoryHint: .isDirectory)
        return defaultFileURL(configurationDirectory: configurationDirectory, id: id)
    }

    /// The engine's open, for the Project the invocation fires for: creates the file and its parent
    /// directory on first use and migrates forward to the current schema. It addresses a Journal by
    /// Project id only, never by path (a rehearsal Journal is ``open(rehearsalJournalAt:projectID:linearWorkspace:)``). `linearWorkspace` is the Linear workspace of the Project's App
    /// Installation; it is recorded only when this open creates the Journal. An existing Journal keeps the
    /// workspace it was created with: this open neither compares nor overwrites it.
    public static func open(
        configurationDirectory: URL, projectID: ProjectID, linearWorkspace: BoardObjectID
    ) throws -> JournalStore {
        let fileURL = defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
        return try open(at: fileURL, projectID: projectID, linearWorkspace: linearWorkspace)
    }

    /// Convenience: `open(configurationDirectory:projectID:linearWorkspace:)` under `~/.config/yellowhammer`.
    public static func open(
        homeDirectory: URL, projectID: ProjectID, linearWorkspace: BoardObjectID
    ) throws -> JournalStore {
        try open(
            at: defaultFileURL(homeDirectory: homeDirectory, id: projectID),
            projectID: projectID,
            linearWorkspace: linearWorkspace
        )
    }

    /// The engine's open of a Project's rehearsal Journal (OQ149): the one Journal not addressed by
    /// Project id, since its path is declared (`[rehearsal] journal`), never derived. Creates and
    /// migrates exactly as ``open(configurationDirectory:projectID:linearWorkspace:)`` does. The caller
    /// has already refused a path that is, or sits beside, a real Journal
    /// (`ProjectConfiguration.rehearsalContext(realJournal:)`), so this never reaches a real one.
    public static func open(
        rehearsalJournalAt fileURL: URL, projectID: ProjectID, linearWorkspace: BoardObjectID
    ) throws -> JournalStore {
        try open(at: fileURL, projectID: projectID, linearWorkspace: linearWorkspace)
    }

    /// Opens a Journal at an explicit path. Internal so that no module can address a Journal other
    /// than by its Project's id or, for a rehearsal, its declared path; tests use it for fixtures.
    static func open(at fileURL: URL, projectID: ProjectID, linearWorkspace: BoardObjectID) throws -> JournalStore {
        try openWritable(
            at: fileURL,
            projectID: projectID,
            migrator: JournalMigrations.migrator(linearWorkspace: linearWorkspace),
            creating: true
        )
    }

    /// The engine's non-creating open, for callers that act only on a Journal that already exists (abort,
    /// stop, Project removal): throws `JournalError.missing` if the file does not exist and never creates
    /// it. It rejects unknown migrations as ``open(configurationDirectory:projectID:linearWorkspace:)``
    /// does, and migrates with no workspace, so a creation still pending throws
    /// `JournalError.linearWorkspaceRequired` rather than inventing one.
    public static func openExisting(configurationDirectory: URL, projectID: ProjectID) throws -> JournalStore {
        let fileURL = defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
        return try openWritable(
            at: fileURL, projectID: projectID, migrator: JournalMigrations.migrator, creating: false
        )
    }

    private static func openWritable(
        at fileURL: URL, projectID: ProjectID, migrator: DatabaseMigrator, creating: Bool
    ) throws -> JournalStore {
        if creating {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } else if !FileManager.default.fileExists(atPath: fileURL.path) {
            throw JournalError.missing(path: fileURL.path)
        }

        // Two Acts of one Project (`build` and `land`) fired in the same minute can reach a fresh, or
        // deleted-and-recreated, Journal at once. Each opens its own connection, and GRDB's migrator does
        // not serialise DDL across processes: both see no `grdb_migrations` table and both run
        // `journal-schema-N`, and the loser dies with `table "night" already exists`. An exclusive flock
        // on a sibling lock file, held from opening the connection through the migration, serialises
        // them. No re-check is needed: once the winner has committed, the loser's `migrate` finds the
        // schema migration applied and does nothing.
        let queue = try withMigrationLock(for: fileURL) {
            var config = Configuration()
            config.foreignKeysEnabled = true
            config.busyMode = .timeout(busyTimeout)

            let queue = try DatabaseQueue(path: fileURL.path, configuration: config)

            // An existing Journal written by a build whose migrations this one does not know (for example
            // one created before the schema was squashed into a single migration) is refused, not migrated:
            // `schemaOlderThanKnown` when provably older, `schemaNewerThanKnown` otherwise.
            try queue.read { db in
                if try db.tableExists("grdb_migrations") {
                    try rejectUnknownMigrations(db, path: fileURL.path)
                }
            }

            try migrator.migrate(queue)
            return queue
        }

        return try makeStore(projectID: projectID, fileURL: fileURL, queue: queue)
    }

    /// Runs `body` while holding an exclusive `flock` on `<fileURL>.lock`. Unlike the Ledger's, this lock
    /// never falls back to running unlocked: for the Journal that is the race it exists to prevent, so a
    /// lock file that cannot be opened or locked throws `JournalError.migrationLockUnavailable`. `flock` is
    /// retried once on `EINTR`.
    private static func withMigrationLock<T>(for fileURL: URL, _ body: () throws -> T) throws -> T {
        let lockPath = fileURL.path + ".lock"
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw JournalError.migrationLockUnavailable(path: lockPath, errno: errno)
        }
        defer { Darwin.close(descriptor) }
        var result = flock(descriptor, LOCK_EX)
        if result != 0, errno == EINTR {
            result = flock(descriptor, LOCK_EX)
        }
        guard result == 0 else {
            throw JournalError.migrationLockUnavailable(path: lockPath, errno: errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// The app's open: read-only, never migrates. Throws JournalError.schemaOlderThanKnown if every migration this build does not know is provably older (delete the Journal), JournalError.schemaNewerThanKnown if it has any other unknown migration, and JournalError.schemaBehind if not fully migrated (only the engine migrates). Throws JournalError.missing if the file does not exist (never creates a file).
    public static func openReadOnly(at fileURL: URL, projectID: ProjectID) throws -> JournalStore {
        // Check file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw JournalError.missing(path: fileURL.path)
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
                throw JournalError.schemaBehind(path: fileURL.path, pending: JournalMigrations.migrationIdentifiers)
            }

            try rejectUnknownMigrations(db, path: fileURL.path)

            let appliedSet = try JournalMigrations.migrator.appliedIdentifiers(db)
            let knownIdentifiers = JournalMigrations.migrationIdentifiers

            // Check if there are pending migrations
            let pending = knownIdentifiers.filter { !appliedSet.contains($0) }
            if !pending.isEmpty {
                throw JournalError.schemaBehind(path: fileURL.path, pending: pending)
            }
        }

        return try makeStore(projectID: projectID, fileURL: fileURL, queue: queue)
    }

    /// Throws if the store has applied a migration this build does not know: `JournalError.schemaOlderThanKnown`
    /// when every unknown identifier is provably older (see ``isProvablyOlder(_:)``), else
    /// `JournalError.schemaNewerThanKnown`.
    private static func rejectUnknownMigrations(_ db: Database, path: String) throws {
        let appliedSet = try JournalMigrations.migrator.appliedIdentifiers(db)
        let knownIdentifiers = JournalMigrations.migrationIdentifiers
        let unknown = Array(appliedSet).filter { !knownIdentifiers.contains($0) }.sorted()
        if !unknown.isEmpty {
            if unknown.allSatisfy(isProvablyOlder) {
                throw JournalError.schemaOlderThanKnown(path: path, unknown: unknown)
            }
            throw JournalError.schemaNewerThanKnown(path: path, unknown: unknown)
        }
    }

    /// Whether an unknown migration identifier is provably older than this build's schema: it matches
    /// `^v\d+-` (the retired pre-squash chain), or it is `journal-schema-M` with integer M below the
    /// current N. Anything else (a higher M, an unparseable shape) is not provable, so the caller treats
    /// it as newer and never advises deleting on a guess.
    static func isProvablyOlder(_ identifier: String) -> Bool {
        if identifier.wholeMatch(of: /v\d+-.*/) != nil {
            return true
        }
        func schemaNumber(_ identifier: String) -> Int? {
            let prefix = "journal-schema-"
            return identifier.hasPrefix(prefix) ? Int(identifier.dropFirst(prefix.count)) : nil
        }
        guard let current = schemaNumber(JournalMigrations.schemaIdentifier), let number = schemaNumber(identifier)
        else { return false }
        return number < current
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

    /// Every write is one IMMEDIATE transaction (GRDB's default for writes), so two connections to the
    /// same file, from the same or another process, serialise on SQLite's lock rather than interleave.
    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try queue.write(block)
    }
}
