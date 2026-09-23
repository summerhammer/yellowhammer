import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Synchronization
import Testing

private final class ResultBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value?>

    init() { storage = Mutex(nil) }

    func set(_ value: Value) { storage.withLock { $0 = value } }
    var value: Value? { storage.withLock { $0 } }
}

@Suite("Act start mainline refresh")
struct ActStartMainlineRefreshTests {
    private struct ExpectedCommits {
        let good: String
        let broken: String
        let spec: String
    }

    private struct TempRepo: ~Copyable {
        let url: URL
        let git = GitRunner()

        init(name: String) {
            self.url = FileManager.default.temporaryDirectory
                .appending(component: "act-git-\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        var path: String { url.path(percentEncoded: false) }

        @discardableResult
        func run(_ args: [String]) async -> GitCommandResult {
            await git.run(["-C", path] + args)
        }

        func initRepo(bare: Bool = false, defaultBranch: String = "main") async {
            if bare {
                _ = await run(["init", "--bare", "--initial-branch=\(defaultBranch)"])
            } else {
                _ = await run(["init", "--initial-branch=\(defaultBranch)"])
                _ = await run(["config", "user.name", "Test User"])
                _ = await run(["config", "user.email", "test@example.com"])
                _ = await run(["config", "commit.gpgsign", "false"])
            }
        }

        @discardableResult
        func commit(
            filename: String = "file.txt",
            content: String = "content",
            message: String = "commit"
        ) async throws -> String {
            let fileURL = url.appending(component: filename)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            _ = await run(["add", "."])
            _ = await run(["commit", "-m", message])
            let result = await run(["rev-parse", "--verify", "--quiet", "HEAD"])
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test(
        "Act start: EngineInvocation refreshes mainlines at Act start for author, build, and land Acts",
        arguments: Act.allCases
    )
    func actStartRefreshesMainlines(_ act: Act) async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let projectID = try #require(ProjectID(rawValue: "mainline"))
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: projectID)

        // 1. Good repo: bare remote with a new commit to fetch
        let goodRemote = TempRepo(name: "good-remote")
        await goodRemote.initRepo(bare: true)

        let goodLocal = TempRepo(name: "good-local")
        await goodLocal.initRepo()
        await goodLocal.run(["remote", "add", "origin", goodRemote.path])
        _ = try await goodLocal.commit(message: "initial good")
        await goodLocal.run(["push", "-u", "origin", "main"])
        await goodLocal.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])

        // Push new commit to goodRemote
        let pusher = TempRepo(name: "pusher")
        await pusher.initRepo()
        await pusher.run(["remote", "add", "origin", goodRemote.path])
        await pusher.run(["fetch", "origin", "main"])
        await pusher.run(["checkout", "main"])
        let newGoodSHA = try await pusher.commit(filename: "update.txt", content: "new", message: "new good commit")
        await pusher.run(["push", "origin", "main"])

        // 2. Broken repo: unreachable origin URL
        let brokenLocal = TempRepo(name: "broken-local")
        await brokenLocal.initRepo()
        await brokenLocal.run(["remote", "add", "origin", "http://127.0.0.1:59999/unreachable.git"])
        let brokenSHA = try await brokenLocal.commit(message: "broken initial")
        // Cache a remote ref so fallback has something to read
        await brokenLocal.run(["update-ref", "refs/remotes/origin/main", brokenSHA])
        await brokenLocal.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])

        // 3. Spec source: remote has newer commits, but spec source is never fetched
        let specRemote = TempRepo(name: "spec-remote")
        await specRemote.initRepo(bare: true)

        let specLocal = TempRepo(name: "spec-local")
        await specLocal.initRepo()
        await specLocal.run(["remote", "add", "origin", specRemote.path])
        let specInitialSHA = try await specLocal.commit(message: "spec v1")
        await specLocal.run(["push", "-u", "origin", "main"])

        let specAuthor = TempRepo(name: "spec-author")
        await specAuthor.initRepo()
        await specAuthor.run(["remote", "add", "origin", specRemote.path])
        await specAuthor.run(["fetch", "origin", "main"])
        await specAuthor.run(["checkout", "main"])
        _ = try await specAuthor.commit(filename: "v2.md", content: "v2", message: "spec v2")
        await specAuthor.run(["push", "origin", "main"])

        // Construct ProjectRepositories
        let workingRepos = [
            Repo(name: "good-repo", path: goodLocal.path, role: .backend),
            Repo(name: "broken-repo", path: brokenLocal.path, role: .mobile)
        ]
        let specSource = SpecSource(path: specLocal.path)
        let projectRepos = ProjectRepositories(workingRepos: workingRepos, specSource: specSource)

        let context = try await runInvocation(act: act, journal: journal, repositories: projectRepos)

        try assertRefresh(
            context: context, journal: journal, act: act,
            commits: ExpectedCommits(good: newGoodSHA, broken: brokenSHA, spec: specInitialSHA)
        )
    }

    private func runInvocation(
        act: Act, journal: JournalStore, repositories: ProjectRepositories
    ) async throws -> ActContext {
        let nightStart = NightStart(rawValue: "2026-09-16")!
        let contextBox = ResultBox<ActContext>()

        let invocation = EngineInvocation(
            act: act,
            mode: .real,
            nightStart: nightStart,
            journal: journal,
            trigger: .forced,
            repositories: repositories,
            work: { context in
                contextBox.set(context)
            }
        )

        try await invocation.run()
        return try #require(contextBox.value)
    }

    private func assertRefresh(
        context: ActContext, journal: JournalStore, act: Act,
        commits: ExpectedCommits
    ) throws {
        // Verify ActContext
        // 1. Good repo fetched new commit
        let goodMainline = try #require(context.mainlines["good-repo"])
        #expect(goodMainline.commit == commits.good)
        #expect(goodMainline.ref == "refs/remotes/origin/main")

        // 2. Broken repo fell back to cached ref
        let brokenMainline = try #require(context.mainlines["broken-repo"])
        #expect(brokenMainline.commit == commits.broken)
        #expect(brokenMainline.ref == "refs/remotes/origin/main")

        // 3. Spec source read local checkout, not the newer remote commit
        let resolvedSpec = try #require(context.mainlines.specSource)
        #expect(resolvedSpec.commit == commits.spec)
        #expect(resolvedSpec.ref == "refs/heads/main")

        // Verify Journal events: MainlineFetchFailed recorded for broken-repo only
        let events = try journal.events()
        let fetchFailedEvents = events.filter { $0.type == .mainlineFetchFailed }
        #expect(fetchFailedEvents.count == 1)

        guard case .mainlineFetchFailed(let repository, let reason) = fetchFailedEvents[0].event else {
            Issue.record("Expected mainlineFetchFailed event")
            return
        }
        #expect(repository == "broken-repo")
        #expect(!reason.isEmpty)
        #expect(fetchFailedEvents[0].act == act)
        #expect(fetchFailedEvents[0].nightID != nil)
    }
}
