public enum LedgerError: Error, Equatable, CustomStringConvertible {
    /// The Ledger file does not exist at the path.
    case missing(path: String)
    /// The Ledger has migrations this build does not know about; a newer build created it.
    case schemaNewerThanKnown(path: String, unknown: [String])
    /// The Ledger has pending migrations; it was not fully migrated before this build opened it.
    case schemaBehind(path: String, pending: [String])
    /// A `probe_result` row does not decode; the Ledger was written by something other than the engine.
    case probeResultUnreadable

    public var description: String {
        return switch self {
        case .missing(let path):
            "Ledger not found at \(path)"
        case .schemaNewerThanKnown(let path, let unknown):
            "Ledger at \(path) has unknown migrations: \(unknown.joined(separator: ", "))"
        case .schemaBehind(let path, let pending):
            "Ledger at \(path) has pending migrations: \(pending.joined(separator: ", "))"
        case .probeResultUnreadable:
            "The Ledger's probe_result row cannot be read"
        }
    }
}
