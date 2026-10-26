import Domain
import Foundation

@testable import Journal

// The writer: both configuration directories, replacing any already there.

/// Why the showcase could not be written or did not read back as designed.
public struct ShowcaseError: Error, CustomStringConvertible {
    public let description: String
}

/// The value, or an error naming what was missing.
func required<T>(_ value: T?, _ what: String = "a value the showcase seed relies on") throws -> T {
    guard let value else { throw ShowcaseError(description: "Missing \(what)") }
    return value
}

/// Throws `message` unless `condition` holds.
func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw ShowcaseError(description: message()) }
}

enum ShowcaseKind: String, CaseIterable {
    case morning
    case working
}

extension Showcase {
    /// Writes `<directory>/morning/` and `<directory>/working/`, each a complete configuration directory with
    /// `orbit`'s Journal and none for `harbor`. Every time is anchored to `now` in `calendar`: the Night starts
    /// on the calendar date of `now - 1 day`.
    public static func write(to directory: URL, now: Date, calendar: Calendar = .current) throws {
        let clock = ShowcaseClock(now: now, calendar: calendar)
        let fileManager = FileManager.default
        for kind in ShowcaseKind.allCases {
            let target = directory.appending(component: kind.rawValue, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try writeConfigurationFiles(into: target)
            try seedJournal(kind, in: target, clock: clock)
        }
    }

    /// Creates `orbit`'s Journal in `directory` and closes it again before returning.
    private static func seedJournal(_ kind: ShowcaseKind, in directory: URL, clock: ShowcaseClock) throws {
        let journal = try JournalStore.open(
            configurationDirectory: directory, projectID: projectID(), linearWorkspace: fixtureWorkspace
        )
        switch kind {
        case .morning: try seedMorning(journal, clock: clock)
        case .working: try seedWorking(journal, clock: clock)
        }
    }

    /// The Linear workspace `config.toml` names, which the Journal records.
    static let fixtureWorkspace = BoardObjectID(rawValue: "workspace-1")
}
