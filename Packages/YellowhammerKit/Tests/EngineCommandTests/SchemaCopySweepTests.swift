@testable import EngineCommand
import Domain
import Foundation
import Testing

@Suite("SchemaCopySweep")
struct SchemaCopySweepTests {
    private func makeRuns() throws -> URL {
        let name = "yh-schema-sweep-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, in runs: URL, run: String, age: TimeInterval, now: Date) throws -> URL {
        let directory = runs.appendingPathComponent(run)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data("{}".utf8).write(to: file)
        let modified = now.addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        return file
    }

    @Test("Only schema.json files 30 or more days old are swept")
    func oldVersusFresh() throws {
        let runs = try makeRuns()
        defer { try? FileManager.default.removeItem(at: runs) }
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        let old = try write("schema.json", in: runs, run: "old", age: 31 * day, now: now)
        let boundary = try write("schema.json", in: runs, run: "boundary", age: 30 * day, now: now)
        let fresh = try write("schema.json", in: runs, run: "fresh", age: 29 * day, now: now)
        let other = try write("result.json", in: runs, run: "other", age: 40 * day, now: now)

        let failures = SchemaCopySweep.removeExpired(under: runs, now: now)

        #expect(failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: boundary.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("A missing directory is not a failure, and remove(under:) ignores age")
    func missingDirectoryAndUnconditionalRemoval() throws {
        let runs = try makeRuns()
        defer { try? FileManager.default.removeItem(at: runs) }
        #expect(SchemaCopySweep.remove(under: runs.appendingPathComponent("nope")).isEmpty)

        let fresh = try write("schema.json", in: runs, run: "fresh", age: 0, now: Date())
        #expect(SchemaCopySweep.remove(under: runs).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
    }
}
