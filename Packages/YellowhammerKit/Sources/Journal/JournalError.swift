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
        }
    }
}
