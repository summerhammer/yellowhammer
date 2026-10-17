import Domain
import Foundation

/// Needs you: the Project's decision Cards, Blocked and Waiting on You alike, and a Feature returned to the
/// Operator with unmet clauses (verification/return-a-feature-with-unmet-clauses), which is in the same
/// disposition as a Work Card that needs them.
public struct NeedsYou: Equatable, Sendable {
    public var cards: [DecisionCard]
    /// The in-flight Feature when its state is `returned`; nil otherwise.
    public var returnedFeature: ReturnedFeature?

    public init(cards: [DecisionCard], returnedFeature: ReturnedFeature? = nil) {
        self.cards = cards
        self.returnedFeature = returnedFeature
    }

    /// Waiting on You Cards, plus the returned Feature, which is Waiting on You too.
    public var waitingOnYouCount: Int {
        cards.count { $0.state == .waitingOnYou } + (returnedFeature == nil ? 0 : 1)
    }

    /// Whether nothing needs the Operator: no decision Card and no returned Feature.
    public var isEmpty: Bool {
        cards.isEmpty && returnedFeature == nil
    }

    /// Everything that needs the Operator: the decision Cards and the returned Feature.
    public var count: Int {
        cards.count + (returnedFeature == nil ? 0 : 1)
    }

    /// Blocked Cards counted by Block Reason, most frequent first.
    public var blockReasonCounts: [(reason: BlockReason, count: Int)] {
        let reasons = cards.compactMap(\.blockReason)
        return BlockReason.allCases
            .compactMap { reason in
                let tally = reasons.count { $0 == reason }
                return tally > 0 ? (reason: reason, count: tally) : nil
            }
            .sorted { $0.count > $1.count }
    }
}

/// A Card that needs a decision, opened in one hop into the Inspector.
public struct DecisionCard: Identifiable, Equatable, Sendable {
    /// The Linear issue id, as the Journal records it.
    public let id: String
    /// The readable issue identifier (e.g. `ENG-123`), recorded for display.
    public var issueIDForDisplay: String?
    public var title: String
    /// `.blocked` or `.waitingOnYou`.
    public var state: CardState
    /// Set only when `state` is `.blocked`.
    public var blockReason: BlockReason?
    public var repo: String
    /// The Card's Linear issue; nil until the Delta Read has recorded its identifier and URL.
    public var link: LinearIssueLink?

    public init(
        id: String,
        issueIDForDisplay: String? = nil,
        title: String,
        state: CardState,
        blockReason: BlockReason?,
        repo: String,
        link: LinearIssueLink? = nil
    ) {
        self.id = id
        self.issueIDForDisplay = issueIDForDisplay
        self.title = title
        self.state = state
        self.blockReason = blockReason
        self.repo = repo
        self.link = link
    }

    public init(
        id: String,
        title: String,
        state: CardState,
        blockReason: BlockReason?,
        repo: String,
        link: LinearIssueLink? = nil
    ) {
        self.init(
            id: id,
            issueIDForDisplay: nil,
            title: title,
            state: state,
            blockReason: blockReason,
            repo: repo,
            link: link
        )
    }
}

/// A Feature returned to the Operator because its Verification left clauses unmet, unresolved or not checked.
public struct ReturnedFeature: Identifiable, Equatable, Sendable {
    /// The Feature Issue's Linear issue id, as the Journal records it.
    public let id: String
    /// The Feature Issue's readable identifier (e.g. `YLH-347`), recorded for display.
    public var issueIDForDisplay: String?
    /// The clause verdicts of the Verification that returned it; nil when none is recorded.
    public var verification: VerificationCounts?
    /// The Feature Issue; nil until the Delta Read has recorded its identifier and URL.
    public var link: LinearIssueLink?

    public init(
        id: String,
        issueIDForDisplay: String? = nil,
        verification: VerificationCounts? = nil,
        link: LinearIssueLink? = nil
    ) {
        self.id = id
        self.issueIDForDisplay = issueIDForDisplay
        self.verification = verification
        self.link = link
    }
}

/// How many of a Feature's Definition of Done clauses a Verification judged met, unmet, unresolved and not checked.
public struct VerificationCounts: Equatable, Sendable {
    public var met: Int
    public var unmet: Int
    public var unresolved: Int
    public var notChecked: Int

    public var total: Int { met + unmet + unresolved + notChecked }

    public init(met: Int, unmet: Int, unresolved: Int, notChecked: Int = 0) {
        self.met = met
        self.unmet = unmet
        self.unresolved = unresolved
        self.notChecked = notChecked
    }
}
