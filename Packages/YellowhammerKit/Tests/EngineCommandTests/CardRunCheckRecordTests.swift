import Domain
@testable import Engine
import Foundation
import GRDB
import Journal
import Repositories
import Testing

// OQ198 item 3 (Lane-less Repository Checkout Ruling 2026-11-02), the wiring: each Check record names the
// other touched repositories' held Worktree HEADs before and after the Check, and the configured lockfile's
// identity at the judged commit. The Check is a fake's here; nothing asserts its output or a verdict.

/// A Check that moves a sibling Worktree's HEAD while it runs, so the record's `after` differs from `before`.
private struct SiblingMovingCheck: RepositoryCheckRunning {
    let siblingPath: String

    func run(repository: String, check: Check, worktreePath: String) async throws -> RepositoryCheckResult {
        _ = await commit(in: siblingPath, message: "moved during the Check")
        return .passed(output: "ok")
    }
}

private func commit(in path: String, message: String) async -> String {
    let git = GitRunner()
    _ = await git.run(
        ["-C", path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
         "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", message]
    )
    let head = await git.run(["-C", path, "rev-parse", "HEAD"])
    return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func commitFile(_ name: String, in path: String) async throws -> String {
    try "locked\n".write(toFile: path + "/" + name, atomically: true, encoding: .utf8)
    let git = GitRunner()
    _ = await git.run(["-C", path, "add", name])
    return await commit(in: path, message: "add \(name)")
}

private func checkRecords(_ world: CardRunWorld) throws -> [CheckRanPayload] {
    try world.journal.events(ofType: .checkRan).compactMap { record in
        if case .checkRan(let payload) = record.event { payload } else { nil }
    }
}

@Suite("Card run, Check records name sibling Worktrees and the lockfile")
struct CardRunCheckRecordTests {
    private func run(
        _ world: CardRunWorld,
        check: any RepositoryCheckRunning = RecordingCheck(log: CallLog(), results: [.passed(output: "ok")]),
        checks: [String: Check] = ["backend": .command("make test")]
    ) async throws {
        let card = CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: CallLog()), check: check, checks: checks,
            reviewRoundsMax: 1, attemptsPerWorkCard: 1, passTimeoutMinutes: 60,
            resetting: RecordingAttemptResetting()
        )
        try await card.run("BACK-1", in: world)
    }

    private func touch(_ world: CardRunWorld, _ repositories: [String]) throws {
        let featureID = world.context.feature.id
        try world.journal.write { db in
            for repository in repositories {
                try db.execute(
                    sql: "INSERT INTO feature_repository (feature_id, repository) VALUES (?, ?)",
                    arguments: [featureID, repository]
                )
            }
        }
    }

    private func path(_ world: CardRunWorld, _ repository: String) throws -> String {
        try #require(try world.journal.heldWorktree(featureID: world.context.feature.id, repository: repository)).path
    }

    @Test("A held sibling Worktree's HEAD is recorded before and after the Check")
    func siblingHeadIsRecordedBeforeAndAfter() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(
            journal: try fixture.open(), cards: [("BACK-1", "backend"), ("WEB-1", "web")]
        )
        try touch(world, ["backend", "web"])
        _ = await commit(in: try path(world, "backend"), message: "base")
        let webPath = try path(world, "web")
        let webHead = await commit(in: webPath, message: "base")

        try await run(world)

        let siblings = try #require(try checkRecords(world).first).siblings
        #expect(siblings == [CheckSiblingState(repository: "web", before: .commit(webHead), after: .commit(webHead))])
    }

    @Test("A sibling whose HEAD moves during the Check records the different HEADs")
    func siblingHeadMovedDuringTheCheck() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(
            journal: try fixture.open(), cards: [("BACK-1", "backend"), ("WEB-1", "web")]
        )
        try touch(world, ["backend", "web"])
        _ = await commit(in: try path(world, "backend"), message: "base")
        let webPath = try path(world, "web")
        let before = await commit(in: webPath, message: "base")

        try await run(world, check: SiblingMovingCheck(siblingPath: webPath))

        let sibling = try #require(try checkRecords(world).first?.siblings.first)
        #expect(sibling.before == .commit(before))
        guard case .commit(let after) = sibling.after else {
            Issue.record("expected a commit, got \(sibling.after)")
            return
        }
        #expect(after != before)
    }

    @Test("A sibling with no held Worktree records noHeldWorktree both times")
    func siblingWithoutHeldWorktree() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(
            journal: try fixture.open(), cards: [("BACK-1", "backend"), ("WEB-1", "web")]
        )
        try touch(world, ["backend", "web", "docs"])
        _ = await commit(in: try path(world, "backend"), message: "base")
        let featureID = world.context.feature.id
        let released = try #require(try world.journal.heldWorktree(featureID: featureID, repository: "web"))
        _ = try world.journal.releaseWorktree(id: released.id, runID: world.runID, discardingUnpushedWork: true)

        try await run(world)

        let siblings = try #require(try checkRecords(world).first).siblings
        #expect(siblings == [
            CheckSiblingState(repository: "docs", before: .noHeldWorktree, after: .noHeldWorktree),
            CheckSiblingState(repository: "web", before: .noHeldWorktree, after: .noHeldWorktree)
        ])
    }

    @Test("A single-repository Feature records no siblings and no lockfile")
    func singleRepositoryFeature() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        try touch(world, ["backend"])

        try await run(world)

        let record = try #require(try checkRecords(world).first)
        #expect(record.siblings.isEmpty)
        #expect(record.lockfile == .unknown)
    }

    @Test("The configured lockfile is identified at the judged commit, absent, or unknown")
    func lockfileIdentity() async throws {
        let configured = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/unused", role: .backend, lockfile: "Package.resolved")
        ])

        // Present at the commit: the blob git itself names.
        let present = try OutboxJournalFixture()
        let presentWorld = try await makeCardRunWorld(journal: try present.open(), repositories: configured)
        let backendPath = try path(presentWorld, "backend")
        let commitID = try await commitFile("Package.resolved", in: backendPath)
        try await run(presentWorld)
        let expected = await GitRunner().run(["-C", backendPath, "rev-parse", "\(commitID):Package.resolved"])
        let objectID = expected.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try checkRecords(presentWorld).first?.lockfile == .blob(path: "Package.resolved", objectID: objectID))

        // Configured but missing at the commit.
        let absent = try OutboxJournalFixture()
        let absentWorld = try await makeCardRunWorld(journal: try absent.open(), repositories: configured)
        _ = await commit(in: try path(absentWorld, "backend"), message: "base")
        try await run(absentWorld)
        #expect(try checkRecords(absentWorld).first?.lockfile == .absent(path: "Package.resolved"))

        // A path naming a directory is not a lockfile.
        let directory = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/unused", role: .backend, lockfile: "locks")
        ])
        let directoryFixture = try OutboxJournalFixture()
        let directoryWorld = try await makeCardRunWorld(journal: try directoryFixture.open(), repositories: directory)
        let directoryPath = try path(directoryWorld, "backend")
        try FileManager.default.createDirectory(atPath: directoryPath + "/locks", withIntermediateDirectories: true)
        _ = try await commitFile("locks/a.lock", in: directoryPath)
        try await run(directoryWorld)
        #expect(try checkRecords(directoryWorld).first?.lockfile == .absent(path: "locks"))

        // None configured.
        let none = try OutboxJournalFixture()
        let noneWorld = try await makeCardRunWorld(journal: try none.open())
        try await run(noneWorld)
        #expect(try checkRecords(noneWorld).first?.lockfile == .unknown)
    }

    @Test("The Check still runs and records for a pass, a fail and a declared none")
    func checkStillRecordsEveryResult() async throws {
        struct Case {
            let answer: RepositoryCheckResult
            let kind: CheckRunResult
            let check: Check
        }
        let answers = [
            Case(answer: .passed(output: "ok"), kind: .passed, check: .command("make test")),
            Case(answer: .failed(output: "red", exitStatus: 2), kind: .failed, check: .command("make test")),
            Case(answer: .declaredNone, kind: .declaredNone, check: .none)
        ]
        for item in answers {
            let fixture = try OutboxJournalFixture()
            let world = try await makeCardRunWorld(
                journal: try fixture.open(), cards: [("BACK-1", "backend"), ("WEB-1", "web")]
            )
            try touch(world, ["backend", "web"])
            try await run(
                world, check: RecordingCheck(log: CallLog(), results: [item.answer]), checks: ["backend": item.check]
            )
            let record = try #require(try checkRecords(world).first)
            #expect(record.result == item.kind)
            #expect(record.siblings.map(\.repository) == ["web"])
        }
    }
}
