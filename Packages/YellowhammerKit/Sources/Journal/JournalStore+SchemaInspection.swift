import Foundation
import GRDB

extension JournalStore {
    /// Inspects schema metadata without opening a store or migrating it. A missing Journal is nil;
    /// unreadable or unknown metadata fails closed so job generation cannot select an older engine.
    public static func schemaIdentifier(at fileURL: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(busyTimeout)
        let queue = try DatabaseQueue(path: fileURL.path, configuration: configuration)
        return try queue.read { database in
            guard try database.tableExists("grdb_migrations") else {
                throw JournalError.schemaBehind(path: fileURL.path, pending: migrationIdentifiers)
            }
            let identifiers = try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations")
            guard identifiers.count == 1, let identifier = identifiers.first else {
                throw JournalError.schemaNewerThanKnown(path: fileURL.path, unknown: identifiers)
            }
            return identifier
        }
    }
}
