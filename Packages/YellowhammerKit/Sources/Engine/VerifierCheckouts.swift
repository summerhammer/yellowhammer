import Domain
import Foundation

/// One repository's checkout as the verifier is handed it.
public struct VerifierCheckout: Equatable, Sendable {
    /// The directory the verifier reads the finished code in.
    public let directory: String
    /// What the Verification record names for the repository; nil where nothing was pushed by design (a
    /// Rehearsal Night), so the record says "judged commit not recorded".
    public let judged: JudgedCheckout?

    public init(directory: String, judged: JudgedCheckout?) {
        self.directory = directory
        self.judged = judged
    }
}

/// Every repository's checkout for one Verification, and the fresh-checkout root to remove when it ends.
public struct VerifierCheckouts: Equatable, Sendable {
    /// By repository name.
    public let byRepository: [String: VerifierCheckout]
    /// The directory every fresh checkout was made under; nil when none was made.
    public let freshRoot: URL?

    public init(byRepository: [String: VerifierCheckout], freshRoot: URL?) {
        self.byRepository = byRepository
        self.freshRoot = freshRoot
    }
}

/// What Verification decides about its checkouts before it makes any: the commit each repository is judged at
/// and the held Worktrees whose HEAD is not that commit. Cheap to resolve, so it is resolved on every
/// Verification; the checkouts themselves are made only when a clause goes to the verifier.
public struct VerifierCheckoutPlan: Equatable, Sendable {
    /// The repositories to hand the verifier a checkout of (sorted names).
    public let repositories: [String]
    /// The judged checkouts the Verification record names, sorted by repository; empty where nothing was pushed by
    /// design (a Rehearsal Night).
    public let judgedCheckouts: [JudgedCheckout]
    /// Each held Worktree whose HEAD was not its repository's recorded commit, sorted by repository: reported as
    /// not published once Verification is recorded (OQ191 items 2 and 5).
    public let unpublishedHeads: [UnpublishedHead]

    public init(repositories: [String], judgedCheckouts: [JudgedCheckout], unpublishedHeads: [UnpublishedHead] = []) {
        self.repositories = repositories
        self.judgedCheckouts = judgedCheckouts
        self.unpublishedHeads = unpublishedHeads
    }
}

/// Makes the checkouts Verification judges and removes them when it ends (spec:
/// verification/verify-a-feature-clause-by-clause, `#judged-checkout`; OQ191 items 2, 5, 7 and 8). The engine's
/// own is ``JudgedCheckoutPreparation``; a test hands another in.
public protocol VerifierCheckoutPreparing: Sendable {
    /// Resolves the plan for `repositories` (sorted names) for `context`'s Cycle, making no checkout. Throws
    /// ``VerificationFault`` when a repository has nothing recorded to judge.
    func plan(_ context: LandActFeatureContext, repositories: [String]) async throws -> VerifierCheckoutPlan

    /// Makes the checkouts `plan` describes. Throws ``VerificationFault`` when a checkout cannot be made, having
    /// removed whatever it made.
    func materialise(_ plan: VerifierCheckoutPlan, context: LandActFeatureContext) async throws -> VerifierCheckouts

    /// Removes what ``materialise(_:context:)`` made, whatever Verification came to. Never throws.
    func release(_ checkouts: VerifierCheckouts)
}
