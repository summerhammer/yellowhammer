import Darwin
import Domain
import Foundation

/// Current-user-only local storage for one Project's saved instructions.
///
/// The single file lives in its own `instructions` subdirectory of the Project's prompt directory, so
/// `DispatchPromptStore` neither lists it as a dispatch record nor sweeps it. Project removal deletes it
/// together with the rest of that directory.
public struct ProjectInstructionsStore: Sendable {
    public let rootDirectory: URL
    public let projectID: ProjectID
    public let currentUser: uid_t
    public let now: @Sendable () -> Date

    public init(
        rootDirectory: URL,
        projectID: ProjectID,
        currentUser: uid_t = getuid(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.projectID = projectID
        self.currentUser = currentUser
        self.now = now
    }

    var instructionsDirectory: URL {
        // No trailing slash: `lstat("link/")` would follow a symlink instead of reporting it.
        rootDirectory.appending(
            components: "projects", projectID.rawValue, "instructions", directoryHint: .notDirectory
        )
    }

    var currentFile: URL {
        instructionsDirectory.appending(components: "current.json", directoryHint: .notDirectory)
    }

    private var lockFile: URL {
        instructionsDirectory.appending(components: ".lock", directoryHint: .notDirectory)
    }

    /// Shares the restricted-directory and restricted-file helpers with the dispatch prompt store.
    private var helper: DispatchPromptStore {
        DispatchPromptStore(rootDirectory: rootDirectory, currentUser: currentUser, now: now)
    }

    // MARK: Reading

    public func read() -> ProjectInstructionsRead {
        let path = currentFile.path(percentEncoded: false)
        var statBuf = stat()
        if lstat(path, &statBuf) != 0 {
            if errno == ENOENT { return .absent }
            return .unavailable(cause: "could not stat saved Project instructions: \(String(cString: strerror(errno)))")
        }
        let helper = helper
        let kind = "Project instructions file"
        if case .failure(let error) = helper.verifyFilePermissions(statBuf: statBuf, path: path, kind: kind) {
            return .unavailable(cause: error.message)
        }
        if (statBuf.st_mode & S_IFMT) != S_IFREG {
            return .unavailable(cause: "Project instructions file is not a regular file")
        }
        if case .failure(let error) = helper.verifyDirectoryHierarchyOnRead(scopeDir: instructionsDirectory) {
            return .unavailable(cause: error.message)
        }
        guard let data = try? Data(contentsOf: currentFile) else {
            return .unavailable(cause: "could not read saved Project instructions")
        }
        let revision: ProjectInstructionsRevision
        do {
            revision = try ProjectInstructionsStore.makeDecoder().decode(ProjectInstructionsRevision.self, from: data)
        } catch {
            return .unavailable(cause: "could not decode saved Project instructions")
        }
        if case .tooLarge(let byteCount) = ProjectInstructions.validate(revision.text) {
            return .unavailable(
                cause: "saved Project instructions are \(byteCount) bytes, over the "
                    + "\(ProjectInstructions.maximumByteCount)-byte limit"
            )
        }
        return .saved(revision)
    }

    // MARK: Writing

    /// Saves `text` if the saved state still is `base`; otherwise writes nothing and reports a conflict.
    public func save(
        _ text: String,
        replacing base: ProjectInstructionsUse,
        reviewedDefaultVersions: [PromptFamily: Int] = PromptFamily.productionDefaultVersions
    ) -> ProjectInstructionsSave {
        if case .tooLarge(let byteCount) = ProjectInstructions.validate(text) {
            return .tooLarge(byteCount: byteCount, limit: ProjectInstructions.maximumByteCount)
        }
        return withLock { _ in
            let current = read()
            guard matches(current, base: base) else { return .conflict(current: current) }
            if ProjectInstructions.isEmpty(text) {
                return removeCurrentFile()
            }
            return write(text: text, reviewedDefaultVersions: reviewedDefaultVersions)
        }
    }

    /// Records `defaultVersions` as reviewed on a new revision with the same text.
    public func acknowledgeReview(
        of revisionID: String,
        defaultVersions: [PromptFamily: Int] = PromptFamily.productionDefaultVersions
    ) -> ProjectInstructionsSave {
        withLock { _ in
            let current = read()
            guard case .saved(let revision) = current, revision.id == revisionID else {
                return .conflict(current: current)
            }
            return write(text: revision.text, reviewedDefaultVersions: defaultVersions)
        }
    }

    /// Removes the saved instructions whether or not they can be read. Touches no prompt record.
    public func reset() -> ProjectInstructionsReset {
        let directory = instructionsDirectory.path(percentEncoded: false)
        var statBuf = stat()
        if lstat(directory, &statBuf) != 0 {
            return errno == ENOENT ? .cleared : .failed(cause: "could not stat \(directory): \(errnoText())")
        }
        // A symlinked directory is removed as a link; unlinking inside it would delete a file elsewhere.
        if (statBuf.st_mode & S_IFMT) != S_IFDIR {
            return Darwin.unlink(directory) == 0
                ? .cleared : .failed(cause: "could not remove \(directory): \(errnoText())")
        }
        let fd = Darwin.open(
            lockFile.path(percentEncoded: false), O_CREAT | O_RDWR | O_NOFOLLOW, 0o600
        )
        defer { if fd >= 0 { Darwin.close(fd) } }
        if fd >= 0 { _ = flock(fd, LOCK_EX) }
        let path = currentFile.path(percentEncoded: false)
        if Darwin.unlink(path) != 0, errno != ENOENT {
            return .failed(cause: "could not remove saved Project instructions: \(errnoText())")
        }
        return .cleared
    }

    // MARK: Internals

    private func matches(_ current: ProjectInstructionsRead, base: ProjectInstructionsUse) -> Bool {
        switch (current, base) {
        case (.absent, .absent): true
        case (.saved(let revision), .revision(let id)): revision.id == id
        default: false
        }
    }

    private func write(text: String, reviewedDefaultVersions: [PromptFamily: Int]) -> ProjectInstructionsSave {
        let revision = ProjectInstructionsRevision(
            id: UUID().uuidString.lowercased(),
            text: text,
            savedAt: Date(timeIntervalSince1970: floor(now().timeIntervalSince1970)),
            reviewedDefaultVersions: reviewedDefaultVersions
        )
        let data: Data
        do {
            data = try ProjectInstructionsStore.makeEncoder().encode(revision)
        } catch {
            return .failed(cause: "failed to encode Project instructions: \(error)")
        }
        switch helper.writeRestrictedFile(data: data, to: currentFile, in: instructionsDirectory) {
        case .recorded: return .saved(revision)
        case .unavailable(let cause): return .failed(cause: cause)
        }
    }

    private func removeCurrentFile() -> ProjectInstructionsSave {
        if Darwin.unlink(currentFile.path(percentEncoded: false)) != 0, errno != ENOENT {
            return .failed(cause: "could not remove saved Project instructions: \(errnoText())")
        }
        return .cleared
    }

    /// Establishes the restricted directories, then runs `body` holding an exclusive `flock`.
    private func withLock(_ body: (Int32) -> ProjectInstructionsSave) -> ProjectInstructionsSave {
        let helper = helper
        switch helper.ensureRestrictedDirectoryTree(for: .project(projectID)) {
        case .failure(let error): return .failed(cause: error.message)
        case .success: break
        }
        if case .failure(let error) = helper.ensureSingleRestrictedDirectory(at: instructionsDirectory) {
            return .failed(cause: error.message)
        }
        let fd = Darwin.open(lockFile.path(percentEncoded: false), O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            return .failed(cause: "could not open lock file: \(errnoText())")
        }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { return .failed(cause: "could not lock Project instructions: \(errnoText())") }
        }
        defer { _ = flock(fd, LOCK_UN) }
        return body(fd)
    }

    private func errnoText() -> String {
        String(cString: strerror(errno))
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
