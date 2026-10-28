import Darwin
import Domain
import Foundation

extension DispatchPromptStore {
    /// Captures a prompt record, verifying directory and file access restrictions before writing.
    public func capture(_ record: DispatchPromptRecord) -> DispatchPromptCapture {
        if let error = validateIdentifier(record.id, name: "record ID") {
            return .unavailable(cause: error)
        }
        let scope = record.provenance.scope
        let scopeDirResult = ensureRestrictedDirectoryTree(for: scope)
        guard case .success(let scopeDir) = scopeDirResult else {
            if case .failure(let error) = scopeDirResult {
                return .unavailable(cause: error.message)
            }
            return .unavailable(cause: "failed to ensure restricted directory")
        }

        let data: Data
        do {
            data = try DispatchPromptRecord.makeJSONEncoder().encode(record)
        } catch {
            return .unavailable(cause: "failed to encode dispatch prompt record: \(error)")
        }

        let targetURL = scopeDir.appending(components: "\(record.id).json", directoryHint: .notDirectory)
        return writeRestrictedFile(data: data, to: targetURL, in: scopeDir)
    }

    /// Updates the launch status of an existing prompt record.
    ///
    /// Returns false and writes nothing when the record was deleted, expired, missing, or unreadable.
    public func markLaunch(_ launch: DispatchLaunch, of record: DispatchPromptRecord) -> Bool {
        let scope = record.provenance.scope
        switch lookup(id: record.id, scope: scope) {
        case .available(var existing):
            existing.launch = launch
            guard case .success(let scopeDir) = ensureRestrictedDirectoryTree(for: scope) else {
                return false
            }
            guard let data = try? DispatchPromptRecord.makeJSONEncoder().encode(existing) else {
                return false
            }
            let targetURL = scopeDir.appending(components: "\(record.id).json", directoryHint: .notDirectory)
            let result = writeRestrictedFile(data: data, to: targetURL, in: scopeDir)
            switch result {
            case .recorded:
                // A delete may have landed between the lookup and the rename: it unlinked the old record
                // and wrote its tombstone, and the rename just re-created the record. Take it back out.
                let tombstonePath = scopeDir
                    .appending(components: "\(record.id).deleted.json", directoryHint: .notDirectory)
                    .path(percentEncoded: false)
                var tombstoneStat = stat()
                if lstat(tombstonePath, &tombstoneStat) == 0 {
                    Darwin.unlink(targetURL.path(percentEncoded: false))
                    return false
                }
                return true
            case .unavailable:
                return false
            }
        case .deleted, .expired, .missing, .unreadable:
            return false
        }
    }

    /// Deletes selected records and writes tombstones.
    ///
    /// Reports `deleted`, `alreadyMissing`, or `failed(cause:)` for each id.
    public func delete(ids: [String], in scope: DispatchPromptScope) -> [DispatchPromptDeletion] {
        ids.map { id in
            deleteSingle(id: id, in: scope)
        }
    }

    private func deleteSingle(id: String, in scope: DispatchPromptScope) -> DispatchPromptDeletion {
        if let error = validateIdentifier(id, name: "record ID") {
            return .failed(cause: error)
        }
        let scopeDir = directory(for: scope)
        let recordURL = scopeDir.appending(components: "\(id).json", directoryHint: .notDirectory)
        let recordPath = recordURL.path(percentEncoded: false)
        var recordStat = stat()
        if lstat(recordPath, &recordStat) != 0 {
            if errno == ENOENT {
                return .alreadyMissing
            }
            return .failed(cause: "could not stat record file: \(String(cString: strerror(errno)))")
        }

        // Unlink first: a failed unlink leaves the record intact with no tombstone, so a retry works
        // and nothing reports the content gone while it is still on disk.
        let details = extractDeletionDetails(recordURL: recordURL, recordPath: recordPath)
        if Darwin.unlink(recordPath) != 0 {
            if errno == ENOENT {
                return .alreadyMissing
            }
            return .failed(cause: "could not remove record file: \(String(cString: strerror(errno)))")
        }

        // The content is gone from here on, so a tombstone failure still reports `.deleted`.
        writeTombstone(for: id, details: details, in: scope)
        return .deleted
    }

