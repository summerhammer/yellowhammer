import Domain
import Foundation

// MARK: - Card Record

public enum WaitingReason: String, Sendable { case question, divergence, overreach }

/// How the Operator removed a Work Card's issue from the board (OQ142): trashed, or archived while
/// the Card was in play. Orthogonal to ``CardState``: a removed Card keeps the state it stood in.
public enum CardRemoval: String, Sendable { case trashed, archived }

public struct CardRecord: Equatable, Sendable {
    public let id: Int64
    public let cycleID: Int64
    public let issueID: String
    /// The Card issue's human-readable identifier (e.g. `ARC-11`), recorded for display.
    public internal(set) var issueIDForDisplay: String?
    /// The board's title for this Card, nil until the Delta Read first reconciles it (a Card has no
    /// recorded title until then). Renders the Roll-up and the partial-landing PR body's
    /// hole listing; ``displayTitle`` falls back to the issue id when this is nil or empty.
    public let title: String?
    public let repository: String
    public let kind: String
    public let authoredOrder: Int
    public let state: CardState
    public let waitingReason: WaitingReason?
    public let blockReason: String?
    /// The state the Card held before the board said Shelved; nil unless state is shelved.
    public let shelvedFromState: CardState?
    /// Bumped by ``JournalStore/resetBudgetEpoch(cardID:reason:runID:act:nightID:now:)`` when an
    /// Override pinned in triage supersedes the exclusions an earlier epoch recorded
    /// (routing/exclude-tried-routes-on-retry, P7.7).
    public let budgetEpoch: Int
    public let createdAt: Date
    /// Bumped by every Journal-side state transition (``JournalStore/transitionCard(cardID:to:waitingReason:blockReason:runID:act:nightID:now:)``).
    public let stateVersion: Int
    /// The version of `stateVersion` last confirmed applied on the board; nil until the first confirmed write.
    public let boardStateVersion: Int?
    /// The unanswered-Nights clock (bounds/bound-unanswered-nights, roadmap P11.4): how many Nights this
    /// Card has been in Waiting on You without an answer, counted only across Nights an Act actually ran.
    public let unansweredNights: Int
    /// The Night this clock last counted, so a second Act of the same Night adds nothing; nil until the
    /// first advance after the Card most recently entered Waiting on You.
    public let unansweredLastCountedNightID: Int64?
    /// How many Adoptions this Card has failed consecutively (roadmap P11.5; spec: feature-authoring/
    /// author-the-cycle-and-card-dag, second story): reset to 0 by a clean Adoption. The Divergence
    /// promotion Bound (roadmap P11.6; bounds/overview) promotes this Card to a standing
    /// item once this count exceeds `failed_adoptions_max`.
    public let failedAdoptions: Int
    /// The Night this Card's `failed_adoptions` first exceeded `failed_adoptions_max` (roadmap P11.6):
    /// visibility only, never a state, counter or budget change — nil until promoted, cleared by every
    /// reset of `failed_adoptions` so a fresh count starts unpromoted.
    public let divergenceStandingNightID: Int64?
    /// The Card issue's Linear `identifier` (e.g. `YH-142`), recorded by the Delta Read; nil until then
    /// (issue #230). Declared last, with a default, so a memberwise init need not name it.
    public internal(set) var issueKey: String?
    /// The Card issue's board URL as Linear gave it, recorded with ``issueKey``; nil until then.
    public internal(set) var issueURL: String?
    /// Set while the Card's issue is trashed, or archived while the Card was in play (OQ142): the Card
    /// is set aside — not work, not destroyed, and nothing is posted to it — until the board restores
    /// the issue, which clears this and leaves every other column as it stood.
    public internal(set) var removedFromBoard: CardRemoval?

    public init(
        id: Int64,
        cycleID: Int64,
        issueID: String,
        issueIDForDisplay: String? = nil,
        title: String?,
        repository: String,
        kind: String,
        authoredOrder: Int,
        state: CardState,
        waitingReason: WaitingReason?,
        blockReason: String?,
        shelvedFromState: CardState?,
        budgetEpoch: Int,
        createdAt: Date,
        stateVersion: Int,
        boardStateVersion: Int?,
        unansweredNights: Int,
        unansweredLastCountedNightID: Int64?,
        failedAdoptions: Int,
        divergenceStandingNightID: Int64?,
        issueKey: String? = nil,
        issueURL: String? = nil,
        removedFromBoard: CardRemoval? = nil
    ) {
        self.id = id
        self.cycleID = cycleID
        self.issueID = issueID
        self.issueIDForDisplay = issueIDForDisplay
        self.title = title
        self.repository = repository
        self.kind = kind
        self.authoredOrder = authoredOrder
        self.state = state
        self.waitingReason = waitingReason
        self.blockReason = blockReason
        self.shelvedFromState = shelvedFromState
        self.budgetEpoch = budgetEpoch
        self.createdAt = createdAt
        self.stateVersion = stateVersion
        self.boardStateVersion = boardStateVersion
        self.unansweredNights = unansweredNights
        self.unansweredLastCountedNightID = unansweredLastCountedNightID
        self.failedAdoptions = failedAdoptions
        self.divergenceStandingNightID = divergenceStandingNightID
        self.issueKey = issueKey
        self.issueURL = issueURL
        self.removedFromBoard = removedFromBoard
    }

