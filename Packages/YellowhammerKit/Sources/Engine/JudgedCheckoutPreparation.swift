import Domain
import Foundation
import Journal
import Repositories

/// The engine's ``VerifierCheckoutPreparing`` (spec: verification/verify-a-feature-clause-by-clause,
/// `#judged-checkout`; OQ191 items 2, 5, 7 and 8): *"a Cycle judges and publishes what it pushed"*.
///
/// Each repository is judged at its recorded commit: its Pushed Tip for this Cycle, or, for a repository with the
/// No-Pushed-Branch Outcome — a touched repository no Work Card names included — its recorded base commit
/// (`feature_base.base_commit`), never the base ref resolved again. A repository with neither is not judged at
/// anything else: Verification faults and records nothing.
///
/// The held Worktrees are the checkout only when every repository has one whose HEAD is its recorded commit and
/// whose `git status` reports nothing (ignored files allowed). Otherwise every repository gets a fresh checkout
/// under `<directory>/cycle-<id>`, laid out as ``FreshCheckoutLayout`` places it; a repository with no held
/// Worktree counts as not exact and clean (Operator decision for OQ195). ``release(_:)`` removes that root, and
/// each Verification first removes any root a crashed Act left behind.
///
/// A Rehearsal Night pushes nothing, so no recorded commit exists by design: the verifier, answered by a
/// fixture, is handed each held Worktree (else the repository) as before, and the record names no judged commit.
public struct JudgedCheckoutPreparation: VerifierCheckoutPreparing {
    /// The Project's own directory for fresh-checkout roots. Outside Yellowhammer's configuration directory,
    /// which every read-only pass is denied (issue #546), so the verifier can read what is made here.
    public let directory: URL
    let git: JudgedCheckoutGit
    /// Compares each held Worktree's HEAD with its recorded commit, for the "not published" report.
    let heads: UnpublishedHeadPin

    public init(
        directory: URL, git: JudgedCheckoutGit = JudgedCheckoutGit(), heads: UnpublishedHeadPin = UnpublishedHeadPin()
    ) {
        self.directory = directory
        self.git = git
        self.heads = heads
    }

    /// `<home>/.cache/yellowhammer/verification/<project id>`: disposable, Yellowhammer-owned, never a
    /// macOS-protected folder, and outside the configuration directory.
    public static func directory(homeDirectory: URL, projectID: ProjectID) -> URL {
        homeDirectory.appending(
            components: ".cache", "yellowhammer", "verification", projectID.rawValue, directoryHint: .isDirectory
        )
    }

    /// The fresh-checkout root for `cycleID`.
    func root(cycleID: Int64) -> URL {
        directory.appending(component: "cycle-\(cycleID)", directoryHint: .isDirectory)
    }

    public func plan(
        _ context: LandActFeatureContext, repositories names: [String]
    ) async throws -> VerifierCheckoutPlan {
        let targets = try names.map { try target(named: $0, context: context) }
        if context.act.mode == .rehearsal {
            return VerifierCheckoutPlan(repositories: names, judgedCheckouts: [])
        }
        let recorded = try recordedCommits(names, context: context)
        pruneStaleRoots()
        // Each held Worktree's HEAD is read once; both the report and the reuse decision derive from it.
        let relations = await headRelations(targets, recorded: recorded)
        let unpublished = unpublishedHeads(targets, recorded: recorded, relations: relations)
        let kind: JudgedCheckout.Kind = await heldWorktreesAreExactAndClean(targets, relations: relations)
            ? .heldWorktree
            : .freshCheckout
        return VerifierCheckoutPlan(
            repositories: names,
            judgedCheckouts: names.compactMap { recorded[$0]?.judged(kind: kind) }
                .sorted { $0.repository < $1.repository },
            unpublishedHeads: unpublished
        )
    }

    public func materialise(
        _ plan: VerifierCheckoutPlan, context: LandActFeatureContext
    ) async throws -> VerifierCheckouts {
        let targets = try plan.repositories.map { try target(named: $0, context: context) }
        if context.act.mode == .rehearsal {
            return VerifierCheckouts(
                byRepository: Dictionary(uniqueKeysWithValues: targets.map {
                    ($0.name, VerifierCheckout(directory: $0.heldWorktree ?? $0.repo.path, judged: nil))
                }),
                freshRoot: nil
            )
        }
        let recorded = Dictionary(uniqueKeysWithValues: plan.judgedCheckouts.map {
            (
                $0.repository,
                RecordedCommit(repository: $0.repository, commit: $0.commit, noPushedBranch: $0.noPushedBranch)
            )
        })
        if plan.judgedCheckouts.allSatisfy({ $0.kind == .heldWorktree }) {
            return VerifierCheckouts(
                byRepository: Dictionary(uniqueKeysWithValues: targets.map { target in
                    let judged = recorded[target.name]?.judged(kind: .heldWorktree)
                    return (target.name, VerifierCheckout(directory: target.heldWorktree ?? "", judged: judged))
                }),
                freshRoot: nil
            )
        }
        return try await freshCheckouts(targets, recorded: recorded, cycleID: context.cycleID)
    }

