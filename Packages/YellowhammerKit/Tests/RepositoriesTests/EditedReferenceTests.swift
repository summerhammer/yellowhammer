import Domain
import Foundation
@testable import Repositories
import Testing

// An Operator-edited Transcription Block reference is read from local mainline at the commit it names
// (spec: feature-authoring/author-an-architectural-brief#edited-reference). Fixture repositories only.

@Suite("Reading an edited reference")
struct EditedReferenceTests {
    private static let v1 = (1...6).map { "old \($0)" }.joined(separator: "\n") + "\n"
    private static let v2 = (1...6).map { "new \($0)" }.joined(separator: "\n") + "\n"

    private final class Setup {
        let reader = MainlineReader()
        /// Held so the fixture repository outlives the test body: it is deleted when the fixture goes.
        let fixture: GitFixture
        let repos: ProjectRepositories
        let first: String
        let second: String

        init(fixture: consuming GitFixture, repos: ProjectRepositories, first: String, second: String) {
            self.fixture = fixture
            self.repos = repos
            self.first = first
            self.second = second
        }
    }

    /// `api.txt` is `v1` at `first` and `v2` at `second` (the mainline head); `docs/` holds a file.
    private func setup(_ name: String) async throws -> Setup {
        let fixture = GitFixture(name: name)
        await fixture.initRepo(defaultBranch: "main")
        let first = try await fixture.commit(filename: "api.txt", content: Self.v1, message: "v1")
        _ = try await fixture.commit(filename: "docs/readme.md", content: "docs", message: "docs")
        let second = try await fixture.commit(filename: "api.txt", content: Self.v2, message: "v2")
        let repo = Repo(name: "api", path: fixture.path, role: .backend)
        return Setup(fixture: fixture, repos: ProjectRepositories(workingRepos: [repo]), first: first, second: second)
    }

    private func read(
        _ setup: Setup, repository: String = "api", paths: [String] = ["api.txt"],
        ranges: [String: [LineRange]] = [:], symbol: String? = nil, commit: String?
    ) async throws -> TranscriptionBlock {
        try await setup.reader.readEditedReference(
            repository: repository, paths: paths, ranges: ranges, symbol: symbol, commit: commit,
            in: setup.repos, mainlines: nil
        )
    }

    @Test("A reference at an older mainline commit returns that commit's lines")
    func olderMainlineCommit() async throws {
        let setup = try await setup("edited-older-1")
        let block = try await read(
            setup, ranges: ["api.txt": [LineRange(start: 2, end: 3)]], symbol: "Api", commit: setup.first
        )
        #expect(block.content == "old 2\nold 3")
        #expect(block.mainlineCommit == setup.first)
        #expect(block.ranges == ["api.txt": [LineRange(start: 2, end: 3)]])
        #expect(block.symbol == "Api")
        #expect(block.contentHash == MainlineReader.sha256("old 2\nold 3"))
    }

    @Test("The mainline head itself is on mainline, and an abbreviated commit resolves to the full sha")
    func headAndAbbreviation() async throws {
        let setup = try await setup("edited-head-2")
        let head = try await read(setup, commit: setup.second)
        #expect(head.content == Self.v2)
        let short = try await read(setup, commit: String(setup.first.prefix(9)))
        #expect(short.mainlineCommit == setup.first)
        let padded = try await read(setup, commit: "  \(setup.first)  ")
        #expect(padded.mainlineCommit == setup.first)
    }

    @Test("A reference naming no commit is refused")
    func noCommit() async throws {
        let setup = try await setup("edited-nocommit-3")
        for commit in [nil, "", "  "] as [String?] {
            await #expect(throws: EditedReferenceError.noCommit) { try await read(setup, commit: commit) }
        }
    }

