import Domain

public enum JournalError: Error, Equatable, CustomStringConvertible {
    case missing(path: String)
    /// The Journal carries migrations this build does not know and that may come from a newer build.
    case schemaNewerThanKnown(path: String, unknown: [String])
    /// Every unknown migration is provably older: the retired pre-squash `v<N>-<slug>` chain, or a
    /// lower `journal-schema-<M>`. The Journal must be deleted; the next Act creates a new one.
    case schemaOlderThanKnown(path: String, unknown: [String])
    case schemaBehind(path: String, pending: [String])
    /// The run no longer holds the Project: its Act-scoped lease expired and was taken, or was released.
    case actLeaseLost(runID: RunID, holder: ActLease?)
    /// The `act_lease` row does not decode; the Journal was written by something other than the engine.
    case actLeaseUnreadable
    /// The Journal has no Card with this id.
    case cardUnknown(cardID: Int64)
    /// The run no longer holds this Card: another run holds it, its lease was released, or it expired.
    case cardLeaseLost(cardID: Int64, runID: RunID, holder: CardLease?)
    /// The `lease` row for this Card does not decode; the Journal was written by something other than the engine.
    case cardLeaseUnreadable(cardID: Int64)
    /// The event row does not decode; the Journal was written by something other than the engine.
    case eventUnreadable(id: Int64)
    /// The Card already has an open Attempt; a Card is dispatched once at a time.
    case attemptStillOpen(cardID: Int64, attemptID: Int64)
    /// The Journal has no Attempt with this id.
    case attemptUnknown(attemptID: Int64)
    /// The Attempt already ended; no more Rounds can be recorded on it, and it cannot be ended again.
    case attemptEnded(attemptID: Int64)
    /// The `attempt` row does not decode; the Journal was written by something other than the engine.
    case attemptUnreadable(id: Int64)
    /// The `round` row does not decode; the Journal was written by something other than the engine.
    case roundUnreadable(id: Int64)
    /// A `route_exclusion` row for this Card does not decode; the Journal was written by something other
    /// than the engine.
    case routeExclusionUnreadable(cardID: Int64)
    /// The Journal has no Feature with this id.
    case featureUnknown(featureID: Int64)
    /// The Journal has no Cycle with this id.
    case cycleUnknown(cycleID: Int64)
    /// The Journal has no Worktree with this id.
    case worktreeUnknown(id: Int64)
    /// The Worktree was already released.
    case worktreeReleased(id: Int64)
    /// The Worktree cannot be released because its Feature Branch has not been pushed and that push
    /// recorded: releasing (and so removing) it earlier would ask Orca ADE to discard unpushed work.
    case worktreeNotPushed(id: Int64)
    /// The `worktree` row does not decode; the Journal was written by something other than the engine.
    case worktreeUnreadable(id: Int64)
    /// More than one Cycle is open. A Project has one in-flight Feature, so it has one open Cycle;
    /// two means the Journal is inconsistent and no Act's trigger can be evaluated against it.
    case multipleOpenCycles
    /// A `card` row's state is outside the `CardState` vocabulary. Since only the engine writes it,
    /// the Journal is inconsistent, and a Card nothing can classify must not be silently counted
    /// as finished.
    case unknownCardState(cardID: Int64, state: String)
    /// The Journal has no Night with this id.
    case nightUnknown(id: Int64)
    /// The Night is already closed and cannot be closed again.
    case nightAlreadyClosed(id: Int64)
    /// The `night` row does not decode; the Journal was written by something other than the engine.
    case nightUnreadable(id: Int64)
    /// The Journal has more than one open Night, but there should be at most one.
    case multipleOpenNights
    /// The Night's `night_card_issue_id` already names a different issue: two Night Cards for one
    /// Night, which the Outbox's idempotency is meant to make impossible.
    case nightCardAlreadyRecorded(id: Int64, issueID: String)
    /// The Journal has no Outbox entry with this id.
    case outboxEntryUnknown(id: Int64)
    /// The Outbox entry exists but is not in pending state; state machine leaves pending only once.
    case outboxEntryNotPending(id: Int64, state: OutboxEntryState)
    /// The `outbox` row does not decode; the Journal was written by something other than the engine.
    case outboxEntryUnreadable(id: Int64)
    /// The `card` row does not decode; the Journal was written by something other than the engine.
    case cardUnreadable(id: Int64)
    /// The Card is already in cancelled state and cannot be cancelled again.
    case cardAlreadyCancelled(cardID: Int64)
    /// The Card is not in cancelled state and cannot be reopened.
    case cardNotCancelled(cardID: Int64)
    /// The `board_sync` row does not decode; the Journal was written by something other than the engine.
    case boardSyncUnreadable
    /// The `clause` row does not decode; the Journal was written by something other than the engine.
    case clauseUnreadable(issueID: String, cid: String)
    /// Cancelled is the one Card state Yellowhammer reads and never writes; the Journal refuses it too.
    case cancelledIsNeverWritten(cardID: Int64)
    /// A transition to Waiting on You without a waiting reason: the Journal record is what backs the state.
    case waitingOnYouUnbacked(cardID: Int64)
    /// A transition to Blocked without a Block Reason.
    case blockReasonRequired(cardID: Int64)
    /// The authoring transaction adopts a Card the Journal holds no row for.
    case adoptedCardUnknown(issueID: String)
    /// The `refusal` row does not decode; the Journal was written by something other than the engine.
    case refusalUnreadable(id: Int64)
    /// The Cycle was already landed and cannot be landed again (roadmap P10.1; risks OQ8, once per Cycle).
    case cycleAlreadyLanded(cycleID: Int64)
    /// The `authoring_halt` row does not decode; the Journal was written by something other than the engine.
    case authoringHaltUnreadable(id: Int64)
    /// The `pull_request` row does not decode; the Journal was written by something other than the engine.
    case pullRequestUnreadable(featureID: Int64)
    /// The `feature_verification` row does not decode; the Journal was written by something other than the engine.
    case featureVerificationUnreadable(cycleID: Int64)
    /// The `card_reply` row does not decode; the Journal was written by something other than the engine.
    case cardReplyUnreadable(id: Int64)
    /// Banking (``JournalStore/bankCardReply(id:stamps:nightID:act:runID:now:)``) was attempted against
    /// a reply whose disposition is not `answer` (roadmap P11.3): only an answer is ever banked.
    case cardReplyNotAnswer(id: Int64)
    /// Explicit Project removal (roadmap P13.5; spec risks OQ52(1)) was refused: an Act of this Project
    /// holds an active Act Lease, so removal wrote nothing.
    case projectRemovalRefused(holder: ActLease)

