import Foundation

// The values the Publication Port's pull request read carries across it (feature-authoring/
// select-the-next-feature, `#pull-request-read`; OQ190 items 20, 27 and 28). Plain values only: no vendor
// type, error shape or query language crosses the Port (ADR-001).

/// Which pull requests to read in one repository. `owner`/`repository` are the opaque slug halves a Port
/// may carry across it.
public struct PullRequestQuery: Equatable, Sendable {
    /// How the pull requests are found.
    public enum Selector: Equatable, Sendable {
        /// The one pull request with this number: the number in the URL the land Act recorded.
        case number(Int)
        /// Every pull request whose head is this branch of this repository, in any state: for a Feature whose
        /// land Act recorded no URL, because Code Hosting answered that a pull request already existed.
        case headBranch(String)
    }

    public let owner: String
    public let repository: String
    public let selector: Selector

    public init(owner: String, repository: String, selector: Selector) {
        self.owner = owner
        self.repository = repository
        self.selector = selector
    }
}

/// Whether a pull request is open, merged, or closed without merging: the last observed state the spec
/// names (`open`, `merged`, `closed without merge`). Read, never set.
public enum ObservedPullRequestState: String, Sendable, Equatable, CaseIterable {
    case open
    case merged
    case closedWithoutMerge = "closed_without_merge"
}

/// One pull request as the read found it, and nothing more than OQ190 item 20 allows: its state, the commit
/// it merged into, its head commit and head branch, and the branch it targets — plus its number and URL to
/// name it.
public struct ObservedPullRequest: Equatable, Sendable {
    public let number: Int
    public let url: String
    public let state: ObservedPullRequestState
    /// The commit the pull request merged into its base branch. Nil unless ``state`` is
    /// ``ObservedPullRequestState/merged``.
    public let mergeCommit: String?
    public let headCommit: String
    public let headBranch: String
    /// The branch the pull request targets: the default branch, or a lower Feature's Feature Branch.
    public let baseBranch: String

    public init(
        number: Int, url: String, state: ObservedPullRequestState, mergeCommit: String?, headCommit: String,
        headBranch: String, baseBranch: String
    ) {
        self.number = number
        self.url = url
        self.state = state
        self.mergeCommit = state == .merged ? mergeCommit : nil
        self.headCommit = headCommit
        self.headBranch = headBranch
        self.baseBranch = baseBranch
    }
}

/// A pull request read that could not be made (OQ190 item 28). Never a Failure Notice and never a halt: the
/// pull request test does not hold this pass, and the content test still runs. Never carries a credential.
public struct PullRequestReadFailure: Error, Equatable, Sendable {
    /// Why the read could not be made: exactly the five reasons the spec names. The raw value is what the
    /// Journal records.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        /// Code Hosting could not be reached.
        case unreachable
        /// The credential is missing or was refused.
        case credentialRefused = "credential_refused"
        /// The credential cannot see the repository or the pull request.
        case noAccess = "no_access"
        /// Code Hosting's rate limit was reached.
        case rateLimited = "rate_limited"
        /// Code Hosting answered something that could not be read.
        case unreadableAnswer = "unreadable_answer"
    }

    public let reason: Reason
    /// Code Hosting's own words, for diagnosis only.
    public let detail: String

    public init(_ reason: Reason, detail: String) {
        self.reason = reason
        self.detail = detail
    }
}