    private func writeTombstone(for id: String, details: DeletionDetails, in scope: DispatchPromptScope) {
        guard case .success(let ensuredDir) = ensureRestrictedDirectoryTree(for: scope) else {
            return
        }
        let tombstone = DispatchPromptTombstone(
            id: id,
            dispatchedAt: details.dispatchedAt,
            deletedAt: now(),
            runID: details.runID,
            family: details.family,
            route: details.route
        )
        guard let data = try? DispatchPromptRecord.makeJSONEncoder().encode(tombstone) else {
            return
        }
        let tombstoneURL = ensuredDir.appending(components: "\(id).deleted.json", directoryHint: .notDirectory)
        _ = writeRestrictedFile(data: data, to: tombstoneURL, in: ensuredDir)
    }

    private struct DeletionDetails {
        let dispatchedAt: Date
        let runID: String?
        let family: PromptFamily?
        let route: String?
    }

    private func extractDeletionDetails(recordURL: URL, recordPath: String) -> DeletionDetails {
        if let data = try? Data(contentsOf: recordURL),
           let record = try? DispatchPromptRecord.makeJSONDecoder().decode(DispatchPromptRecord.self, from: data) {
            return DeletionDetails(
                dispatchedAt: record.dispatchedAt,
                runID: record.provenance.runID,
                family: record.provenance.family,
                route: record.route
            )
        }
        var st = stat()
        if lstat(recordPath, &st) == 0 {
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            return DeletionDetails(dispatchedAt: modified, runID: nil, family: nil, route: nil)
        }
        return DeletionDetails(dispatchedAt: now(), runID: nil, family: nil, route: nil)
    }

    /// Removes all records for a project entirely. Missing directory counts as success.
    public func removeAll(projectID: ProjectID) throws {
        try removeAll(projectID: projectID.rawValue)
    }

