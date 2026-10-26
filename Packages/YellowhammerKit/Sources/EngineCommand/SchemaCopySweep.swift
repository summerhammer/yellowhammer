import Domain
import Foundation

/// Removes the output-schema copies an agent CLI adapter leaves in run directories (`schema.json`).
/// The runner deletes its own after each pass; this catches the ones a crashed `yh` left behind and
/// the ones a removed Project owned, so no captured schema outlives its 30 days (Evidence Lifecycle).
enum SchemaCopySweep {
    static let fileName = "schema.json"

    /// Deletes every file named exactly `schema.json` under `directory`. With `olderThan`, only those
    /// last modified at or before it. Returns the paths it could not delete; a missing directory is not a failure.
    static func remove(under directory: URL, olderThan cutoff: Date? = nil) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return [] }

        var failures: [String] = []
        for case let url as URL in walker where url.lastPathComponent == fileName {
            if let cutoff {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let modified, modified <= cutoff else { continue }
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append(url.path(percentEncoded: false))
            }
        }
        return failures
    }

    /// Schema copies at least ``DispatchPromptRecord/retention`` old.
    static func removeExpired(under directory: URL, now: Date = Date()) -> [String] {
        remove(under: directory, olderThan: now.addingTimeInterval(-DispatchPromptRecord.retention))
    }
}
