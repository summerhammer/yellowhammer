import Domain
import Foundation
@testable import Repositories
import Testing

// A contract may name line ranges per path: only those lines are transcribed, unioned, and a range the
// file at the resolved commit does not have is refused — never clamped. Fixture repositories only.

@Suite("Line counting")
struct TranscriptionLineCountTests {
    @Test("A final newline ends the last line rather than starting another")
    func counts() {
        #expect(MainlineReader.lines(of: "").isEmpty)
        #expect(MainlineReader.lines(of: "\n") == [""])
        #expect(MainlineReader.lines(of: "a\nb\n") == ["a", "b"])
        #expect(MainlineReader.lines(of: "a\nb") == ["a", "b"])
        #expect(MainlineReader.lines(of: "a\n\n") == ["a", ""])
    }

    @Test("Lines are kept verbatim, a trailing carriage return included")
    func verbatim() {
        #expect(MainlineReader.lines(of: "a\r\nb\r\n") == ["a\r", "b\r"])
    }
}

@Suite("Transcribing line ranges")
struct TranscriptionRangeTests {
    private static let twelve = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"

    private final class Setup {
        let reader = MainlineReader()
        /// Held so the fixture repository outlives the test body: it is deleted when the fixture goes.
        let fixture: GitFixture
        let repos: ProjectRepositories
        let commit: String

        init(fixture: consuming GitFixture, repos: ProjectRepositories, commit: String) {
            self.fixture = fixture
            self.repos = repos
            self.commit = commit
        }
    }

    private func setup(
        _ name: String, files: [(String, String)] = [("api.txt", TranscriptionRangeTests.twelve)]
    ) async throws -> Setup {
        let fixture = GitFixture(name: name)
        await fixture.initRepo(defaultBranch: "main")
        var sha = ""
        for (filename, content) in files {
            sha = try await fixture.commit(filename: filename, content: content)
        }
        let repo = Repo(name: "api", path: fixture.path, role: .backend)
        return Setup(fixture: fixture, repos: ProjectRepositories(workingRepos: [repo]), commit: sha)
    }

    private func transcribe(
        _ setup: Setup, paths: [String] = ["api.txt"], ranges: [String: [LineRange]]
    ) async throws -> TranscriptionBlock {
        try await setup.reader.transcribe(
            paths: paths, ranges: ranges, repository: "api", in: setup.repos, symbol: "Api"
        )
    }

    private func expectRangeError(
        _ setup: Setup, paths: [String] = ["api.txt"], ranges: [String: [LineRange]],
        _ expected: (String) -> TranscriptionRangeError
    ) async throws {
        do {
            let block = try await transcribe(setup, paths: paths, ranges: ranges)
            Issue.record("expected a range error, transcribed \(block.content)")
        } catch let error as TranscriptionRangeError {
            #expect(error == expected(setup.commit))
        }
    }

    @Test("One range transcribes exactly those lines")
    func oneRange() async throws {
        let setup = try await setup("range-one-1")
        let block = try await transcribe(setup, ranges: ["api.txt": [LineRange(start: 3, end: 5)]])
        #expect(block.content == "line 3\nline 4\nline 5")
        #expect(block.ranges == ["api.txt": [LineRange(start: 3, end: 5)]])
        #expect(block.contentHash == MainlineReader.sha256("line 3\nline 4\nline 5"))
        #expect(block.mainlineCommit == setup.commit)
        #expect(block.symbol == "Api")
    }

    @Test("A range may run to the very first and the very last line")
    func wholeFileAsRange() async throws {
        let setup = try await setup("range-bounds-2")
        let block = try await transcribe(setup, ranges: ["api.txt": [LineRange(start: 1, end: 12)]])
        #expect(block.content == String(Self.twelve.dropLast()))
        let single = try await transcribe(setup, ranges: ["api.txt": [LineRange(start: 12, end: 12)]])
        #expect(single.content == "line 12")
    }