    public func release(_ checkouts: VerifierCheckouts) {
        guard let root = checkouts.freshRoot else { return }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Recorded commits

    private struct Target {
        let name: String
        let repo: Repo
        /// The held Worktree's path, unmodified; nil when the repository has none held.
        let heldWorktree: String?
    }

    private struct RecordedCommit {
        let repository: String
        let commit: String
        let noPushedBranch: Bool

        func judged(kind: JudgedCheckout.Kind) -> JudgedCheckout {
            JudgedCheckout(repository: repository, commit: commit, kind: kind, noPushedBranch: noPushedBranch)
        }
    }

    private func target(named name: String, context: LandActFeatureContext) throws -> Target {
        guard let repo = context.act.repositories?.workingRepo(named: name) else {
            throw VerificationFault(reason: "the Feature touched repository \"\(name)\", which is not configured")
        }
        let held = try context.act.journal.heldWorktree(featureID: context.feature.id, repository: name)
        return Target(name: name, repo: repo, heldWorktree: held?.isHeld == true ? held?.path : nil)
    }

    /// Each repository's recorded commit, or a ``VerificationFault`` naming the first repository that has none.
    private func recordedCommits(
        _ names: [String], context: LandActFeatureContext
    ) throws -> [String: RecordedCommit] {
        let journal = context.act.journal
        let noPushedBranch = Set(try journal.noPushedBranchRepositories(featureID: context.feature.id))
        let bases = Dictionary(
            try journal.featureBases(featureID: context.feature.id).map { ($0.repository, $0.baseCommit) }
        ) { first, _ in first }
        var recorded: [String: RecordedCommit] = [:]
        for name in names {
            if let tip = try journal.pushedTip(cycleID: context.cycleID, repository: name) {
                recorded[name] = RecordedCommit(repository: name, commit: tip, noPushedBranch: false)
            } else if noPushedBranch.contains(name), let base = bases[name] {
                recorded[name] = RecordedCommit(repository: name, commit: base, noPushedBranch: true)
            } else {
                let missing = noPushedBranch.contains(name)
                    ? "it has the No-Pushed-Branch Outcome but no recorded base commit"
                    : "it has no Pushed Tip for this Cycle and no No-Pushed-Branch Outcome"
                throw VerificationFault(
                    reason: "repository \"\(name)\" has no recorded commit to judge: \(missing); "
                        + "Verification judges only what the Cycle pushed"
                )
            }
        }
        return recorded
    }

    // MARK: - Checkouts

    /// How each held Worktree's HEAD stands against its recorded commit, by repository; a repository with no held
    /// Worktree has none.
    private func headRelations(
        _ targets: [Target], recorded: [String: RecordedCommit]
    ) async -> [String: WorktreeHeadRelation] {
        var relations: [String: WorktreeHeadRelation] = [:]
        for target in targets {
            guard let worktree = target.heldWorktree, let commit = recorded[target.name] else { continue }
            relations[target.name] = await heads.headRelation(worktreePath: worktree, recordedCommit: commit.commit)
        }
        return relations
    }

    /// Each held Worktree whose HEAD is not its recorded commit, descendant or not (OQ191 items 2, 5 and 9). A
    /// HEAD git cannot read is not reported: nothing is pinned here, and release reads it again.
    private func unpublishedHeads(
        _ targets: [Target], recorded: [String: RecordedCommit], relations: [String: WorktreeHeadRelation]
    ) -> [UnpublishedHead] {
        targets.sorted(by: { $0.name < $1.name }).compactMap { target in
            guard let relation = relations[target.name], let commit = recorded[target.name] else { return nil }
            return UnpublishedHead(
                relation, repository: target.name, recordedCommit: commit.commit,
                noPushedBranch: commit.noPushedBranch
            )
        }
    }

    /// True when every repository has a held Worktree whose HEAD is its recorded commit and whose `git status`
    /// reports nothing.
    private func heldWorktreesAreExactAndClean(
        _ targets: [Target], relations: [String: WorktreeHeadRelation]
    ) async -> Bool {
        for target in targets {
            guard let worktree = target.heldWorktree, relations[target.name] == .atRecordedCommit else { return false }
            guard await git.isClean(worktreePath: worktree) else { return false }
        }
        return true
    }

    private func freshCheckouts(
        _ targets: [Target], recorded: [String: RecordedCommit], cycleID: Int64
    ) async throws -> VerifierCheckouts {
        let root = root(cycleID: cycleID)
        let layout = FreshCheckoutLayout.relativePaths(
            heldWorktrees: targets.reduce(into: [:]) { $0[$1.name] = $1.heldWorktree },
            repositories: targets.map(\.name)
        )
        var byRepository: [String: VerifierCheckout] = [:]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for target in targets {
                guard let commit = recorded[target.name], let relative = layout[target.name] else { continue }
                let destination = root.appending(path: relative, directoryHint: .isDirectory)
                    .path(percentEncoded: false)
                do {
                    try await git.makeFreshCheckout(
                        mainClonePath: (target.repo.path as NSString).expandingTildeInPath, commit: commit.commit,
                        destination: destination
                    )
                } catch {
                    throw VerificationFault(
                        reason: "could not make a fresh checkout of \"\(target.name)\" at "
                            + "\(commit.commit.prefix(7)) for the verifier: \(error)"
                    )
                }
                byRepository[target.name] = VerifierCheckout(
                    directory: destination, judged: commit.judged(kind: .freshCheckout)
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            if error is VerificationFault { throw error }
            throw VerificationFault(reason: "could not make the verifier's fresh-checkout directory: \(error)")
        }
        return VerifierCheckouts(byRepository: byRepository, freshRoot: root)
    }

    /// Removes every fresh-checkout root a crashed Act left behind. A land Act holds the Project's lease, so no
    /// other Verification of this Project is running.
    private func pruneStaleRoots() {
        let fileManager = FileManager.default
        guard let stale = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for root in stale {
            try? fileManager.removeItem(at: root)
        }
    }
}