    public var description: String {
        return switch self {
        case .missing(let path):
            "Journal not found at \(path)"
        case .schemaNewerThanKnown(let path, let unknown):
            "Journal at \(path) was created by a newer build of Yellowhammer " +
                "(unknown migrations: \(unknown.joined(separator: ", "))). Update Yellowhammer to read it."
        case .schemaOlderThanKnown(let path, _):
            "Journal at \(path) was created by an earlier build of Yellowhammer, and this build cannot read it. " +
                "Delete it; the next Act creates a new one."
        case .schemaBehind(let path, let pending):
            "Journal at \(path) has pending migrations: \(pending.joined(separator: ", "))"
        case .actLeaseLost(let runID, let holder):
            holder.map { heldBy in
                heldBy.runID == runID
                    ? "Run \(runID) no longer holds the Project: its lease expired at " +
                        "\(JournalStore.timestamp(heldBy.expiresAt))"
                    : ("Run \(runID) no longer holds the Project: run \(heldBy.runID) " +
                        "holds it for the \(heldBy.act.rawValue) Act")
            } ?? "Run \(runID) no longer holds the Project: its lease was released"
        case .actLeaseUnreadable:
            "The Journal's act_lease row cannot be read"
        case .cardUnknown(let cardID):
            "The Journal has no Card with id \(cardID)"
        case .cardLeaseLost(let cardID, let runID, let holder):
            holder.map { heldBy in
                heldBy.runID == runID
                    ? "Run \(runID) no longer holds Card \(cardID): its lease expired at " +
                        "\(JournalStore.timestamp(heldBy.expiresAt))"
                    : "Run \(runID) no longer holds Card \(cardID): run \(heldBy.runID) holds it"
            } ?? "Run \(runID) no longer holds Card \(cardID): its lease was released"
        case .cardLeaseUnreadable(let cardID):
            "The Journal's lease row for Card \(cardID) cannot be read"
        case .eventUnreadable(let id):
            "The Journal's event row \(id) cannot be read"
        case .attemptStillOpen(let cardID, let attemptID):
            "Card \(cardID) already has an open Attempt (\(attemptID)): a Card is dispatched once at a time"
        case .attemptUnknown(let attemptID):
            "The Journal has no Attempt with id \(attemptID)"
        case .attemptEnded(let attemptID):
            "Attempt \(attemptID) has already ended"
        case .attemptUnreadable(let id):
            "The Journal's attempt row \(id) cannot be read"
        case .roundUnreadable(let id):
            "The Journal's round row \(id) cannot be read"
        case .routeExclusionUnreadable(let cardID):
            "A route_exclusion row for Card \(cardID) cannot be read"
        case .featureUnknown(let featureID):
            "The Journal has no Feature with id \(featureID)"
        case .cycleUnknown(let cycleID):
            "The Journal has no Cycle with id \(cycleID)"
        case .worktreeUnknown(let id):
            "The Journal has no Worktree with id \(id)"
        case .worktreeReleased(let id):
            "Worktree \(id) was already released"
        case .worktreeNotPushed(let id):
            "Worktree \(id) cannot be released: its Feature Branch has not been pushed"
        case .worktreeUnreadable(let id):
            "The Journal's worktree row \(id) cannot be read"
        case .multipleOpenCycles:
            "The Journal has more than one open Cycle, but a Project has one in-flight Feature"
        case .unknownCardState(let cardID, let state):
            "The Journal's card row \(cardID) has state '\(state)', which is not a Card state"
        case .nightUnknown(let id):
            "The Journal has no Night with id \(id)"
        case .nightAlreadyClosed(let id):
            "Night \(id) is already closed and cannot be closed again"
        case .nightUnreadable(let id):
            "The Journal's night row \(id) cannot be read"
        case .multipleOpenNights:
            "The Journal has more than one open Night, but there should be at most one"
        case .nightCardAlreadyRecorded(let id, let issueID):
            "Night \(id) already has a Night Card recorded, which is not \(issueID)"
        case .outboxEntryUnknown(let id):
            "The Journal has no Outbox entry with id \(id)"
        case .outboxEntryNotPending(let id, let state):
            "Outbox entry \(id) is in state \(state.rawValue), not pending"
        case .outboxEntryUnreadable(let id):
            "The Journal's outbox row \(id) cannot be read"
        case .cardUnreadable(let id):
            "The Journal's card row \(id) cannot be read"
        case .cardAlreadyCancelled(let cardID):
            "Card \(cardID) is already cancelled and cannot be cancelled again"
        case .cardNotCancelled(let cardID):
            "Card \(cardID) is not cancelled and cannot be reopened"
        case .boardSyncUnreadable:
            "The Journal's board_sync row cannot be read"
        case .clauseUnreadable(let issueID, let cid):
            "The Journal's clause row (issue_id=\(issueID), cid=\(cid)) cannot be read"
        case .cancelledIsNeverWritten(let cardID):
            "Card \(cardID) cannot be transitioned to Cancelled: Yellowhammer reads it and never writes it"
        case .waitingOnYouUnbacked(let cardID):
            "Card \(cardID) cannot transition to Waiting on You without a waiting reason"
        case .blockReasonRequired(let cardID):
            "Card \(cardID) cannot transition to Blocked without a Block Reason"
        case .adoptedCardUnknown(let issueID):
            "The Journal has no Card row for adopted issue \(issueID)"
        case .refusalUnreadable(let id):
            "The Journal's refusal row \(id) cannot be read"
        case .cycleAlreadyLanded(let cycleID):
            "Cycle \(cycleID) is already landed and cannot be landed again"
        case .authoringHaltUnreadable(let id):
            "The Journal's authoring halt row \(id) cannot be read"
        case .pullRequestUnreadable(let featureID):
            "The Journal's pull request row for Feature \(featureID) cannot be read"
        case .featureVerificationUnreadable(let cycleID):
            "The Journal's verification row for Cycle \(cycleID) cannot be read"
        case .cardReplyUnreadable(let id):
            "The Journal's card_reply row \(id) cannot be read"
        case .cardReplyNotAnswer(let id):
            "Card reply \(id) is not an answer and cannot be banked"
        case .projectRemovalRefused(let holder):
            "Project removal refused: run \(holder.runID) holds the Act Lease for the \(holder.act.rawValue) Act " +
                "until \(JournalStore.timestamp(holder.expiresAt))"
        }
    }
}
