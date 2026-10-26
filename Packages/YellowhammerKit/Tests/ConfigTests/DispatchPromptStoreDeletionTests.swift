import Config
import Darwin
import Domain
import Foundation
import Testing

/// Runs `/usr/bin/chflags` on a path; the immutable flag makes `unlink` fail for the owner.
func setFileFlag(_ flag: String, on url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
    process.arguments = [flag, url.path(percentEncoded: false)]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteNoPermission)
    }
}

func makeStoreTestRecord(
    id: String,
    projectID: String? = "proj-1",
    runID: String? = nil,
    family: PromptFamily = .worker,
    dispatchedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> DispatchPromptRecord {
    let provenance = DispatchProvenance(recordID: id, family: family, projectID: projectID, runID: runID)
    return DispatchPromptRecord(
        provenance: provenance,
        route: "claude-code/sonnet/high",
        pass: .worker,
        dispatchedAt: dispatchedAt,
        defaultVersion: 1,
        projectInstructions: .absent,
        session: .new,
        instruction: "test instruction",
        outputSchema: nil,
        launch: .pending
    )
}

@Suite("DispatchPromptStore deletion truthfulness")
struct DispatchPromptStoreDeletionTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(components: "yh-prompt-store-del-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    @Test("A failed unlink is reported failed, leaves no tombstone, and a retry deletes")
    func failedUnlinkIsNotSuccess() throws {
        let root = try makeTemporaryDirectory()
        let record = makeStoreTestRecord(id: "rec-uchg")
        let store = DispatchPromptStore(rootDirectory: root, now: { Date(timeIntervalSince1970: 1_700_000_100) })
        #expect(store.capture(record) == .recorded(id: "rec-uchg"))
        let scope = record.provenance.scope

        let scopeDir = store.directory(for: scope)
        let recordURL = scopeDir.appending(components: "rec-uchg.json", directoryHint: .notDirectory)
        let tombstoneURL = scopeDir.appending(components: "rec-uchg.deleted.json", directoryHint: .notDirectory)
        try setFileFlag("uchg", on: recordURL)
        defer {
            try? setFileFlag("nouchg", on: recordURL)
            try? FileManager.default.removeItem(at: root)
        }

        let failed = store.delete(ids: ["rec-uchg"], in: scope)
        guard case .failed = failed.first else {
            Issue.record("expected .failed, got \(failed)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL.path(percentEncoded: false)))
        #expect(store.lookup(id: "rec-uchg", scope: scope) == .available(record))

        try setFileFlag("nouchg", on: recordURL)
        #expect(store.delete(ids: ["rec-uchg"], in: scope) == [.deleted])
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_100)
        #expect(store.lookup(id: "rec-uchg", scope: scope) == .deleted(deletedAt: deletedAt))
    }

    private func writeLeftoverTombstone(store: DispatchPromptStore, record: DispatchPromptRecord) throws {
        let tombstone = DispatchPromptTombstone(
            id: record.id,
            dispatchedAt: record.dispatchedAt,
            deletedAt: record.dispatchedAt.addingTimeInterval(10)
        )
        let data = try DispatchPromptRecord.makeJSONEncoder().encode(tombstone)
        let url = store.directory(for: record.provenance.scope)
            .appending(components: "\(record.id).deleted.json", directoryHint: .notDirectory)
        #expect(FileManager.default.createFile(
            atPath: url.path(percentEncoded: false), contents: data, attributes: [.posixPermissions: 0o600]
        ))
    }

    @Test("A leftover tombstone beside a record is served as the record, and delete removes it")
    func leftoverPairServesRecord() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DispatchPromptStore(rootDirectory: root, now: { Date(timeIntervalSince1970: 1_700_000_100) })
        let record = makeStoreTestRecord(id: "rec-pair")
        #expect(store.capture(record) == .recorded(id: "rec-pair"))
        try writeLeftoverTombstone(store: store, record: record)
        let scope = record.provenance.scope

        #expect(store.lookup(id: "rec-pair", scope: scope) == .available(record))
        #expect(store.delete(ids: ["rec-pair"], in: scope) == [.deleted])
        let recordURL = store.directory(for: scope).appending(components: "rec-pair.json", directoryHint: .notDirectory)
        #expect(!FileManager.default.fileExists(atPath: recordURL.path(percentEncoded: false)))
    }

    @Test("sweepExpired removes an expired record that has a leftover tombstone")
    func sweepRemovesExpiredLeftoverPair() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatched = Date(timeIntervalSince1970: 1_700_000_000)
        let store = DispatchPromptStore(rootDirectory: root, now: { dispatched.addingTimeInterval(31 * 86_400) })
        let record = makeStoreTestRecord(id: "rec-old", dispatchedAt: dispatched)
        #expect(store.capture(record) == .recorded(id: "rec-old"))
        try writeLeftoverTombstone(store: store, record: record)
        let scope = record.provenance.scope

        #expect(store.lookup(id: "rec-old", scope: scope) == .expired(dispatchedAt: dispatched))
        #expect(store.sweepExpired(in: scope).isEmpty)
        let recordURL = store.directory(for: scope).appending(components: "rec-old.json", directoryHint: .notDirectory)
        #expect(!FileManager.default.fileExists(atPath: recordURL.path(percentEncoded: false)))
    }

    @Test("A tombstone carries the deleted record's runID and family")
    func tombstoneCarriesRunIDAndFamily() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DispatchPromptStore(rootDirectory: root)
        let record = makeStoreTestRecord(id: "rec-run", runID: "run-42", family: .worker)
        #expect(store.capture(record) == .recorded(id: "rec-run"))
        #expect(store.delete(ids: ["rec-run"], in: record.provenance.scope) == [.deleted])

        let tombstoneURL = store.directory(for: record.provenance.scope)
            .appending(components: "rec-run.deleted.json", directoryHint: .notDirectory)
        let tombstone = try DispatchPromptRecord.makeJSONDecoder()
            .decode(DispatchPromptTombstone.self, from: Data(contentsOf: tombstoneURL))
        #expect(tombstone.runID == "run-42")
        #expect(tombstone.family == .worker)
    }
}
