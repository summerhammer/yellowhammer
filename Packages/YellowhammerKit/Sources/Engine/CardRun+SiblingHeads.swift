import Domain
import Foundation
import Journal
import Repositories

/// What a Check record names besides its result (OQ198 item 3, Lane-less Repository Checkout Ruling
/// 2026-11-02): the HEAD of every other touched repository's held Worktree, and the configured lockfile's
/// identity at the judged commit. Local git, run directly; a failing read is recorded, never thrown.
extension CardRun {
    /// The other repositories the Feature touches, sorted; empty for a single-repository Feature.
    func siblingRepositories(frame: CardRunFrame) -> [String] {
        let touched = (try? frame.journal.touchedRepositories(featureID: frame.context.feature.id)) ?? []
        return Set(touched).subtracting([frame.card.repository]).sorted()
    }

    /// The HEAD of each of `repositories`' held Worktree right now.
    func siblingHeads(frame: CardRunFrame, repositories: [String]) async -> [String: SiblingWorktreeHead] {
        var heads: [String: SiblingWorktreeHead] = [:]
        for repository in repositories {
            heads[repository] = await siblingHead(frame: frame, repository: repository)
        }
        return heads
    }

    private func siblingHead(frame: CardRunFrame, repository: String) async -> SiblingWorktreeHead {
        let held: WorktreeRecord?
        do {
            held = try frame.journal.heldWorktree(featureID: frame.context.feature.id, repository: repository)
        } catch {
            return .unreadable(reason: "the Journal could not be read: \(error)")
        }
        guard let held, held.isHeld else { return .noHeldWorktree }
        let result = await GitRunner().run(
            ["-C", held.path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"], timeout: 10
        )
        let head = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.isSuccess, !head.isEmpty else {
            return .unreadable(reason: result.failureReason(fallback: "HEAD of \(held.path) does not resolve"))
        }
        return .commit(head)
    }

    /// The `before` and `after` HEADs paired per repository, in `repositories` order.
    func siblingStates(
        repositories: [String], before: [String: SiblingWorktreeHead], after: [String: SiblingWorktreeHead]
    ) -> [CheckSiblingState] {
        repositories.map { repository in
            CheckSiblingState(
                repository: repository,
                before: before[repository] ?? .noHeldWorktree,
                after: after[repository] ?? .noHeldWorktree
            )
        }
    }

    /// The identity of the Repo's configured lockfile at `commit`: `.unknown` with none configured,
    /// `.absent` when the path does not exist at that commit.
    func lockfileIdentity(frame: CardRunFrame, commit: String) async -> LockfileIdentity {
        guard let path = frame.repository?.lockfile else { return .unknown }
        let result = await GitRunner().run(
            ["-C", frame.worktree.path, "rev-parse", "--verify", "--quiet", "\(commit):\(path)"], timeout: 10
        )
        let objectID = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.isSuccess, !objectID.isEmpty else { return .absent(path: path) }
        // A path naming a directory resolves to a tree: that is no lockfile.
        let kind = await GitRunner().run(["-C", frame.worktree.path, "cat-file", "-t", objectID], timeout: 10)
        guard kind.isSuccess, kind.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "blob" else {
            return .absent(path: path)
        }
        return .blob(path: path, objectID: objectID)
    }
}