    public init(
        id: Int64,
        cycleID: Int64,
        issueID: String,
        title: String?,
        repository: String,
        kind: String,
        authoredOrder: Int,
        state: CardState,
        waitingReason: WaitingReason?,
        blockReason: String?,
        shelvedFromState: CardState?,
        budgetEpoch: Int,
        createdAt: Date,
        stateVersion: Int,
        boardStateVersion: Int?,
        unansweredNights: Int,
        unansweredLastCountedNightID: Int64?,
        failedAdoptions: Int,
        divergenceStandingNightID: Int64?,
        issueKey: String? = nil,
        issueURL: String? = nil,
        removedFromBoard: CardRemoval? = nil
    ) {
        self.init(
            id: id,
            cycleID: cycleID,
            issueID: issueID,
            issueIDForDisplay: nil,
            title: title,
            repository: repository,
            kind: kind,
            authoredOrder: authoredOrder,
            state: state,
            waitingReason: waitingReason,
            blockReason: blockReason,
            shelvedFromState: shelvedFromState,
            budgetEpoch: budgetEpoch,
            createdAt: createdAt,
            stateVersion: stateVersion,
            boardStateVersion: boardStateVersion,
            unansweredNights: unansweredNights,
            unansweredLastCountedNightID: unansweredLastCountedNightID,
            failedAdoptions: failedAdoptions,
            divergenceStandingNightID: divergenceStandingNightID,
            issueKey: issueKey,
            issueURL: issueURL,
            removedFromBoard: removedFromBoard
        )
    }

    /// The Card's title, or its display id / issue id when no title is recorded yet (not yet reconciled against
    /// the board). What the Roll-up and the partial-landing PR body name a
    /// Card by (issue #161; spec: landing/announce-a-partial-landing).
    public var isRemovedFromBoard: Bool {
        removedFromBoard != nil
    }

    public var displayTitle: String {
        guard let title, !title.isEmpty else { return issueIDForDisplay ?? issueID }
        return title
    }

    /// The Card's display identifier (e.g. `YLH-326`), falling back to `displayTitle` when unknown.
    public var displayIdentifier: String {
        if let id = issueIDForDisplay, !id.isEmpty { return id }
        if let key = issueKey, !key.isEmpty { return key }
        return displayTitle
    }

    /// Renders the Card as a Markdown link to `issueURL` when recorded, or as `displayIdentifier`.
    public var displayLink: String {
        let text = displayIdentifier
        if let issueURL, !issueURL.isEmpty {
            return "[\(text)](\(issueURL))"
        }
        return text
    }
}

// MARK: - CardRecord helpers

extension CardRecord {
    func with(removedFromBoard: CardRemoval?) -> CardRecord {
        var record = self
        record.removedFromBoard = removedFromBoard
        return record
    }

    func with(state: CardState, shelvedFromState: CardState?) -> CardRecord {
        CardRecord(
            id: id,
            cycleID: cycleID,
            issueID: issueID,
            issueIDForDisplay: issueIDForDisplay,
            title: title,
            repository: repository,
            kind: kind,
            authoredOrder: authoredOrder,
            state: state,
            waitingReason: waitingReason,
            blockReason: blockReason,
            shelvedFromState: shelvedFromState,
            budgetEpoch: budgetEpoch,
            createdAt: createdAt,
            stateVersion: stateVersion,
            boardStateVersion: boardStateVersion,
            unansweredNights: unansweredNights,
            unansweredLastCountedNightID: unansweredLastCountedNightID,
            failedAdoptions: failedAdoptions,
            divergenceStandingNightID: divergenceStandingNightID,
            issueKey: issueKey,
            issueURL: issueURL,
            removedFromBoard: removedFromBoard
        )
    }
}
