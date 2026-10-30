import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// OQ191 (yellowhammer#708): the real-git land world the harness's Act-level cases share, built from the land
// fixtures (`LandPushTestEnvironment`, `TestGitRepo`, `LandCallLog`) and the Verification fixtures. Each
// repository has a main clone whose `origin` is a bare repository, and a held Worktree — a real
// `git worktree add` of the Feature Branch — under one layout directory. So a test can move a Worktree, read
// what the remote holds and see which directory the verifier was handed. No network, no `gh`, no agent CLI:
// the verifier is scripted and the Publication Port is a fixture that records each pull request it opened.

/// Runs git in `path`: a Worktree, a fresh checkout or a bare remote.
func oq191Git(_ path: String, _ args: [String]) async -> GitCommandResult {
    await GitRunner().run(["-C", path] + args)
}

/// `ref` resolved in `path`; nil when it does not resolve.
func oq191RevParse(_ path: String, _ ref: String = "HEAD") async -> String? {
    let result = await oq191Git(path, ["rev-parse", "--verify", "--quiet", ref])
    let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isSuccess && !sha.isEmpty ? sha : nil
}

/// The abbreviated commit a report names: a prefix of the full commit.
func oq191Short(_ commit: String) -> String {
    String(commit.prefix(7))
}

/// `path` with symbolic links resolved, for comparing directories.
func oq191Resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
}

/// The relative path from directory `from` to directory `to`, after resolving symbolic links.
func oq191RelativePath(from: String, to: String) -> String {
    let source = URL(fileURLWithPath: from).resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let target = URL(fileURLWithPath: to).resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let shared = zip(source, target).prefix { $0 == $1 }.count
    return (Array(repeating: "..", count: source.count - shared) + target.dropFirst(shared)).joined(separator: "/")
}

/// One repository of an ``OQ191LandWorld``.
final class OQ191Repository {
    let name: String
    /// The main clone, on `main`; `origin` is ``remote``.
    let clone: TestGitRepo
    /// A bare repository: the remote the Feature Branch is pushed to.
    let remote: TestGitRepo
    /// The held Worktree's directory, as recorded in the Journal.
    let worktree: String
    /// The recorded base commit (`feature_base.base_commit`): `main` when the Feature was selected.
    let base: String
    /// The Feature Branch's tip after setup: one commit past ``base``, or ``base`` itself for a repository with
    /// the No-Pushed-Branch Outcome.
    let tip: String

    init(name: String, clone: TestGitRepo, remote: TestGitRepo, worktree: String, base: String, tip: String) {
        self.name = name
        self.clone = clone
        self.remote = remote
        self.worktree = worktree
        self.base = base
        self.tip = tip
    }

    /// The bare remote's directory, without the trailing slash `TestGitRepo.path` carries.
    var remoteDirectory: String {
        remote.path.hasSuffix("/") ? String(remote.path.dropLast()) : remote.path
    }

    /// The commit the remote Feature Branch is at; nil when it is absent.
    func remoteTip() async -> String? {
        await oq191RevParse(remote.path, "refs/heads/\(landBranch.name)")
    }

    /// The local Feature Branch in the main clone (shared with the Worktree).
    func branchHead() async -> String? {
        await oq191RevParse(clone.path, "refs/heads/\(landBranch.name)")
    }

    /// Commits a new file in the held Worktree, moving whatever its HEAD is on; returns the new HEAD.
    @discardableResult
    func commitInWorktree(_ filename: String) async throws -> String {
        try UUID().uuidString.write(toFile: "\(worktree)/\(filename)", atomically: true, encoding: .utf8)
        _ = await oq191Git(worktree, ["add", filename])
        _ = await oq191Git(worktree, ["commit", "-m", "\(name): \(filename)"])
        return try #require(await oq191RevParse(worktree))
    }
}

/// A Publication Port fixture: refuses a scripted number of pull requests per repository, and records each
/// pull request it opened with the commit the remote Feature Branch was at when it opened.
actor OQ191Publication: Publication {
    struct Opened: Equatable {
        let repository: String
        let remoteTip: String?
    }

    private var refusalsLeft: [String: Int]
    private let remotePaths: [String: String]
    private(set) var calls: [PullRequestDraft] = []
    private(set) var opened: [Opened] = []

    init(refusing: Set<String>, remotePaths: [String: String]) {
        refusalsLeft = Dictionary(uniqueKeysWithValues: refusing.map { ($0, 1) })
        self.remotePaths = remotePaths
    }

    func openPullRequest(_ draft: PullRequestDraft) async throws(PublicationError) -> PullRequestReceipt {
        calls.append(draft)
        if let left = refusalsLeft[draft.repository], left > 0 {
            refusalsLeft[draft.repository] = left - 1
            throw .validationRejected("refused by the OQ191 fixture")
        }
        var tip: String?
        if let path = remotePaths[draft.repository] {
            tip = await oq191RevParse(path, "refs/heads/\(draft.head)")
        }
        opened.append(Opened(repository: draft.repository, remoteTip: tip))
        return .opened(url: "https://github.com/summerhammer/\(draft.repository)/pull/1")
    }

    func opened(_ repository: String) -> [Opened] {
        opened.filter { $0.repository == repository }
    }
}

/// The real push seam, recording each call in the land call log as `push:<repository>`.
struct OQ191LoggedPush: LanePushing {
    let inner: any LanePushing
    let log: LandCallLog

    func push(_ context: LandActLaneContext) async throws -> LanePushOutcome {
        log.add("push:\(context.lane.repository)")
        return try await inner.push(context)
    }
}

/// The engine's own checkouts, kept until the world is gone: a test reads the HEAD of each directory the verifier
/// was handed after the firing returns. That the engine removes them is `JudgedCheckoutPreparationTests`'.
struct OQ191KeptCheckouts: VerifierCheckoutPreparing {
    let inner: JudgedCheckoutPreparation

    func prepare(_ context: LandActFeatureContext, repositories: [String]) async throws -> VerifierCheckouts {
        try await inner.prepare(context, repositories: repositories)
    }

    func release(_ checkouts: VerifierCheckouts) {}
}

/// What one land firing did: the verifier dispatch it used, and what the Act threw.
struct OQ191Firing {
    let dispatch: ScriptedVerifierDispatch
    let error: (any Error)?

    /// The last verifier instruction this firing dispatched.
    var instruction: VerificationInstruction? {
        dispatch.requests.compactMap { request -> VerificationInstruction? in
            guard case .verification(let instruction) = request.instruction else { return nil }
            return instruction
        }.last
    }

    /// The directory each repository was handed to the verifier in, by repository.
    var verifiedDirectories: [String: String] {
        Dictionary(uniqueKeysWithValues: (instruction?.repositories ?? []).map { ($0.name, $0.directory) })
    }
}