    @Test("Several ranges on one path join in file order with a newline")
    func severalRanges() async throws {
        let setup = try await setup("range-several-3")
        let block = try await transcribe(
            setup, ranges: ["api.txt": [LineRange(start: 9, end: 10), LineRange(start: 2, end: 3)]]
        )
        #expect(block.content == "line 2\nline 3\nline 9\nline 10")
        #expect(block.ranges == ["api.txt": [LineRange(start: 2, end: 3), LineRange(start: 9, end: 10)]])
    }

    @Test("Overlapping and duplicate ranges transcribe their union once, and the block shows the union")
    func overlappingAndDuplicate() async throws {
        let setup = try await setup("range-union-4")
        let block = try await transcribe(setup, ranges: ["api.txt": [
            LineRange(start: 4, end: 7), LineRange(start: 2, end: 5), LineRange(start: 4, end: 7)
        ]])
        #expect(block.content == "line 2\nline 3\nline 4\nline 5\nline 6\nline 7")
        #expect(block.ranges == ["api.txt": [LineRange(start: 2, end: 7)]])
    }

    @Test("Adjacent ranges merge into one run")
    func adjacentRanges() async throws {
        let setup = try await setup("range-adjacent-5")
        let block = try await transcribe(
            setup, ranges: ["api.txt": [LineRange(start: 1, end: 2), LineRange(start: 3, end: 4)]]
        )
        #expect(block.content == "line 1\nline 2\nline 3\nline 4")
        #expect(block.ranges == ["api.txt": [LineRange(start: 1, end: 4)]])
    }

    @Test("A path with no range is transcribed whole and hashes exactly as before ranges existed")
    func unrangedUnchanged() async throws {
        let setup = try await setup("range-none-6")
        let plain = try await setup.reader.transcribe(path: "api.txt", repository: "api", in: setup.repos)
        let withEmpty = try await transcribe(setup, ranges: [:])
        let withEmptyList = try await transcribe(setup, ranges: ["api.txt": []])
        #expect(plain.content == Self.twelve)
        #expect(plain.contentHash == MainlineReader.sha256(Self.twelve))
        #expect(plain.ranges.isEmpty)
        #expect(withEmpty.content == plain.content)
        #expect(withEmpty.contentHash == plain.contentHash)
        #expect(withEmptyList.contentHash == plain.contentHash)
        #expect(withEmptyList.ranges.isEmpty)
    }

    @Test("Ranged and whole paths combine with a newline, and only ranged ones appear in ranges")
    func mixedPaths() async throws {
        let setup = try await setup("range-mixed-7", files: [("a.txt", "a1\na2\na3\n"), ("b.txt", "b1\nb2\n")])
        let block = try await transcribe(
            setup, paths: ["a.txt", "b.txt"], ranges: ["a.txt": [LineRange(start: 2, end: 3)]]
        )
        #expect(block.content == "a2\na3\nb1\nb2\n")
        #expect(block.ranges == ["a.txt": [LineRange(start: 2, end: 3)]])
        #expect(block.contentHash == MainlineReader.sha256("a2\na3\nb1\nb2\n"))
    }

    @Test("A file without a final newline counts the same lines")
    func noFinalNewline() async throws {
        let setup = try await setup("range-nonl-8", files: [("api.txt", "x\ny\nz")])
        let block = try await transcribe(setup, ranges: ["api.txt": [LineRange(start: 2, end: 3)]])
        #expect(block.content == "y\nz")
        try await expectRangeError(setup, ranges: ["api.txt": [LineRange(start: 3, end: 4)]]) {
            .outOfBounds(
                repository: "api", path: "api.txt", range: LineRange(start: 3, end: 4), lineCount: 3, commit: $0
            )
        }
    }

    @Test("A range ending past the last line is refused, never clamped")
    func endPastLastLine() async throws {
        let setup = try await setup("range-past-end-9")
        try await expectRangeError(setup, ranges: ["api.txt": [LineRange(start: 10, end: 13)]]) {
            .outOfBounds(
                repository: "api", path: "api.txt", range: LineRange(start: 10, end: 13), lineCount: 12,
                commit: $0
            )
        }
    }

