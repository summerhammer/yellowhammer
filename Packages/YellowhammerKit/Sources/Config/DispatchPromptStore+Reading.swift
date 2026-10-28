import Darwin
import Domain
import Foundation

extension DispatchPromptStore {
    /// Reads a prompt record or its tombstone without side effects.
    ///
    /// Never serves prompt text once 30 days have elapsed from dispatch.
    /// Returns `unreadable` when permissions or decoding checks fail.
    public func lookup(id: String, scope: DispatchPromptScope) -> DispatchPromptLookup {
        if let error = validateIdentifier(id, name: "record ID") {
            return .unreadable(cause: error)
        }
        if let projectID = scope.projectID, let error = validateIdentifier(projectID.rawValue, name: "Project ID") {
            return .unreadable(cause: error)
        }

        let scopeDir = directory(for: scope)

        // The tombstone decides while it exists: record ids are fresh UUIDs never re-created, so a record
        // beside a tombstone is a launch rewrite that raced the deletion, and must not resurrect the prompt.
        if let tombstoneLookup = lookupTombstone(id: id, scopeDir: scopeDir) {
            return tombstoneLookup
        }

        return lookupRecord(id: id, scopeDir: scopeDir)
    }

    private func lookupTombstone(id: String, scopeDir: URL) -> DispatchPromptLookup? {
        let tombstoneURL = scopeDir.appending(components: "\(id).deleted.json", directoryHint: .notDirectory)
        let tombstonePath = tombstoneURL.path(percentEncoded: false)
        var tombstoneStat = stat()
        guard lstat(tombstonePath, &tombstoneStat) == 0 else {
            return nil
        }

        let tombstoneCheck = verifyFilePermissions(statBuf: tombstoneStat, path: tombstonePath, kind: "tombstone")
        if case .failure(let error) = tombstoneCheck {
            return .unreadable(cause: error.message)
        }
        if case .failure(let error) = verifyDirectoryHierarchyOnRead(scopeDir: scopeDir) {
            return .unreadable(cause: error.message)
        }
        guard let data = try? Data(contentsOf: tombstoneURL) else {
            return .unreadable(cause: "could not read tombstone file")
        }
        guard let tombstone = try? DispatchPromptRecord.makeJSONDecoder()
            .decode(DispatchPromptTombstone.self, from: data) else {
            return .unreadable(cause: "could not decode tombstone")
        }
        return .deleted(deletedAt: tombstone.deletedAt)
    }

    private func lookupRecord(id: String, scopeDir: URL) -> DispatchPromptLookup {
        let recordURL = scopeDir.appending(components: "\(id).json", directoryHint: .notDirectory)
        let recordPath = recordURL.path(percentEncoded: false)
        var recordStat = stat()
        let statResult = lstat(recordPath, &recordStat)
        if statResult != 0 {
            if errno == ENOENT {
                return .missing
            }
            return .unreadable(cause: "could not stat record file: \(String(cString: strerror(errno)))")
        }

        let recordCheck = verifyFilePermissions(statBuf: recordStat, path: recordPath, kind: "record file")
        if case .failure(let error) = recordCheck {
            return .unreadable(cause: error.message)
        }
        if case .failure(let error) = verifyDirectoryHierarchyOnRead(scopeDir: scopeDir) {
            return .unreadable(cause: error.message)
        }

        guard let data = try? Data(contentsOf: recordURL) else {
            return .unreadable(cause: "could not read record file")
        }
        guard let record = try? DispatchPromptRecord.makeJSONDecoder()
            .decode(DispatchPromptRecord.self, from: data) else {
            return .unreadable(cause: "could not decode record file")
        }

        if record.isExpired(at: now()) {
            return .expired(dispatchedAt: record.dispatchedAt)
        }

        return .available(record)
    }

    func verifyFilePermissions(statBuf: stat, path: String, kind: String) -> Result<Void, RestrictionError> {
        if (statBuf.st_mode & S_IFMT) == S_IFLNK {
            return .failure(RestrictionError(message: "\(kind) is a symlink"))
        }
        if statBuf.st_uid != currentUser {
            return .failure(
                RestrictionError(
                    message: "\(kind) owner mismatch: expected \(currentUser), got \(statBuf.st_uid)"
                )
            )
        }
        if (statBuf.st_mode & 0o077) != 0 {
            return .failure(RestrictionError(message: "\(kind) mode has group or other bits set"))
        }
        return verifyNoExtendedACL(path: path, kind: kind)
    }

    /// Lists all prompt entries in a scope (including tombstones), sorted oldest dispatch first.
    public func entries(in scope: DispatchPromptScope) -> [DispatchPromptEntry] {
        let scopeDir = directory(for: scope)
        let path = scopeDir.path(percentEncoded: false)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }

        var ids: Set<String> = []
        for item in items {
            if item.hasSuffix(".deleted.json") {
                ids.insert(String(item.dropLast(".deleted.json".count)))
            } else if item.hasSuffix(".json") && !item.hasPrefix(".") {
                ids.insert(String(item.dropLast(".json".count)))
            }
        }

