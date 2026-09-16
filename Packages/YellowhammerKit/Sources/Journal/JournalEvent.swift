import Domain
import Foundation

/// One entry of the Project's append-only event log, typed so that the spec's vocabulary is the code's.
public enum JournalEvent: Equatable, Sendable {
    case actStarted
    case actEnded
    /// The Act's trigger predicate was false; it recorded an idle tick and exited normally.
    case actIdle(reason: ActIdleReason)
    /// The Act could not complete; `reason` is what it knew when it gave up.
    case actIncomplete(reason: String)
    /// Another run of the same Project held the Act-scoped lease; this Act ran nothing.
    case actStoodDown(holder: ActLease)
    case mainlineFetchFailed(repository: String, reason: String)
    /// The resumption self-audit found a Night that never opened (OQ12): a calendar date
    /// between two recorded Nights with no Night row. Recorded on the Night that resumed, by its
    /// first Act. Reported, never acted on — `unanswered_nights_max` is spent only by Nights that ran.
    case absentNightDetected(nightStart: NightStart)
    case authoringNoWorkAvailable
    case managedBlockDelimiterBroken(issueID: String)
    /// Fire-and-forget: the failure is recorded, never acted on.
    case notificationDeliveryFailed(notification: String, reason: String)
    /// The board's request budget was exhausted and the Act did less work. The budget is the
    /// identity's, shared by every Project running that night, so the record names it workspace-wide
    /// and never attributes the exhaustion to this Project's own reads.
    case rateBudgetExhausted(degradation: String)
    /// An expired Act-scoped lease was taken over by a new run: the previous run crashed or slept past its TTL.
    case leaseReclaimed(previousRunID: RunID, previousAct: Act, expiredAt: Date)
    /// An expired Card-scoped lease was taken over by a new run: the previous run crashed or slept past its TTL.
    case cardLeaseReclaimed(cardID: Int64, previousRunID: RunID, expiredAt: Date)
    /// The first Act of the Night recorded it, before any work.
    case nightOpened
    /// The Night closed, with the reason it closed.
    case nightClosed(reason: NightCloseReason)
    /// This Project's previous Night was left open with no completion: it opened and died. Recorded
    /// on the next Night, by its first Act, which is the only thing alive to draw the conclusion.
    case nightOpenedAndDied(nightID: Int64, nightStart: NightStart)
    /// The SHA-256 of the human prose outside the delimiters, recorded for provenance on every
    /// description write.
    case managedBlockWritten(issueID: String, preservedProseHash: String, renderedHash: String)
    /// The first Act of the Night created that Project's Night Card, before any work (DR7).
    case nightCardOpened(issueID: String)
    /// The land firing at `night_end` completed the Night Card with the Night Summary.
    case nightCardCompleted(issueID: String)
    /// A permanent board write failure, surfaced in the Night Summary because a silent projection
    /// failure makes every other guarantee unreadable.
    case boardWriteFailed(clientID: UUID, operation: String, issueID: String?, reason: String)
    /// An all-or-nothing group of writes (the authoring transaction) failed part-way and its applied
    /// creates were archived.
    case outboxGroupRolledBack(groupID: String, reason: String)
    /// The board read the Card as Cancelled; the Journal records its previous state for reopening.
    case cardCancelled(cardID: Int64, issueID: String, previousState: CardState)
    /// The board read a Journal-cancelled Card as reopened; the Journal restores its previous state.
    case cardReopened(cardID: Int64, issueID: String, restoredState: CardState)
    /// The board moved a Card to a state the Journal did not write; the Journal stays authoritative
    /// and records the discrepancy.
    case cardRestated(cardID: Int64, issueID: String, journalState: CardState, boardState: String)
    /// The board no longer lists this Card; the Journal records how it was removed.
    case cardRemovedFromBoard(cardID: Int64, issueID: String, how: String)
    /// A Card violates an invariant that must hold for authoring to proceed; the Journal records
    /// what broke so no Act blindly retries.
    case authoringInvariantBroken(cardID: Int64, issueID: String, reason: String)
    /// A Delta Read completed, reporting object counts and the sync point it reads next.
    case deltaReadCompleted(
        objects: Int, comments: Int, ownComments: Int, requests: Int,
        since: Date?, syncPoint: Date?
    )
    /// A Journal-side Card state transition (roadmap P5.8): the state, waiting reason and block reason
    /// the Card holds after it, bumping `card.state_version` in the same write.
    case cardStateTransitioned(
        cardID: Int64, issueID: String, from: CardState, to: CardState,
        waitingReason: WaitingReason?, blockReason: BlockReason?
    )
    /// The Delta Read found a Card in Waiting on You with no Journal record behind it: an unknown
    /// object labelled Card, or a known Card whose Journal state is Waiting on You with no waiting
    /// reason recorded. Never dispatched.
    case waitingOnYouUnbacked(issueID: String, cardID: Int64?, reason: String)

