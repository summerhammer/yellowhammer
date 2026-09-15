/// A configuration file that could not be read, located by file, line and key.
public struct ConfigurationError: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case unreadable(String)
        case syntax(String)
        case duplicateKey(firstLine: Int)
        case tableRedefined(firstLine: Int)
        case missingTable
        case missingKey
        case unknownKey
        case typeMismatch(expected: String, found: String)
        case emptyString
        case invalidKind(String)
        case invalidRoute(String)
        case duplicateRoutingEntry(firstLine: Int)
    }

    public let file: String
    /// 1-based. A missing key is reported on the line of its enclosing table's header; a missing
    /// top-level table, and a file that cannot be read, on line 1.
    public let line: Int
    /// A dotted and indexed path such as `routing[1].fallbacks[0]`; nil when no key applies.
    public let key: String?
    public let reason: Reason

    public init(file: String, line: Int, key: String?, reason: Reason) {
        self.file = file
        self.line = line
        self.key = key
        self.reason = reason
    }
}

extension ConfigurationError: CustomStringConvertible {
    public var description: String {
        let location = key.map { "\(file):\(line): \($0)" } ?? "\(file):\(line)"
        return "\(location): \(reason)"
    }
}

extension ConfigurationError.Reason: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unreadable(let message):
            return "could not read the file: \(message)"
        case .syntax(let message):
            return message
        case .duplicateKey(let firstLine):
            return "key is already defined on line \(firstLine)"
        case .tableRedefined(let firstLine):
            return "table is already defined on line \(firstLine)"
        case .missingTable:
            return "missing required table"
        case .missingKey:
            return "missing required key"
        case .unknownKey:
            return "unknown key"
        case .typeMismatch(let expected, let found):
            return "expected \(expected), got \(found)"
        case .emptyString:
            return "must not be empty"
        case .invalidKind(let value):
            return "expected \"*\" or a dotted Kind such as \"impl.boilerplate\", got \"\(value)\""
        case .invalidRoute(let value):
            return "expected \"cli/model\" or \"cli/model/effort\", got \"\(value)\""
        case .duplicateRoutingEntry(let firstLine):
            return "a Routing Entry for the same Kind and Repo Role is already defined on line \(firstLine)"
        }
    }
}
