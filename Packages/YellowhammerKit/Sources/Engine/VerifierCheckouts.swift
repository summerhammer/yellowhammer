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

    /// The judged checkouts the Verification record names, sorted by repository.
    public var judgedCheckouts: [JudgedCheckout] {
        byRepository.values.compactMap(\.judged).sorted { $0.repository < $1.repository }
    }
}

/// Makes the checkouts Verification judges and removes them when it ends (spec:
/// verification/verify-a-feature-clause-by-clause, `#judged-checkout`; OQ191 items 2, 5, 7 and 8). The engine's
/// own is ``JudgedCheckoutPreparation``; a test hands another in.
public protocol VerifierCheckoutPreparing: Sendable {
    /// The checkout of every repository in `repositories` (sorted names) for `context`'s Cycle. Throws
    /// ``VerificationFault`` when a repository has nothing recorded to judge or a checkout cannot be made, having
    /// removed whatever it made.
    func prepare(_ context: LandActFeatureContext, repositories: [String]) async throws -> VerifierCheckouts

    /// Removes what ``prepare(_:repositories:)`` made, whatever Verification came to. Never throws.
    func release(_ checkouts: VerifierCheckouts)
}