    /// Removes all records for a project string entirely. Missing directory counts as success.
    public func removeAll(projectID: String) throws {
        if let error = validateIdentifier(projectID, name: "Project ID") {
            throw DispatchPromptStoreError.invalidIdentifier(error)
        }
        let projectDir = rootDirectory.appending(components: "projects", projectID, directoryHint: .isDirectory)
        let path = projectDir.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: projectDir)
        } catch {
            throw DispatchPromptStoreError.directoryRemovalFailed(projectDir, String(describing: error))
        }
    }

    /// Verifies and establishes mode 0700 current-user ownership on the directory hierarchy.
    func ensureRestrictedDirectoryTree(for scope: DispatchPromptScope) -> Result<URL, RestrictionError> {
        let directoriesResult = resolveScopeDirectories(for: scope)
        guard case .success(let directories) = directoriesResult else {
            return directoriesResult.map { $0.last! }
        }

        for dir in directories {
            if case .failure(let error) = ensureSingleRestrictedDirectory(at: dir) {
                return .failure(error)
            }
        }

        return .success(directories.last!)
    }

    private func resolveScopeDirectories(
        for scope: DispatchPromptScope
    ) -> Result<[URL], RestrictionError> {
        switch scope {
        case .project(let projectID):
            if let err = validateIdentifier(projectID.rawValue, name: "Project ID") {
                return .failure(RestrictionError(message: err))
            }
            let projectsDir = rootDirectory.appending(components: "projects", directoryHint: .isDirectory)
            let scopeDir = projectsDir.appending(components: projectID.rawValue, directoryHint: .isDirectory)
            return .success([rootDirectory, projectsDir, scopeDir])
        case .machine:
            let machineDir = rootDirectory.appending(components: "machine", directoryHint: .isDirectory)
            return .success([rootDirectory, machineDir])
        }
    }

    func ensureSingleRestrictedDirectory(at dir: URL) -> Result<Void, RestrictionError> {
        let path = dir.path(percentEncoded: false)
        var statBuf = stat()
        if lstat(path, &statBuf) != 0 {
            if errno == ENOENT {
                if Darwin.mkdir(path, 0o700) != 0 {
                    return .failure(
                        RestrictionError(
                            message: "could not create directory at \(path): \(String(cString: strerror(errno)))"
                        )
                    )
                }
                if lstat(path, &statBuf) != 0 {
                    return .failure(
                        RestrictionError(
                            message: "could not stat directory at \(path): \(String(cString: strerror(errno)))"
                        )
                    )
                }
            } else {
                return .failure(
                    RestrictionError(
                        message: "could not stat directory at \(path): \(String(cString: strerror(errno)))"
                    )
                )
            }
        }

        return checkAndTightenDirectory(path: path, statBuf: &statBuf)
    }

    private func checkAndTightenDirectory(
        path: String,
        statBuf: inout stat
    ) -> Result<Void, RestrictionError> {
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

        if (statBuf.st_mode & 0o777) != 0o700 {
            if Darwin.chmod(path, 0o700) != 0 {
                return .failure(
                    RestrictionError(
                        message: "failed to chmod 0700 on directory at \(path): \(String(cString: strerror(errno)))"
                    )
                )
            }
            if lstat(path, &statBuf) != 0 {
                return .failure(
                    RestrictionError(
                        message: "could not re-stat directory at \(path): \(String(cString: strerror(errno)))"
                    )
                )
            }
            if (statBuf.st_mode & 0o777) != 0o700 {
                return .failure(
                    RestrictionError(message: "tightening permissions to 0700 failed for directory at \(path)")
                )
            }
            if statBuf.st_uid != currentUser {
                return .failure(RestrictionError(message: "directory at \(path) owner changed after tightening"))
            }
        }

        return Self.clearExtendedACL(path: path)
    }

    /// Writes data to a temporary file in `scopeDirectory`, validates owner and mode via `fstat`, fsyncs,
    /// and renames to `targetURL`. Cleans up temporary file on any error.
    func writeRestrictedFile(data: Data, to targetURL: URL, in scopeDirectory: URL) -> DispatchPromptCapture {
        let targetPath = targetURL.path(percentEncoded: false)
        let tempFileName = ".\(targetURL.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        let tempURL = scopeDirectory.appending(components: tempFileName, directoryHint: .notDirectory)
        let tempPath = tempURL.path(percentEncoded: false)

        let flags = O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW
        let fd = Darwin.open(tempPath, flags, 0o600)
        guard fd >= 0 else {
            return .unavailable(
                cause: "could not open temporary file at \(tempPath): \(String(cString: strerror(errno)))"
            )
        }

        var cleanUpNeeded = true
        defer {
            if cleanUpNeeded {
                Darwin.unlink(tempPath)
            }
        }

        if case .failure(let error) = validateTempFileDescriptor(fd: fd) {
            Darwin.close(fd)
            return .unavailable(cause: error.message)
        }

        guard writeAllBytes(fd: fd, data: data) else {
            Darwin.close(fd)
            return .unavailable(cause: "failed to write temporary file bytes: \(String(cString: strerror(errno)))")
        }

        guard Darwin.fsync(fd) == 0 else {
            Darwin.close(fd)
            return .unavailable(cause: "failed to fsync temporary file: \(String(cString: strerror(errno)))")
        }

        guard Darwin.close(fd) == 0 else {
            return .unavailable(cause: "failed to close temporary file: \(String(cString: strerror(errno)))")
        }

        guard Darwin.rename(tempPath, targetPath) == 0 else {
            return .unavailable(
                cause: "failed to rename temporary file into place: \(String(cString: strerror(errno)))"
            )
        }

        cleanUpNeeded = false
        return .recorded(id: targetURL.deletingPathExtension().lastPathComponent)
    }

    private func validateTempFileDescriptor(fd: Int32) -> Result<Void, RestrictionError> {
        var statBuf = stat()
        guard fstat(fd, &statBuf) == 0 else {
            return .failure(
                RestrictionError(message: "could not fstat temporary file: \(String(cString: strerror(errno)))")
            )
        }

        guard (statBuf.st_mode & S_IFMT) == S_IFREG else {
            return .failure(RestrictionError(message: "temporary file is not a regular file"))
        }

        guard statBuf.st_uid == currentUser else {
            return .failure(
                RestrictionError(
                    message: "temporary file owner mismatch: expected uid \(currentUser), found \(statBuf.st_uid)"
                )
            )
        }

        guard (statBuf.st_mode & 0o077) == 0 else {
            let modeStr = String(format: "%04o", statBuf.st_mode & 0o777)
            return .failure(
                RestrictionError(message: "temporary file mode has group or other bits: \(modeStr)")
            )
        }

        // A file created in a directory with an inheritable ACL inherits it; clear it before any byte lands.
        return Self.clearExtendedACL(fd: fd)
    }

    private func writeAllBytes(fd: Int32, data: Data) -> Bool {
        var writeFailed = false
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            let total = rawBuffer.count
            while written < total {
                let count = Darwin.write(fd, baseAddress.advanced(by: written), total - written)
                if count <= 0 {
                    if errno == EINTR { continue }
                    writeFailed = true
                    break
                }
                written += count
            }
        }
        return !writeFailed
    }
}