    @Test("A range starting past the last line is refused")
    func startPastLastLine() async throws {
        let setup = try await setup("range-past-start-10")
        try await expectRangeError(setup, ranges: ["api.txt": [LineRange(start: 13, end: 14)]]) {
            .outOfBounds(
                repository: "api", path: "api.txt", range: LineRange(start: 13, end: 14), lineCount: 12,
                commit: $0
            )
        }
    }

    @Test("A reversed range and a range starting at line 0 are refused")
    func reversedAndZero() async throws {
        let setup = try await setup("range-reversed-11")
        try await expectRangeError(setup, ranges: ["api.txt": [LineRange(start: 5, end: 3)]]) { _ in
            .reversed(repository: "api", path: "api.txt", range: LineRange(start: 5, end: 3))
        }
        try await expectRangeError(setup, ranges: ["api.txt": [LineRange(start: 0, end: 3)]]) { _ in
            .startsBeforeFirstLine(repository: "api", path: "api.txt", range: LineRange(start: 0, end: 3))
        }
    }

    @Test("Any range on an empty file is refused")
    func emptyFile() async throws {
        let setup = try await setup("range-empty-12", files: [("api.txt", "")])
        try await expectRangeError(setup, ranges: ["api.txt": [LineRange(start: 1, end: 1)]]) {
            .emptyFile(repository: "api", path: "api.txt", commit: $0)
        }
    }

    @Test("One bad range refuses the whole path, even when another range fits")
    func oneBadRangeRefusesAll() async throws {
        let setup = try await setup("range-one-bad-13")
        try await expectRangeError(
            setup, ranges: ["api.txt": [LineRange(start: 1, end: 2), LineRange(start: 11, end: 20)]]
        ) {
            .outOfBounds(
                repository: "api", path: "api.txt", range: LineRange(start: 11, end: 20), lineCount: 12,
                commit: $0
            )
        }
    }

    @Test("A bad range on a later path refuses the contract")
    func badRangeOnLaterPath() async throws {
        let setup = try await setup("range-later-14", files: [("a.txt", "a1\n"), ("b.txt", "b1\n")])
        try await expectRangeError(
            setup, paths: ["a.txt", "b.txt"], ranges: ["b.txt": [LineRange(start: 1, end: 2)]]
        ) {
            .outOfBounds(
                repository: "api", path: "b.txt", range: LineRange(start: 1, end: 2), lineCount: 1, commit: $0
            )
        }
    }

    @Test("A missing path with a range still throws the file-not-found error: the path is checked first")
    func missingPathFirst() async throws {
        let setup = try await setup("range-missing-15")
        do {
            _ = try await transcribe(
                setup, paths: ["gone.txt"], ranges: ["gone.txt": [LineRange(start: 0, end: 0)]]
            )
            Issue.record("expected the missing path to be refused")
        } catch let error as MainlineReadError {
            #expect(error == .fileNotFound(path: "gone.txt", commit: setup.commit, repository: "api"))
        }
    }

    @Test("The error names the path, the range and the file's actual line count")
    func descriptions() {
        let range = LineRange(start: 900, end: 950)
        let outOfBounds = TranscriptionRangeError.outOfBounds(
            repository: "api", path: "openapi.yaml", range: range, lineCount: 812, commit: "abc1234def"
        ).description
        #expect(outOfBounds == "openapi.yaml lines 900–950 is out of bounds at abc1234: the file has 812 lines in api")
        #expect(TranscriptionRangeError.reversed(repository: "api", path: "openapi.yaml", range: range)
            .description.contains("openapi.yaml lines 900–950 is reversed"))
        #expect(TranscriptionRangeError.startsBeforeFirstLine(
            repository: "api", path: "openapi.yaml", range: LineRange(start: 0, end: 5)
        ).description.contains("starts at line 0"))
        #expect(TranscriptionRangeError.emptyFile(repository: "api", path: "openapi.yaml", commit: "abc1234def")
            .description == "openapi.yaml is empty at abc1234 in api, so it has no line range")
    }
}