        // The dispatch date is read once per entry (a deletion marker is a file read), then the sort compares.
        var dated: [(entry: DispatchPromptEntry, date: Date)] = []
        for id in ids {
            let lookupResult = lookup(id: id, scope: scope)
            let date = dispatchDate(for: id, scope: scope, lookup: lookupResult) ?? Date.distantPast
            dated.append((DispatchPromptEntry(id: id, lookup: lookupResult), date))
        }

        dated.sort { first, second in
            if first.date != second.date {
                return first.date < second.date
            }
            return first.entry.id < second.entry.id
        }

        return dated.map(\.entry)
    }

    /// Sweeps expired records in the scope by unlinking them. Returns failed removals by filename.
    public func sweepExpired(in scope: DispatchPromptScope) -> [String] {
        let scopeDir = directory(for: scope)
        let path = scopeDir.path(percentEncoded: false)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }

        var failures: [String] = []
        for item in items {
            if item.hasSuffix(".json") && !item.hasSuffix(".deleted.json") && !item.hasPrefix(".") {
                let id = String(item.dropLast(".json".count))
                let result = lookup(id: id, scope: scope)
                // A record beside a tombstone is a deletion's leftover; sweep it with the expired ones.
                let sweepable: Bool
                switch result {
                case .expired, .deleted: sweepable = true
                default: sweepable = false
                }
                if sweepable {
                    let filePath = scopeDir.appending(components: item, directoryHint: .notDirectory)
                        .path(percentEncoded: false)
                    if Darwin.unlink(filePath) != 0 {
                        if errno != ENOENT {
                            failures.append(item)
                        }
                    }
                }
            }
        }
        return failures
    }

    private func dispatchDate(
        for id: String,
        scope: DispatchPromptScope,
        lookup: DispatchPromptLookup
    ) -> Date? {
        switch lookup {
        case .available(let record):
            return record.dispatchedAt
        case .expired(let dispatchedAt):
            return dispatchedAt
        case .deleted:
            let scopeDir = directory(for: scope)
            let tombstoneURL = scopeDir.appending(components: "\(id).deleted.json", directoryHint: .notDirectory)
            if let data = try? Data(contentsOf: tombstoneURL),
               let tomb = try? DispatchPromptRecord.makeJSONDecoder()
                .decode(DispatchPromptTombstone.self, from: data) {
                return tomb.dispatchedAt
            }
            return nil
        case .missing, .unreadable:
            return nil
        }
    }

    /// Verifies that directories leading to `scopeDir` exist, are owned by `currentUser`,
    /// and have no group or other bits set. Never modifies files or directories.
    func verifyDirectoryHierarchyOnRead(scopeDir: URL) -> Result<Void, RestrictionError> {
        var current = scopeDir.standardizedFileURL
        var dirs: [URL] = []
        let rootPath = rootDirectory.standardizedFileURL.path(percentEncoded: false)
        while true {
            dirs.append(current)
            if current.path(percentEncoded: false) == rootPath {
                break
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path(percentEncoded: false) == current.path(percentEncoded: false) {
                break
            }
            current = parent
        }

        for dir in dirs {
            if case .failure(let error) = verifySingleDirectoryOnRead(dir: dir) {
                return .failure(error)
            }
        }

        return .success(())
    }

    private func verifySingleDirectoryOnRead(dir: URL) -> Result<Void, RestrictionError> {
        let path = dir.path(percentEncoded: false)
        var statBuf = stat()
        if lstat(path, &statBuf) != 0 {
            return .failure(
                RestrictionError(
                    message: "could not stat directory at \(path): \(String(cString: strerror(errno)))"
                )
            )
        }
        if (statBuf.st_mode & S_IFMT) == S_IFLNK {
            return .failure(RestrictionError(message: "directory at \(path) is a symlink"))
        }
        if (statBuf.st_mode & S_IFMT) != S_IFDIR {
            return .failure(RestrictionError(message: "path at \(path) is not a directory"))
        }
        if statBuf.st_uid != currentUser {
            return .failure(
                RestrictionError(
                    message: "directory at \(path) is owned by uid \(statBuf.st_uid), expected \(currentUser)"
                )
            )
        }
        if (statBuf.st_mode & 0o077) != 0 {
            return .failure(RestrictionError(message: "directory at \(path) has group or other bits set"))
        }
        return verifyNoExtendedACL(path: path, kind: "directory at \(path)")
    }

    /// Read-only ACL check: any extended entry may grant another user access, so it refuses.
    private func verifyNoExtendedACL(path: String, kind: String) -> Result<Void, RestrictionError> {
        switch Self.hasExtendedACL(path: path) {
        case .some(false):
            return .success(())
        case .some(true):
            return .failure(RestrictionError(message: "\(kind) has an extended ACL entry"))
        case .none:
            return .failure(RestrictionError(message: "could not read the ACL of \(kind)"))
        }
    }
}
