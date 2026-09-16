import Domain

public enum JournalError: Error, Equatable, CustomStringConvertible {
    case missing(path: String)
    case schemaNewerThanKnown(path: String, unknown: [String])
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
    /// The Journal has no Worktree with this id.
    case worktreeUnknown(id: Int64)
    /// The Worktree was already released.
    case worktreeReleased(id: Int64)
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
    /// The Journal has no Outbox entry with this id.
    case outboxEntryUnknown(id: Int64)
    /// The Outbox entry exists but is not in pending state; state machine leaves pending only once.
    case outboxEntryNotPending(id: Int64, state: OutboxEntryState)
    /// The `outbox` row does not decode; the Journal was written by something other than the engine.
    case outboxEntryUnreadable(id: Int64)

    public var description: String {
        return switch self {
        case .missing(let path):
            "Journal not found at \(path)"
        case .schemaNewerThanKnown(let path, let unknown):
            "Journal at \(path) has unknown migrations: \(unknown.joined(separator: ", "))"
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
        case .worktreeUnknown(let id):
            "The Journal has no Worktree with id \(id)"
        case .worktreeReleased(let id):
            "Worktree \(id) was already released"
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
        case .outboxEntryUnknown(let id):
            "The Journal has no Outbox entry with id \(id)"
        case .outboxEntryNotPending(let id, let state):
            "Outbox entry \(id) is in state \(state.rawValue), not pending"
        case .outboxEntryUnreadable(let id):
            "The Journal's outbox row \(id) cannot be read"
        }
    }
}
