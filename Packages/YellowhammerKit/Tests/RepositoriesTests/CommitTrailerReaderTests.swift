import Foundation
import Repositories
import Testing

@Suite("Commit trailer reader")
struct CommitTrailerReaderTests {
    @Test("base..commit returns only the commit that lacks the trailer")
    func rangeReturnsOnlyTheTrailerLess() async throws {
        let fixture = GitFixture(name: "trailer-range")
        await fixture.initRepo()
        let base = try await fixture.commit(filename: "a.txt", message: "initial")
        let tagged = try await fixture.commit(
            filename: "b.txt", message: "feat: tagged\n\nYellowhammer-Work-Card: YLH-7"
        )
        let bare = try await fixture.commit(filename: "c.txt", message: "feat: bare")

        let result = await CommitTrailerReader().commitsMissingWorkCardTrailer(
            worktreePath: fixture.path, from: base, to: bare
        )

        #expect(result == .success([bare]))
        #expect(tagged != bare)
    }

    @Test("a nil base reads only the reported commit")
    func nilBaseReadsOneCommit() async throws {
        let fixture = GitFixture(name: "trailer-nil-base")
        await fixture.initRepo()
        _ = try await fixture.commit(filename: "a.txt", message: "initial")
        let head = try await fixture.commit(filename: "b.txt", message: "feat: bare")

        let result = await CommitTrailerReader().commitsMissingWorkCardTrailer(
            worktreePath: fixture.path, from: nil, to: head
        )

        #expect(result == .success([head]))
    }

    @Test("base equal to the commit returns nothing")
    func emptyRange() async throws {
        let fixture = GitFixture(name: "trailer-empty")
        await fixture.initRepo()
        let head = try await fixture.commit(filename: "a.txt", message: "initial")

        let result = await CommitTrailerReader().commitsMissingWorkCardTrailer(
            worktreePath: fixture.path, from: head, to: head
        )

        #expect(result == .success([]))
    }

    @Test("an unknown commit is a failure carrying git's stderr")
    func unknownCommitFails() async throws {
        let fixture = GitFixture(name: "trailer-unknown")
        await fixture.initRepo()
        let base = try await fixture.commit(filename: "a.txt", message: "initial")

        let result = await CommitTrailerReader().commitsMissingWorkCardTrailer(
            worktreePath: fixture.path, from: base, to: String(repeating: "0", count: 40)
        )

        guard case .failure(let failure) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(!failure.reason.isEmpty)
    }

    @Test("a reported commit shaped like an option is read as a revision, never as an option")
    func optionShapedCommitIsNotAnOption() async throws {
        let fixture = GitFixture(name: "trailer-option")
        await fixture.initRepo()
        _ = try await fixture.commit(filename: "a.txt", message: "initial")
        let written = (fixture.path as NSString).appendingPathComponent("written-by-git.txt")

        let result = await CommitTrailerReader().commitsMissingWorkCardTrailer(
            worktreePath: fixture.path, from: nil, to: "--output=\(written)"
        )

        guard case .failure = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: written))
    }
}