    @Test("A commit that does not resolve is refused")
    func unresolvableCommit() async throws {
        let setup = try await setup("edited-unresolvable-4")
        let bogus = String(repeating: "0", count: 40)
        await #expect(throws: MainlineReadError.unresolvableCommit(repository: "api", commit: bogus)) {
            try await read(setup, commit: bogus)
        }
    }

    @Test("A commit on a side branch that mainline does not contain is refused")
    func sideBranchCommit() async throws {
        let setup = try await setup("edited-side-5")
        await setup.fixture.run(["checkout", "-b", "side", setup.first])
        let side = try await setup.fixture.commit(filename: "side.txt", content: "side", message: "side")
        await setup.fixture.run(["checkout", "main"])
        await #expect(
            throws: EditedReferenceError.notOnMainline(repository: "api", commit: side, mainlineCommit: setup.second)
        ) {
            try await read(setup, paths: ["side.txt"], commit: side)
        }
    }

    @Test("A range out of bounds, reversed or before line 1 is refused")
    func badRanges() async throws {
        let setup = try await setup("edited-ranges-6")
        let outOfBounds = LineRange(start: 5, end: 9)
        await #expect(
            throws: TranscriptionRangeError.outOfBounds(
                repository: "api", path: "api.txt", range: outOfBounds, lineCount: 6, commit: setup.second
            )
        ) {
            try await read(setup, ranges: ["api.txt": [outOfBounds]], commit: setup.second)
        }
        let reversed = LineRange(start: 4, end: 2)
        await #expect(
            throws: TranscriptionRangeError.reversed(repository: "api", path: "api.txt", range: reversed)
        ) {
            try await read(setup, ranges: ["api.txt": [reversed]], commit: setup.second)
        }
        let zero = LineRange(start: 0, end: 2)
        await #expect(
            throws: TranscriptionRangeError.startsBeforeFirstLine(repository: "api", path: "api.txt", range: zero)
        ) {
            try await read(setup, ranges: ["api.txt": [zero]], commit: setup.second)
        }
    }

    @Test("A path that is a directory, or is absent at the commit, is refused")
    func notAFile() async throws {
        let setup = try await setup("edited-directory-7")
        await #expect(
            throws: MainlineReadError.notAFile(path: "docs", commit: setup.second, repository: "api")
        ) {
            try await read(setup, paths: ["docs"], commit: setup.second)
        }
        await #expect(
            throws: MainlineReadError.fileNotFound(path: "docs/readme.md", commit: setup.first, repository: "api")
        ) {
            try await read(setup, paths: ["docs/readme.md"], commit: setup.first)
        }
    }

    @Test("A repository that is not one of the Project's is refused")
    func unconfiguredRepository() async throws {
        let setup = try await setup("edited-unconfigured-8")
        await #expect(throws: MainlineReadError.unconfiguredRepository("elsewhere")) {
            try await read(setup, repository: "elsewhere", commit: setup.first)
        }
    }

    @Test("A pinned mainline decides what is on mainline")
    func pinnedMainline() async throws {
        let setup = try await setup("edited-pinned-9")
        let pinned = ResolvedMainline(
            repository: "api", defaultBranch: "main", ref: "refs/heads/main", commit: setup.first
        )
        let mainlines = ResolvedMainlines(workingRepos: ["api": pinned])
        await #expect(
            throws: EditedReferenceError.notOnMainline(
                repository: "api", commit: setup.second, mainlineCommit: setup.first
            )
        ) {
            try await setup.reader.readEditedReference(
                repository: "api", paths: ["api.txt"], ranges: [:], symbol: nil, commit: setup.second,
                in: setup.repos, mainlines: mainlines
            )
        }
    }

    @Test("A reference into the Spec Source is read the same way")
    func specSource() async throws {
        let fixture = GitFixture(name: "edited-spec-10")
        await fixture.initRepo(defaultBranch: "main")
        let first = try await fixture.commit(filename: "spec.md", content: "spec one\n", message: "one")
        _ = try await fixture.commit(filename: "spec.md", content: "spec two\n", message: "two")
        let repos = ProjectRepositories(workingRepos: [], specSource: SpecSource(path: fixture.path))
        let block = try await MainlineReader().readEditedReference(
            repository: "spec_source", paths: ["spec.md"], ranges: [:], symbol: nil, commit: first,
            in: repos, mainlines: nil
        )
        #expect(block.content == "spec one\n")
        #expect(block.mainlineCommit == first)
    }

    @Test("Each error describes its problem in words")
    func descriptions() {
        #expect(EditedReferenceError.noCommit.description == "it names no commit")
        #expect(
            EditedReferenceError.notOnMainline(
                repository: "api", commit: "abc1234ffff", mainlineCommit: "def5678aaaa"
            ).description == "commit abc1234 is not on api's mainline (mainline at def5678)"
        )
    }
}
