import Domain
import Foundation

@testable import Journal

/// A Journal migrated once per test process, copied into place wherever a test opens a fresh one.
///
/// Swift Testing starts every test of the target at once, and each opens a Journal synchronously on
/// a cooperative-pool thread. Migrating from empty is one fsynced transaction per migration, so
/// several hundred of those at once park the whole pool in disk I/O for seconds, and whatever has to
/// resume inside a real-time window (a Lease heartbeat) loses. A copy is a clone: no fsync. A Journal
/// file carries no Project id, so the one template serves every Project.
private enum JournalTemplate {
    static let fileURL: Result<URL, any Error> = Result {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-template-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileURL = directory.appending(component: "template.db", directoryHint: .notDirectory)
        guard let projectID = ProjectID(rawValue: "template") else { throw InvalidTemplateProjectID() }
        // Scoped, so the connection is closed before anything copies the file.
        _ = try JournalStore.open(at: fileURL, projectID: projectID)
        return fileURL
    }
}

private struct InvalidTemplateProjectID: Error {}

extension JournalStore {
    /// The engine's open, except that a Journal that does not exist yet starts as a copy of the
    /// migrated template rather than being migrated from empty. An existing file is opened as it is.
    static func openSeeded(configurationDirectory: URL, projectID: ProjectID) throws -> JournalStore {
        let fileURL = defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Losing a race to another opener of the same path is fine: the file is there either way.
            try? FileManager.default.copyItem(at: try JournalTemplate.fileURL.get(), to: fileURL)
        }
        return try open(configurationDirectory: configurationDirectory, projectID: projectID)
    }
}
