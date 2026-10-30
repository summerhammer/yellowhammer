import Foundation

/// The Publication Port (ADR-001): how Yellowhammer opens a pull request for a Repo Lane's Feature
/// Branch, and reads whether the Operator merged it. GitHub is the vendor behind it.
///
/// Two operations, one credential: the Project's selected Code Hosting Connection, the one the push uses
/// (OQ190 item 29). It opens a pull request and reads pull requests; it never updates, closes, reopens,
/// retargets or merges one, and never reads reviews, comments, approvals or checks (OQ190 item 20).
/// Yellowhammer never merges — the Operator's merge on GitHub is the only closure gesture, and this Port
/// has no way to perform it.
public protocol Publication: Sendable {
    /// Opens one pull request from `draft`. GitHub reporting that a pull request already exists for
    /// this head is not an error: it is `.alreadyOpen`, and carries no URL.
    func openPullRequest(_ draft: PullRequestDraft) async throws(PublicationError) -> PullRequestReceipt

    /// Reads the pull requests `query` names (feature-authoring/select-the-next-feature, `#pull-request-read`):
    /// one by its number, or every pull request whose head is a branch, in any state. Finding none is an empty
    /// answer, never an error: the pull request test then does not apply. A read that cannot be made throws
    /// one of the five ``PullRequestReadFailure/Reason``s (OQ190 item 28).
    func readPullRequests(_ query: PullRequestQuery) async throws(PullRequestReadFailure) -> [ObservedPullRequest]
}

/// A pull request to open. `owner`/`repository` are the opaque slug halves a Port may carry across it
/// (ADR-001); everything else is plain text this Port hands to GitHub unread.
public struct PullRequestDraft: Equatable, Sendable {
    public let owner: String
    public let repository: String
    /// The branch to open the pull request from.
    public let head: String
    /// The branch to open the pull request against: the repository's default branch, or, for a stacked
    /// pull request, the predecessor Feature's Feature Branch (spec: landing/open-one-pull-request-per-repository
    /// `#stack-notice`). Always a branch name as GitHub expects it, never a ref.
    public let base: String
    public let title: String
    public let body: String

    public init(owner: String, repository: String, head: String, base: String, title: String, body: String) {
        self.owner = owner
        self.repository = repository
        self.head = head
        self.base = base
        self.title = title
        self.body = body
    }
}

/// What opening a pull request resolved to.
public enum PullRequestReceipt: Equatable, Sendable {
    /// GitHub created the pull request at `url`.
    case opened(url: String)
    /// GitHub reports a pull request already exists for this head. No URL: GitHub's refusal names none. The
    /// predecessor gate finds that pull request later by its head branch (OQ190 item 27).
    case alreadyOpen
}

/// A refusal, unavailability, or malformed response from the Publication Port. Never carries a
/// credential.
public enum PublicationError: Error, Equatable, Sendable {
    /// The GitHub credential is missing or insufficient to open a pull request.
    case credentialsMissingOrInsufficient(String)
    /// GitHub reports the repository does not exist, or is not accessible with this credential.
    case repositoryNotFound(String)
    /// GitHub rejected the request's content, carrying its own detail.
    case validationRejected(String)
    /// GitHub's rate limit was reached.
    case rateLimited(String)
    /// The GitHub API could not be reached, or its response could not be read.
    case transport(String)
    /// Anything else GitHub refused the request for.
    case other(String)
}

extension PublicationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .credentialsMissingOrInsufficient(let detail):
            "GitHub credentials are missing or insufficient: \(detail)"
        case .repositoryNotFound(let detail):
            "GitHub reports the repository not found or not accessible: \(detail)"
        case .validationRejected(let detail):
            "GitHub rejected the pull request: \(detail)"
        case .rateLimited(let detail):
            "GitHub's rate limit was reached: \(detail)"
        case .transport(let detail):
            "GitHub could not be reached: \(detail)"
        case .other(let detail):
            "GitHub refused the request: \(detail)"
        }
    }
}
