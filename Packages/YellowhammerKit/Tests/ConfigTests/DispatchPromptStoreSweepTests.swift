import Config
import Darwin
import Domain
import Foundation
import Testing

@Suite("DispatchPromptStore sweep tests")
struct DispatchPromptStoreSweepTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(components: "yh-prompt-store-sweep-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func makeRecord(
        id: String,
        projectID: String?,
        dispatchedAt: Date
    ) -> DispatchPromptRecord {
        let roundedDate = Date(timeIntervalSince1970: floor(dispatchedAt.timeIntervalSince1970))
        let provenance = DispatchProvenance(
            recordID: id,
            family: .worker,
            projectID: projectID
        )
        return DispatchPromptRecord(
            provenance: provenance,
            route: "claude-code/sonnet/high",
            pass: .worker,
            dispatchedAt: roundedDate,
            defaultVersion: 1,
            projectInstructions: .absent,
            session: .new,
            instruction: "test instruction",
            outputSchema: nil,
            launch: .pending
        )
    }

    @Test("A sweep removes expired records and keeps fresh ones")
    func sweepRemovesExpiredAndKeepsFresh() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let baseInstant = Date(timeIntervalSince1970: 1_700_000_000)
        let store = DispatchPromptStore(rootDirectory: root, now: { baseInstant })

        let projectID = try #require(ProjectID(rawValue: "alpha"))
        let scope = DispatchPromptScope.project(projectID)

        let rec1 = makeRecord(
            id: "rec-old-1",
            projectID: "alpha",
            dispatchedAt: baseInstant.addingTimeInterval(-31 * 86_400)
        )
        let rec2 = makeRecord(
            id: "rec-fresh-1",
            projectID: "alpha",
            dispatchedAt: baseInstant.addingTimeInterval(-5 * 86_400)
        )
        let rec3 = makeRecord(
            id: "rec-old-2",
            projectID: "alpha",
            dispatchedAt: baseInstant.addingTimeInterval(-40 * 86_400)
        )
        let rec4 = makeRecord(
            id: "rec-fresh-2",
            projectID: "alpha",
            dispatchedAt: baseInstant.addingTimeInterval(-3_600)
        )

        _ = store.capture(rec1)
        _ = store.capture(rec2)
        _ = store.capture(rec3)
        _ = store.capture(rec4)

        let failures = store.sweepExpired(in: scope)
        #expect(failures.isEmpty)

        #expect(store.lookup(id: "rec-old-1", scope: scope) == .missing)
        #expect(store.lookup(id: "rec-old-2", scope: scope) == .missing)
        #expect(store.lookup(id: "rec-fresh-1", scope: scope) == .available(rec2))
        #expect(store.lookup(id: "rec-fresh-2", scope: scope) == .available(rec4))
    }
}