    /// The type of this event.
    public var type: JournalEventType {
        switch self {
        case .actStarted:
            .actStarted
        case .actEnded:
            .actEnded
        case .actIdle:
            .actIdle
        case .actIncomplete:
            .actIncomplete
        case .actStoodDown:
            .actStoodDown
        case .mainlineFetchFailed:
            .mainlineFetchFailed
        case .absentNightDetected:
            .absentNightDetected
        case .authoringNoWorkAvailable:
            .authoringNoWorkAvailable
        case .managedBlockDelimiterBroken:
            .managedBlockDelimiterBroken
        case .notificationDeliveryFailed:
            .notificationDeliveryFailed
        case .rateBudgetExhausted:
            .rateBudgetExhausted
        case .leaseReclaimed:
            .leaseReclaimed
        case .cardLeaseReclaimed:
            .cardLeaseReclaimed
        case .nightOpened:
            .nightOpened
        case .nightClosed:
            .nightClosed
        case .nightOpenedAndDied:
            .nightOpenedAndDied
        case .managedBlockWritten:
            .managedBlockWritten
        case .nightCardOpened:
            .nightCardOpened
        case .nightCardCompleted:
            .nightCardCompleted
        case .boardWriteFailed:
            .boardWriteFailed
        case .outboxGroupRolledBack:
            .outboxGroupRolledBack
        case .cardCancelled:
            .cardCancelled
        case .cardReopened:
            .cardReopened
        case .cardRestated:
            .cardRestated
        case .cardRemovedFromBoard:
            .cardRemovedFromBoard
        case .authoringInvariantBroken:
            .authoringInvariantBroken
        case .deltaReadCompleted:
            .deltaReadCompleted
        case .cardStateTransitioned:
            .cardStateTransitioned
        case .waitingOnYouUnbacked:
            .waitingOnYouUnbacked
        }
    }
}

/// The type of a JournalEvent, with raw values matching the spec's PascalCase names.
public enum JournalEventType: String, CaseIterable, Sendable {
    case actStarted = "ActStarted"
    case actEnded = "ActEnded"
    case actIdle = "ActIdle"
    case actIncomplete = "ActIncomplete"
    case actStoodDown = "ActStoodDown"
    case mainlineFetchFailed = "MainlineFetchFailed"
    case absentNightDetected = "AbsentNightDetected"
    case authoringNoWorkAvailable = "AuthoringNoWorkAvailable"
    case managedBlockDelimiterBroken = "ManagedBlockDelimiterBroken"
    case notificationDeliveryFailed = "NotificationDeliveryFailed"
    case rateBudgetExhausted = "RateBudgetExhausted"
    case leaseReclaimed = "LeaseReclaimed"
    case cardLeaseReclaimed = "CardLeaseReclaimed"
    case nightOpened = "NightOpened"
    case nightClosed = "NightClosed"
    case nightOpenedAndDied = "NightOpenedAndDied"
    case managedBlockWritten = "ManagedBlockWritten"
    case nightCardOpened = "NightCardOpened"
    case nightCardCompleted = "NightCardCompleted"
    case boardWriteFailed = "BoardWriteFailed"
    case outboxGroupRolledBack = "OutboxGroupRolledBack"
    case cardCancelled = "CardCancelled"
    case cardReopened = "CardReopened"
    case cardRestated = "CardRestated"
    case cardRemovedFromBoard = "CardRemovedFromBoard"
    case authoringInvariantBroken = "AuthoringInvariantBroken"
    case deltaReadCompleted = "DeltaReadCompleted"
    case cardStateTransitioned = "CardStateTransitioned"
    case waitingOnYouUnbacked = "WaitingOnYouUnbacked"
}
