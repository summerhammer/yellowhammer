import Foundation

/// The Card a dispatch is running against: just enough for the instruction to name it, not the full
/// board object.
public struct InstructionCard: Equatable, Sendable {
    public let key: String
    public let title: String
    public let description: String?

    public init(key: String, title: String, description: String? = nil) {
        self.key = key
        self.title = title
        self.description = description
    }
}

/// One Definition of Done clause, with the machine-minted id the reviewer references and its optional
/// citation back to the spec.
public struct DoDClause: Equatable, Sendable {
    public let id: String
    public let text: String
    public let citation: SpecCitation?

    public init(id: String, text: String, citation: SpecCitation? = nil) {
        self.id = id
        self.text = text
        self.citation = citation
    }
}

/// The repository a pass is dispatched into: which Repo, which Worktree, which Feature Branch, and
/// the Check it must satisfy.
public struct InstructionRepository: Equatable, Sendable {
    public let repo: Repo
    public let worktreePath: String
    public let featureBranch: String
    public let check: Check

    public init(repo: Repo, worktreePath: String, featureBranch: String, check: Check) {
        self.repo = repo
        self.worktreePath = worktreePath
        self.featureBranch = featureBranch
        self.check = check
    }
}

/// The WIP ref left by a Worktree reconciliation, handed to a retry as context only — explicitly not
/// as a known-good state (loop-state/reconcile-worktrees-at-act-start).
public struct WIPContext: Equatable, Sendable {
    public let commit: String
    public let note: String?

    public init(commit: String, note: String? = nil) {
        self.commit = commit
        self.note = note
    }
}

/// One human reply to a worker's earlier question, flagged Operator-supplied.
public struct OperatorReply: Equatable, Sendable {
    public let body: String
    public let repliedAt: Date
    public let commentID: String

    public init(body: String, repliedAt: Date, commentID: String) {
        self.body = body
        self.repliedAt = repliedAt
        self.commentID = commentID
    }
}

/// A worker's earlier question and every human reply to it since it was asked.
public struct AnsweredQuestion: Equatable, Sendable {
    public let question: String
    public let askedOn: NightStart
    public let replies: [OperatorReply]

    public init(question: String, askedOn: NightStart, replies: [OperatorReply]) {
        self.question = question
        self.askedOn = askedOn
        self.replies = replies
    }
}

/// A reply banked from a prior Night, replayed into a later retry's instruction. Dated, Operator-supplied,
/// unverified against the repositories as they now stand — the rendering must say so.
public struct BankedReply: Equatable, Sendable {
    public let body: String
    public let night: NightStart
    /// Repository name to the 40-hex mainline commit as of the Night this reply was banked.
    public let mainlineCommits: [String: String]
    public let commentID: String

    public init(body: String, night: NightStart, mainlineCommits: [String: String], commentID: String) {
        self.body = body
        self.night = night
        self.mainlineCommits = mainlineCommits
        self.commentID = commentID
    }
}

/// One prior Round's feedback, carried forward into the retry's instruction.
public struct RoundFeedback: Equatable, Sendable {
    /// 1-based: the first Round is 1, never 0. Round is not Attempt.
    public let round: Int
    public let lens: Lens
    public let verdict: String
    public let requestedChanges: String?
    public let judgedCommit: String?

    public init(round: Int, lens: Lens, verdict: String, requestedChanges: String? = nil, judgedCommit: String? = nil) {
        self.round = round
        self.lens = lens
        self.verdict = verdict
        self.requestedChanges = requestedChanges
        self.judgedCommit = judgedCommit
    }
}

/// Every optional payload an instruction may carry, beyond the Brief and the DoD. Each is omitted
/// entirely from the rendering when absent or empty.
public struct InstructionPayloads: Equatable, Sendable {
    public let wip: WIPContext?
    public let answeredQuestion: AnsweredQuestion?
    public let bankedReplies: [BankedReply]
    public let roundFeedback: [RoundFeedback]

    public init(
        wip: WIPContext? = nil,
        answeredQuestion: AnsweredQuestion? = nil,
        bankedReplies: [BankedReply] = [],
        roundFeedback: [RoundFeedback] = []
    ) {
        self.wip = wip
        self.answeredQuestion = answeredQuestion
        self.bankedReplies = bankedReplies
        self.roundFeedback = roundFeedback
    }

    public static let none = InstructionPayloads()
}

/// The Project's commit-message Message Template, already rendered with the Card's tokens, that the worker
/// pass's instruction asks the worker to follow. Not part of the Architectural Brief.
public struct CommitMessageRequest: Equatable, Sendable {
    /// The rendered `[git] commit_message` template.
    public let message: String
    /// The Card's human Linear identifier (such as `YLH-42`); nil when it is not known.
    public let cardKey: String?

    public init(message: String, cardKey: String? = nil) {
        self.message = message
        self.cardKey = cardKey
    }
}

/// The instruction Yellowhammer composes and hands to the CLI for one pass of one dispatch. Yellowhammer
/// owns the instruction and the result contract; the CLI owns execution — this is data plus a
/// deterministic text rendering, nothing about tools, context management or subagents.
public struct Instruction: Equatable, Sendable {
    public let pass: RunPass
    public let card: InstructionCard
    public let brief: ArchitecturalBrief
    public let definitionOfDone: [DoDClause]
    public let repository: InstructionRepository
    public let route: Route
    public let payloads: InstructionPayloads
    /// The commit message the worker pass is asked to write; nil omits the section.
    public let commitMessage: CommitMessageRequest?
    /// The absolute path the CLI must write its result file to.
    public let resultFilePath: String

    public init(
        pass: RunPass,
        card: InstructionCard,
        brief: ArchitecturalBrief,
        definitionOfDone: [DoDClause],
        repository: InstructionRepository,
        route: Route,
        payloads: InstructionPayloads,
        commitMessage: CommitMessageRequest? = nil,
        resultFilePath: String
    ) {
        self.pass = pass
        self.card = card
        self.brief = brief
        self.definitionOfDone = definitionOfDone
        self.repository = repository
        self.route = route
        self.payloads = payloads
        self.commitMessage = commitMessage
        self.resultFilePath = resultFilePath
    }
}
