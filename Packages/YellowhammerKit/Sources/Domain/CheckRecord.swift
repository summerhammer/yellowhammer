import Foundation

/// The HEAD of another touched repository's held Worktree at one moment around a Check (OQ198 item 3,
/// Lane-less Repository Checkout Ruling 2026-11-02).
public enum SiblingWorktreeHead: Equatable, Sendable {
    /// The full commit SHA the Worktree's HEAD pointed at.
    case commit(String)
    /// No Worktree is held in that repository.
    case noHeldWorktree
    /// The HEAD could not be read; `reason` says why.
    case unreadable(reason: String)
}

/// One other touched repository's held Worktree HEAD before and after a Check (OQ198 item 3, Lane-less
/// Repository Checkout Ruling 2026-11-02): each Check record names, for every other touched repository,
/// the HEAD of its held Worktree before and after the Check.
public struct CheckSiblingState: Equatable, Sendable {
    public let repository: String
    public let before: SiblingWorktreeHead
    public let after: SiblingWorktreeHead

    public init(repository: String, before: SiblingWorktreeHead, after: SiblingWorktreeHead) {
        self.repository = repository
        self.before = before
        self.after = after
    }
}

/// The identity of the configured lockfile at the Check's commit (OQ198 item 3, Lane-less Repository
/// Checkout Ruling 2026-11-02).
public enum LockfileIdentity: Equatable, Sendable {
    /// No lockfile is configured for the Repo.
    case unknown
    /// A lockfile is configured but its path does not exist at the Check's commit.
    case absent(path: String)
    /// The configured lockfile's git blob object ID at the Check's commit.
    case blob(path: String, objectID: String)
}

/// The fields of a `checkRan` event, wrapped in a struct to keep `JournalEvent`'s cases within SwiftLint's
/// associated-values-count limit.
///
/// The engine-run Check ran over an Attempt's work (P8.5), pass or fail or declared none. `output` is what
/// it printed, already capped by the runner; it is empty or nil when nothing ran. `judgedCommit` is the
/// worker commit the Check judged: a passing Check writes no Round, so this event is the only place a
/// Check's result is tied to a commit. `command` is the actual executed command, never current
/// configuration. `siblings` and `lockfile` are the OQ198 item 3 record. All of these are nil, empty or
/// `unknown` on events written before they were recorded.
public struct CheckRanPayload: Equatable, Sendable {
    public let cardID: Int64
    public let issueID: String
    public let attemptID: Int64
    public let result: CheckRunResult
    public let exitStatus: Int32?
    public let output: String?
    public let judgedCommit: String?
    public let command: String?
    public let siblings: [CheckSiblingState]
    public let lockfile: LockfileIdentity

    public init(
        cardID: Int64, issueID: String, attemptID: Int64, result: CheckRunResult, exitStatus: Int32?,
        output: String?, judgedCommit: String?, command: String? = nil,
        siblings: [CheckSiblingState] = [], lockfile: LockfileIdentity = .unknown
    ) {
        self.cardID = cardID
        self.issueID = issueID
        self.attemptID = attemptID
        self.result = result
        self.exitStatus = exitStatus
        self.output = output
        self.judgedCommit = judgedCommit
        self.command = command
        self.siblings = siblings
        self.lockfile = lockfile
    }
}
