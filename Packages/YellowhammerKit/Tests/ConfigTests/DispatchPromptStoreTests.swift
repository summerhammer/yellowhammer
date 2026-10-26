import Config
import Darwin
import Domain
import Foundation
import Testing

@Suite("DispatchPromptStore (P18 prompt evidence model and store)")
struct DispatchPromptStoreTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(components: "yh-prompt-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func fileMode(at url: URL) -> mode_t? {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        return st.st_mode & 0o777
    }

    private func fileOwner(at url: URL) -> uid_t? {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        return st.st_uid
    }

    private func makeRecord(
        id: String,
        projectID: String? = "proj-1",
        family: PromptFamily = .worker,
        pass: RunPass = .worker,
        dispatchedAt: Date = Date(),
        instruction: String = "test instruction",
        outputSchema: String? = "{\"type\":\"object\"}"
    ) -> DispatchPromptRecord {
        let roundedDate = Date(timeIntervalSince1970: floor(dispatchedAt.timeIntervalSince1970))
        let provenance = DispatchProvenance(
            recordID: id,
            family: family,
            projectID: projectID
        )
        return DispatchPromptRecord(
            provenance: provenance,
            route: "claude-code/sonnet/high",
            pass: pass,
            dispatchedAt: roundedDate,
            defaultVersion: 1,
            projectInstructions: .absent,
            session: .new,
            instruction: instruction,
            outputSchema: outputSchema,
            launch: .pending
        )
    }

    @Test("rootDirectory returns <configurationDirectory>/prompts")
    func rootDirectoryPath() {
        let configDir = URL(fileURLWithPath: "/tmp/yh-config", isDirectory: true)
        let root = DispatchPromptStore.rootDirectory(configurationDirectory: configDir)
        #expect(root.path(percentEncoded: false) == "/tmp/yh-config/prompts")
    }

    @Test("Capture establishes file mode 0600 and directory mode 0700 owned by current user")
    func fileMode0600AndDirectoryMode0700() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DispatchPromptStore(rootDirectory: root)
        let projectRecord = makeRecord(id: "rec-p1", projectID: "proj-1")
        let machineRecord = makeRecord(id: "rec-m1", projectID: nil, family: .unattendedProbe, pass: .architect)

        let captureP = store.capture(projectRecord)
        #expect(captureP == .recorded(id: "rec-p1"))

        let captureM = store.capture(machineRecord)
        #expect(captureM == .recorded(id: "rec-m1"))

        let uid = getuid()

        // Root directory
        #expect(fileMode(at: root) == 0o700)
        #expect(fileOwner(at: root) == uid)

        // Projects directories
        let projectsDir = root.appending(components: "projects", directoryHint: .isDirectory)
        #expect(fileMode(at: projectsDir) == 0o700)
        #expect(fileOwner(at: projectsDir) == uid)

        let project1Dir = projectsDir.appending(components: "proj-1", directoryHint: .isDirectory)
        #expect(fileMode(at: project1Dir) == 0o700)
        #expect(fileOwner(at: project1Dir) == uid)

        // Machine directory
        let machineDir = root.appending(components: "machine", directoryHint: .isDirectory)
        #expect(fileMode(at: machineDir) == 0o700)
        #expect(fileOwner(at: machineDir) == uid)

        // Files
        let projectFile = project1Dir.appending(components: "rec-p1.json", directoryHint: .notDirectory)
        #expect(fileMode(at: projectFile) == 0o600)
        #expect(fileOwner(at: projectFile) == uid)

        let machineFile = machineDir.appending(components: "rec-m1.json", directoryHint: .notDirectory)
        #expect(fileMode(at: machineFile) == 0o600)
        #expect(fileOwner(at: machineFile) == uid)
    }

    @Test("An existing 0755 scope directory is tightened to 0700 on capture")
    func scopeDirectoryTightenedFrom0755() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let projectDir = root.appending(components: "projects", "proj-tighten", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        Darwin.chmod(projectDir.path(percentEncoded: false), 0o755)
        #expect(fileMode(at: projectDir) == 0o755)

        let store = DispatchPromptStore(rootDirectory: root)
        let record = makeRecord(id: "rec-tighten", projectID: "proj-tighten")
        let result = store.capture(record)
        #expect(result == .recorded(id: "rec-tighten"))

        #expect(fileMode(at: projectDir) == 0o700)
    }

    @Test("An injected currentUser mismatch gives .unavailable, leaving no file")
    func currentUserMismatchGivesUnavailable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let mismatchedUID = getuid() + 10_000
        let store = DispatchPromptStore(rootDirectory: root, currentUser: mismatchedUID)
        let record = makeRecord(id: "rec-mismatch", projectID: "proj-mismatch")

        let result = store.capture(record)
        guard case .unavailable(let cause) = result else {
            Issue.record("expected .unavailable, got \(result)")
            return
        }
        #expect(!cause.isEmpty)

        let targetFile = root.appending(
            components: "projects", "proj-mismatch", "rec-mismatch.json",
            directoryHint: .notDirectory
        )
        #expect(!FileManager.default.fileExists(atPath: targetFile.path(percentEncoded: false)))
    }

    @Test("The expiry boundary at exactly 30 days, using an injected now")
    func expiryBoundaryAtExactly30Days() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dispatchInstant = Date(timeIntervalSince1970: 1_700_000_000)
        nonisolated(unsafe) var currentInstant = dispatchInstant

        let store = DispatchPromptStore(
            rootDirectory: root,
            now: { currentInstant }
        )
        let record = makeRecord(id: "rec-exp", projectID: "proj-exp", dispatchedAt: dispatchInstant)
        let captureResult = store.capture(record)
        #expect(captureResult == .recorded(id: "rec-exp"))

        let scope = record.provenance.scope

        // 1 second before 30 days: available
        currentInstant = dispatchInstant.addingTimeInterval(30 * 86_400 - 1)
        #expect(store.lookup(id: "rec-exp", scope: scope) == .available(record))

        // Exactly 30 days: expired
        currentInstant = dispatchInstant.addingTimeInterval(30 * 86_400)
        #expect(store.lookup(id: "rec-exp", scope: scope) == .expired(dispatchedAt: dispatchInstant))

        // 1 second past 30 days: expired
        currentInstant = dispatchInstant.addingTimeInterval(30 * 86_400 + 1)
        #expect(store.lookup(id: "rec-exp", scope: scope) == .expired(dispatchedAt: dispatchInstant))

        // sweepExpired unlinks the expired record file
        let sweepFailures = store.sweepExpired(in: scope)
        #expect(sweepFailures.isEmpty)

        // After sweep, lookup reports missing
        #expect(store.lookup(id: "rec-exp", scope: scope) == .missing)
    }

    @Test("Delete gives deleted, then alreadyMissing, then .deleted on lookup, with no prompt text in tombstone")
    func deleteLifecycle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dispatchInstant = Date(timeIntervalSince1970: 1_700_000_000)
        let deleteInstant = Date(timeIntervalSince1970: 1_700_050_000)
        nonisolated(unsafe) var currentInstant = dispatchInstant

        let store = DispatchPromptStore(
            rootDirectory: root,
            now: { currentInstant }
        )
        let record = makeRecord(
            id: "rec-del",
            projectID: "proj-del",
            dispatchedAt: dispatchInstant,
            instruction: "super secret private prompt text"
        )
        #expect(store.capture(record) == .recorded(id: "rec-del"))

        let scope = record.provenance.scope
        currentInstant = deleteInstant

        // First delete gives deleted
        let firstDelete = store.delete(ids: ["rec-del"], in: scope)
        #expect(firstDelete == [.deleted])

        // Second delete gives alreadyMissing
        let secondDelete = store.delete(ids: ["rec-del"], in: scope)
        #expect(secondDelete == [.alreadyMissing])

        // Lookup gives .deleted(deletedAt:)
        let lookupResult = store.lookup(id: "rec-del", scope: scope)
        #expect(lookupResult == .deleted(deletedAt: deleteInstant))

        // Verify tombstone on disk exists and contains NO prompt text
        let tombstoneURL = root.appending(
            components: "projects", "proj-del", "rec-del.deleted.json",
            directoryHint: .notDirectory
        )
        let tombstoneText = try String(contentsOf: tombstoneURL, encoding: .utf8)
        #expect(!tombstoneText.contains("super secret private prompt text"))
        #expect(tombstoneText.contains("\"id\":\"rec-del\""))
        #expect(fileMode(at: tombstoneURL) == 0o600)

        // Record file is gone
        let recordURL = root.appending(
            components: "projects", "proj-del", "rec-del.json",
            directoryHint: .notDirectory
        )
        #expect(!FileManager.default.fileExists(atPath: recordURL.path(percentEncoded: false)))
    }

    @Test("markLaunch updates an un-deleted record, but refuses after delete")
    func markLaunchRefusesAfterDelete() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DispatchPromptStore(rootDirectory: root)
        let record = makeRecord(id: "rec-launch", projectID: "proj-launch")
        #expect(store.capture(record) == .recorded(id: "rec-launch"))

        let scope = record.provenance.scope

        // Updating launch before delete succeeds
        let marked = store.markLaunch(.launched, of: record)
        #expect(marked)
        guard case .available(let updated) = store.lookup(id: "rec-launch", scope: scope) else {
            Issue.record("expected .available")
            return
        }
        #expect(updated.launch == .launched)

        // Delete record
        let deleted = store.delete(ids: ["rec-launch"], in: scope)
        #expect(deleted == [.deleted])

        // markLaunch after delete returns false and writes nothing
        let markedAfterDelete = store.markLaunch(.notLaunched(cause: "should be refused"), of: record)
        #expect(!markedAfterDelete)

        // Lookup still reports .deleted
        guard case .deleted = store.lookup(id: "rec-launch", scope: scope) else {
            Issue.record("expected .deleted")
            return
        }

        // markLaunch on missing record returns false
        let missingRecord = makeRecord(id: "rec-missing", projectID: "proj-launch")
        #expect(!store.markLaunch(.launched, of: missingRecord))
    }

    @Test("removeAll removes only the target Project and stays inside its scope")
    func removeAllStaysInsideScope() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DispatchPromptStore(rootDirectory: root)
        let recordA = makeRecord(id: "rec-a", projectID: "proj-a")
        let recordB = makeRecord(id: "rec-b", projectID: "proj-b")
        let recordM = makeRecord(id: "rec-m", projectID: nil, family: .unattendedProbe, pass: .architect)

        #expect(store.capture(recordA) == .recorded(id: "rec-a"))
        #expect(store.capture(recordB) == .recorded(id: "rec-b"))
        #expect(store.capture(recordM) == .recorded(id: "rec-m"))

        let scopeA = recordA.provenance.scope
        let scopeB = recordB.provenance.scope
        let scopeM = recordM.provenance.scope

        try store.removeAll(projectID: ProjectID(rawValue: "proj-a")!)

        // Proj-a is completely gone
        #expect(store.lookup(id: "rec-a", scope: scopeA) == .missing)
        let projADir = root.appending(components: "projects", "proj-a", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: projADir.path(percentEncoded: false)))

        // Proj-b and Machine are untouched
        #expect(store.lookup(id: "rec-b", scope: scopeB) == .available(recordB))
        #expect(store.lookup(id: "rec-m", scope: scopeM) == .available(recordM))

        // Calling removeAll again on missing directory succeeds
        try store.removeAll(projectID: "proj-a")
    }

    @Test("entries lists records and tombstones sorted oldest dispatch first")
    func entriesSortedOldestFirst() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = DispatchPromptStore(
            rootDirectory: root,
            now: { baseDate.addingTimeInterval(300) }
        )

        let record1 = makeRecord(id: "rec-1", projectID: "proj-list", dispatchedAt: baseDate.addingTimeInterval(100))
        let record2 = makeRecord(id: "rec-2", projectID: "proj-list", dispatchedAt: baseDate.addingTimeInterval(50))
        let record3 = makeRecord(id: "rec-3", projectID: "proj-list", dispatchedAt: baseDate.addingTimeInterval(200))

        #expect(store.capture(record1) == .recorded(id: "rec-1"))
        #expect(store.capture(record2) == .recorded(id: "rec-2"))
        #expect(store.capture(record3) == .recorded(id: "rec-3"))

        let scope = record1.provenance.scope

        // Delete record2
        _ = store.delete(ids: ["rec-2"], in: scope)

        let entries = store.entries(in: scope)
        #expect(entries.count == 3)
        // Order must be rec-2 (T+50), rec-1 (T+100), rec-3 (T+200)
        #expect(entries.map(\.id) == ["rec-2", "rec-1", "rec-3"])

        guard case .deleted = entries[0].lookup else {
            Issue.record("expected entries[0] to be .deleted")
            return
        }
        guard case .available = entries[1].lookup else {
            Issue.record("expected entries[1] to be .available")
            return
        }
        guard case .available = entries[2].lookup else {
            Issue.record("expected entries[2] to be .available")
            return
        }
    }

    @Test("Store refuses invalid identifiers with slashes, dots, or empty strings")
    func refusesInvalidIdentifiers() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DispatchPromptStore(rootDirectory: root)
        let invalidRecord = makeRecord(id: "rec/bad", projectID: "proj-1")
        let expectedCause = "record ID contains invalid path components: \"rec/bad\""
        #expect(store.capture(invalidRecord) == .unavailable(cause: expectedCause))

        let dotRecord = makeRecord(id: "..", projectID: "proj-1")
        #expect(store.capture(dotRecord) == .unavailable(cause: "record ID contains invalid path components: \"..\""))

        #expect(store.lookup(id: "", scope: .machine) == .unreadable(cause: "record ID is empty"))

        let del = store.delete(ids: ["rec/bad"], in: .machine)
        #expect(del == [.failed(cause: "record ID contains invalid path components: \"rec/bad\"")])

        #expect(throws: DispatchPromptStoreError.self) {
            try store.removeAll(projectID: "../sneaky")
        }
    }
}
