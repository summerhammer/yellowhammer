public enum JournalError: Error, Equatable, CustomStringConvertible {
    case missing(path: String)
    case schemaNewerThanKnown(path: String, unknown: [String])
    case schemaBehind(path: String, pending: [String])

    public var description: String {
        switch self {
        case .missing(let path):
            "Journal not found at \(path)"
        case .schemaNewerThanKnown(let path, let unknown):
            "Journal at \(path) has unknown migrations: \(unknown.joined(separator: ", "))"
        case .schemaBehind(let path, let pending):
            "Journal at \(path) has pending migrations: \(pending.joined(separator: ", "))"
        }
    }
}
