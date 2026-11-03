import Domain
import Foundation
import Journal
import Repositories

/// The engine-computed reading of a Check record for the verifier (OQ198 item 3): which other repositories'
/// held Worktrees were where, the lockfile's identity, and whether the evidence is decisive. The verifier
/// runs no new command; it is handed these lines.
extension FeatureVerification {
    static func verificationCheckResult(
        _ run: CheckRunRecord, repository: String, checkouts: VerifierCheckouts
    ) -> VerificationCheckResult {
        VerificationCheckResult(
            command: run.command, judgedCommit: run.judgedCommit, exitStatus: run.exitStatus,
            siblings: run.siblings.map {
                VerificationSiblingHead(repository: $0.repository, before: head($0.before), after: head($0.after))
            },
            lockfile: display(run.lockfile),
            evidence: evidence(of: run.siblings, repository: repository, checkouts: checkouts)
        )
    }

    /// Decisive when every sibling's HEAD, before and after the Check, equals that sibling's recorded commit.
    /// Otherwise not decisive, naming every sibling that is not. A record that names no sibling in a Feature
    /// with other repositories predates the recording, so it is not decisive either. Lockfile identity never
    /// takes part.
    static func evidence(
        of siblings: [CheckSiblingState], repository: String, checkouts: VerifierCheckouts
    ) -> VerificationCheckEvidence {
        if siblings.isEmpty {
            guard checkouts.byRepository.keys.contains(where: { $0 != repository }) else { return .decisive }
            return .notDecisive(
                "the record names no other repository's HEAD: it was written before Yellowhammer recorded them"
            )
        }
        let reasons = siblings.compactMap { reason(for: $0, checkouts: checkouts) }
        return reasons.isEmpty ? .decisive : .notDecisive(reasons.joined(separator: "; "))
    }

    private static func reason(for sibling: CheckSiblingState, checkouts: VerifierCheckouts) -> String? {
        let name = "`\(sibling.repository)`"
        for head in [sibling.before, sibling.after] {
            switch head {
            case .noHeldWorktree: return "\(name) had no held Worktree when the Check ran"
            case .unreadable(let reason): return "\(name): unreadable: \(reason)"
            case .commit: break
            }
        }
        guard let recorded = checkouts.byRepository[sibling.repository]?.judged?.commit else {
            return "\(name) has no recorded commit to compare with"
        }
        guard sibling.before == .commit(recorded), sibling.after == .commit(recorded) else {
            return "\(name) was at \(display(sibling.before)) before and \(display(sibling.after)) after the Check; "
                + "the recorded commit is \(GitCommit.short(recorded))"
        }
        return nil
    }

    private static func head(_ head: SiblingWorktreeHead) -> VerificationSiblingHead.Head {
        switch head {
        case .commit(let sha): .commit(GitCommit.short(sha))
        case .noHeldWorktree: .noHeldWorktree
        case .unreadable(let reason): .unreadable(reason: reason)
        }
    }

    private static func display(_ head: SiblingWorktreeHead) -> String {
        switch head {
        case .commit(let sha): GitCommit.short(sha)
        case .noHeldWorktree: "no held Worktree"
        case .unreadable(let reason): "unreadable: \(reason)"
        }
    }

    private static func display(_ lockfile: LockfileIdentity) -> String {
        switch lockfile {
        case .unknown: "unknown (none configured)"
        case .absent(let path): "\(path) absent at this commit"
        case .blob(let path, let objectID): "\(path) → blob \(GitCommit.short(objectID))"
        }
    }
}
