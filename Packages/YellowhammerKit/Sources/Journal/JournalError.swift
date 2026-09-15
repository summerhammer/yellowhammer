import Domain

public enum JournalError: Error, Equatable, CustomStringConvertible {
    case missing(path: String)
    case schemaNewerThanKnown(path: String, unknown: [String])
    case schemaBehind(path: String, pending: [String])
    /// The run no longer holds the Project: its Act-scoped lease expired and was taken, or was released.
    case actLeaseLost(runID: RunID, holder: ActLease?)
    /// The `act_lease` row does not decode; the Journal was written by something other than the engine.
    case actLeaseUnreadable
    /// The event row does not decode; the Journal was written by something other than the engine.
    case eventUnreadable(id: Int64)

    public var description: String {
        switch self {
        case .missing(let path):
            "Journal not found at \(path)"
        case .schemaNewerThanKnown(let path, let unknown):
            "Journal at \(path) has unknown migrations: \(unknown.joined(separator: ", "))"
        case .schemaBehind(let path, let pending):
            "Journal at \(path) has pending migrations: \(pending.joined(separator: ", "))"
        case .actLeaseLost(let runID, let holder):
            if let holder {
                "Run \(runID) no longer holds the Project: "
                    + "run \(holder.runID) holds it for the \(holder.act.rawValue) Act"
            } else {
                "Run \(runID) no longer holds the Project: its lease was released"
            }
        case .actLeaseUnreadable:
            "The Journal's act_lease row cannot be read"
        case .eventUnreadable(let id):
            "The Journal's event row \(id) cannot be read"
        }
    }
}
