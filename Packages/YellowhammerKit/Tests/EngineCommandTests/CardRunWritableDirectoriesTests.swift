import Domain
@testable import Engine
import Foundation
import Repositories
import Testing

@Suite("Card run, worker git write access")
struct CardRunWritableDirectoriesTests {
    private func makeRun(dispatch: any AgentDispatch, git: GitRunner = GitRunner()) -> CardRun {
        let route = cardRunFallback
        let resolver = cardRunResolver(table: RoutingTable(entries: [RoutingEntry(kind: Kind("card")!, route: route)]))
        return CardRun(
            resolver: resolver, dispatch: dispatch,
            check: RecordingCheck(log: CallLog(), results: [.failed(output: "retry", exitStatus: 1), .declaredNone]),
            checks: ["backend": .none], reviewRoundsMax: 3, attemptsPerWorkCard: 1, passTimeoutMinutes: 60,
            resetting: RecordingAttemptResetting(), git: git
        )
    }

    @Test("Every worker Round gets exact git directories; architect and reviewer get none", arguments: [false, true])
    func workerRequestsCarryGitDirectories(linked: Bool) async throws {
        let fixture = try OutboxJournalFixture()
        let git = GitRunner()
        let repository = fixture.directory.appendingPathComponent("main checkout")
        try await initReconcilerGitRepo(at: repository, git: git)
        let worktree: URL
        if linked {
            worktree = fixture.directory.appendingPathComponent("linked checkout")
            let added = await git.run(
                ["worktree", "add", "-b", "worker", worktree.path], workingDirectory: repository.path
            )
            #expect(added.isSuccess)
        } else {
            worktree = repository
        }
        let topLevel = await git.run(["rev-parse", "--show-toplevel"], workingDirectory: repository.path)
        #expect(topLevel.isSuccess)
        let commonDirectory = topLevel.stdout.trimmingCharacters(in: .newlines) + "/.git"
        var expected = [commonDirectory]
        if linked {
            let pointer = try String(contentsOf: worktree.appendingPathComponent(".git"), encoding: .utf8)
            expected.insert(String(pointer.dropFirst("gitdir: ".count)).trimmingCharacters(in: .newlines), at: 0)
        }
        let world = try await makeCardRunWorld(journal: try fixture.open(), worktreePath: { _ in worktree.path })
        let dispatch = SequencedDispatch(sequences: [
            .worker: [.workerCompleted], .reviewer: [.reviewerChangesRequested, .reviewerApproved]
        ])

        try await makeRun(dispatch: dispatch).run("BACK-1", in: world)

        let workers = dispatch.requests.passes(.worker)
        #expect(workers.count == 3)
        for worker in workers {
            #expect(worker.additionalWritableDirectories == expected)
        }
        #expect(workers.first?.resumeSession == nil)
        #expect(workers.dropFirst().allSatisfy { $0.resumeSession != nil })
        let otherPasses = dispatch.requests.all.filter { $0.pass != .worker }
        #expect(otherPasses.map(\.pass) == [.architect, .reviewer, .reviewer])
        #expect(otherPasses.allSatisfy { $0.additionalWritableDirectories.isEmpty })
    }

    @Test("Nonworker passes do not discover git directories")
    func nonworkerPassesSkipDiscovery() async throws {
        let run = makeRun(dispatch: RehearsalDispatch(), git: GitRunner(executablePath: "/usr/bin/false"))
        for pass in [RunPass.architect, .reviewer] {
            #expect(try await run.workerWritableDirectories(for: pass, path: "/missing/worktree").isEmpty)
        }
    }

    @Test("Git discovery failure throws an engine fault before dispatching the worker")
    func discoveryFailureStopsWorker() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let dispatch = LoggingDispatch(log: CallLog())
        let run = makeRun(dispatch: dispatch, git: GitRunner(executablePath: "/usr/bin/false"))

        do {
            try await run.run("BACK-1", in: world)
            Issue.record("expected git discovery to fail")
        } catch let error as CardRunError {
            guard case .gitDirectoryDiscoveryFailed(let path, let detail) = error else { throw error }
            #expect(path == world.worktrees?.directory.appendingPathComponent("backend").path)
            #expect(detail.contains("git rev-parse --git-dir failed"))
        }
        #expect(dispatch.requests.all.map(\.pass) == [.architect])
        #expect(try world.attempts("BACK-1").count == 1)
        #expect(try world.journal.attemptHistory(cardID: #require(world.cardIDs["BACK-1"])).openAttempt != nil)
    }
}
