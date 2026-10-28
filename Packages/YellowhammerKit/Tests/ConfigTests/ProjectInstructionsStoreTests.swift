import Config
import Darwin
import Domain
import Foundation
import Testing

@Suite("ProjectInstructionsStore")
struct ProjectInstructionsStoreTests {
    private let projectID = ProjectID(rawValue: "proj-1")!

    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(components: "yh-instr-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(_ url: URL) -> mode_t? {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        return st.st_mode & 0o777
    }

    private func store(_ root: URL, user: uid_t = getuid()) -> ProjectInstructionsStore {
        ProjectInstructionsStore(rootDirectory: root, projectID: projectID, currentUser: user)
    }

    private func instructionsDir(_ root: URL) -> URL {
        root.appending(components: "projects", "proj-1", "instructions", directoryHint: .isDirectory)
    }

    private func currentFile(_ root: URL) -> URL {
        instructionsDir(root).appending(components: "current.json", directoryHint: .notDirectory)
    }

    private func saved(_ result: ProjectInstructionsSave) throws -> ProjectInstructionsRevision {
        guard case .saved(let revision) = result else {
            Issue.record("expected .saved, got \(result)")
            throw CancellationError()
        }
        return revision
    }

    @Test("A missing file reads as absent")
    func absent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store(root).read() == .absent)
    }

    @Test("Save then read returns the revision with the reviewed versions; ids are fresh")
    func saveAndRead() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try saved(store(root).save("Be terse.", replacing: .absent))
        #expect(store(root).read() == .saved(first))
        #expect(first.reviewedDefaultVersions == PromptFamily.productionDefaultVersions)
        #expect(first.id == first.id.lowercased())
        let second = try saved(store(root).save("Be terse.", replacing: .revision(first.id)))
        #expect(second.id != first.id)
    }

    @Test("Exactly 32,768 bytes saves; 32,769 and a multibyte overflow are refused and the old revision stays")
    func sizeLimit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = store(root)
        let full = try saved(subject.save(String(repeating: "a", count: 32_768), replacing: .absent))
        let before = try Data(contentsOf: currentFile(root))
        #expect(subject.save(String(repeating: "a", count: 32_769), replacing: .revision(full.id))
            == .tooLarge(byteCount: 32_769, limit: 32_768))
        #expect(subject.save(String(repeating: "é", count: 20_000), replacing: .revision(full.id))
            == .tooLarge(byteCount: 40_000, limit: 32_768))
        #expect(try Data(contentsOf: currentFile(root)) == before)
        #expect(subject.read() == .saved(full))
    }

    @Test("A stale base conflicts and writes nothing, in both directions")
    func conflicts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = store(root)
        let first = try saved(subject.save("one", replacing: .absent))
        let before = try Data(contentsOf: currentFile(root))
        #expect(subject.save("two", replacing: .absent) == .conflict(current: .saved(first)))
        #expect(subject.save("two", replacing: .revision("stale")) == .conflict(current: .saved(first)))
        #expect(subject.acknowledgeReview(of: "stale") == .conflict(current: .saved(first)))
        #expect(try Data(contentsOf: currentFile(root)) == before)

        #expect(subject.reset() == .cleared)
        #expect(subject.save("two", replacing: .revision(first.id)) == .conflict(current: .absent))
        #expect(subject.read() == .absent)
    }

    @Test("Empty text clears to shipped behaviour")
    func emptyClears() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = store(root)
        let first = try saved(subject.save("one", replacing: .absent))
        #expect(subject.save("  \n ", replacing: .revision(first.id)) == .cleared)
        #expect(subject.read() == .absent)
    }

    @Test("Directories are 0700 and the file is 0600")
    func modes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try saved(store(root).save("x", replacing: .absent))
        #expect(mode(instructionsDir(root)) == 0o700)
        #expect(mode(currentFile(root)) == 0o600)
        #expect(mode(instructionsDir(root).deletingLastPathComponent()) == 0o700)
    }

    @Test("A symlinked instructions directory refuses the save and the read")
    func symlinkRefused() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = try makeRoot()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let projectDir = root.appending(components: "projects", "proj-1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: projectDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(at: instructionsDir(root), withDestinationURL: elsewhere)

        guard case .failed = store(root).save("x", replacing: .absent) else {
            Issue.record("expected failure")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appending(component: "current.json").path))
    }

    @Test("A directory owned by someone else refuses the save and the read")
    func foreignOwner() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try saved(store(root).save("x", replacing: .absent))
        let foreign = store(root, user: getuid() &+ 1)
        guard case .unavailable = foreign.read() else {
            Issue.record("expected unavailable")
            return
        }
        guard case .failed = foreign.save("y", replacing: .absent) else {
            Issue.record("expected failure")
            return
        }
        #expect(store(root).read() != .absent)
    }

    @Test("Oversized, corrupt and loose-mode files are unavailable; reset clears them")
    func unavailableAndReset() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = store(root)
        let first = try saved(subject.save("x", replacing: .absent))
        let file = currentFile(root)

        let big = ProjectInstructionsRevision(
            id: first.id, text: String(repeating: "a", count: 32_769), savedAt: Date(timeIntervalSince1970: 0),
            reviewedDefaultVersions: [:]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(big).write(to: file)
        guard case .unavailable(let cause) = subject.read() else {
            Issue.record("expected unavailable")
            return
        }
        #expect(cause.contains("32769"))
        #expect(cause.contains("32768"))
        #expect(subject.save("y", replacing: .revision(first.id)) != .cleared)

        try Data("not json".utf8).write(to: file)
        guard case .unavailable = subject.read() else {
            Issue.record("expected unavailable")
            return
        }
        chmod(file.path(percentEncoded: false), 0o644)
        guard case .unavailable = subject.read() else {
            Issue.record("expected unavailable")
            return
        }

        #expect(subject.reset() == .cleared)
        #expect(subject.read() == .absent)
        #expect(subject.reset() == .cleared)
    }

    @Test("Acknowledging writes a new revision with the same text and the given versions")
    func acknowledge() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = store(root)
        var old = PromptFamily.productionDefaultVersions
        old[.worker] = 0
        let first = try saved(subject.save("keep", replacing: .absent, reviewedDefaultVersions: old))
        #expect(first.defaultChanges().map(\.family) == [.worker])
        let second = try saved(subject.acknowledgeReview(of: first.id))
        #expect(second.id != first.id)
        #expect(second.text == "keep")
        #expect(second.defaultChanges().isEmpty)
        #expect(subject.read() == .saved(second))
    }

    @Test("Dispatch record listing and the sweep neither list nor delete the instructions file")
    func invisibleToPromptStore() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try saved(store(root).save("x", replacing: .absent))
        let prompts = DispatchPromptStore(rootDirectory: root, now: { Date().addingTimeInterval(86_400 * 90) })
        #expect(prompts.entries(in: .project(projectID)).isEmpty)
        #expect(prompts.sweepExpired(in: .project(projectID)).isEmpty)
        guard case .saved = store(root).read() else {
            Issue.record("expected saved")
            return
        }
    }

    @Test("Reset leaves dispatch prompt records untouched; removeAll deletes the instructions")
    func resetAndRemoveAll() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prompts = DispatchPromptStore(rootDirectory: root)
        let record = DispatchPromptRecord(
            provenance: DispatchProvenance(recordID: "rec-1", family: .worker, projectID: "proj-1"),
            route: "claude/opus/high", pass: .worker, dispatchedAt: Date(), defaultVersion: 1,
            projectInstructions: .absent, session: .new, instruction: "hi", outputSchema: nil, launch: .launched
        )
        #expect(prompts.capture(record) == .recorded(id: "rec-1"))
        _ = try saved(store(root).save("x", replacing: .absent))
        #expect(store(root).reset() == .cleared)
        #expect(prompts.entries(in: .project(projectID)).count == 1)

        _ = try saved(store(root).save("x", replacing: .absent))
        try prompts.removeAll(projectID: projectID)
        #expect(!FileManager.default.fileExists(atPath: currentFile(root).path(percentEncoded: false)))
    }

    @Test("Two concurrent writers from the same base: exactly one wins")
    func concurrentWriters() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = store(root)
        let results = await withTaskGroup(of: ProjectInstructionsSave.self) { group in
            for index in 0..<8 {
                group.addTask { subject.save("writer \(index)", replacing: .absent) }
            }
            var all: [ProjectInstructionsSave] = []
            for await result in group { all.append(result) }
            return all
        }
        let wins = results.filter { if case .saved = $0 { true } else { false } }
        #expect(wins.count == 1)
    }
}
