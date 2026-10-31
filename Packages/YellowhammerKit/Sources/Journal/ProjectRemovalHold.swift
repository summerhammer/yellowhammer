import Darwin
import Domain
import Foundation
import Synchronization

/// A short-lived file lock for one Journal. Removal holds it exclusively through the final TOML
/// deletion, beyond its SQLite commit. Writable opens and Act claims take a shared lock, so neither
/// a first Journal creation nor a new Act can enter during that interval. Read-only app opens do not
/// participate. The persistent lock file is never unlinked: replacing it would bypass a held flock.
public final class ProjectRemovalHold: Sendable {
    let journalURL: URL
    /// The locked descriptor, -1 once ``release()`` ran.
    private let descriptor: Mutex<Int32>

    /// How long removal waits for an exclusive hold: SQLite's own busy timeout. A shared hold is only ever taken for one short
    /// open or Act claim (or inherited for an instant by a spawned child before `exec` closes it), so
    /// removal waits it out; an Act never waits, it refuses fast while removal holds the Journal.
    static let exclusiveWait: Duration = .seconds(JournalStore.busyTimeout)

    private init(journalURL: URL, exclusive: Bool) throws {
        self.journalURL = journalURL.standardizedFileURL
        let path = journalURL.path + ".removal.lock"
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProjectRemovalHoldError.unavailable(path: path, code: errno) }
        let deadline = ContinuousClock.now + (exclusive ? Self.exclusiveWait : .zero)
        while flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK || code == EAGAIN, ContinuousClock.now < deadline {
                usleep(20_000)
                continue
            }
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw ProjectRemovalHoldError.held(path: path) }
            throw ProjectRemovalHoldError.unavailable(path: path, code: code)
        }
        self.descriptor = Mutex(descriptor)
    }

    deinit { release() }

    /// Ends the hold now rather than when the last reference goes; idempotent.
    public func release() {
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    static func shared(for journalURL: URL) throws -> ProjectRemovalHold {
        try ProjectRemovalHold(journalURL: journalURL, exclusive: false)
    }

    static func exclusive(for journalURL: URL) throws -> ProjectRemovalHold {
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return try ProjectRemovalHold(journalURL: journalURL, exclusive: true)
    }

    func validate(journalURL: URL) throws {
        guard self.journalURL == journalURL.standardizedFileURL else {
            throw ProjectRemovalHoldError.differentJournal
        }
    }
}

public enum ProjectRemovalHoldError: Error, Sendable, CustomStringConvertible {
    case held(path: String)
    case unavailable(path: String, code: Int32)
    case differentJournal

    public var description: String {
        switch self {
        case .held(let path): "Project removal holds \(path); retry after removal finishes"
        case .unavailable(let path, let code): "could not hold the Project removal lock \(path) (errno \(code))"
        case .differentJournal: "the Project removal hold belongs to a different Journal"
        }
    }
}

extension JournalStore {
    /// Does not create a Journal. The lock also excludes an Act's first writable open while removal
    /// handles a Project that has never run or whose Journal was deleted.
    public static func holdProjectRemoval(
        configurationDirectory: URL, projectID: ProjectID
    ) throws -> ProjectRemovalHold {
        try .exclusive(for: defaultFileURL(configurationDirectory: configurationDirectory, id: projectID))
    }
}
