import Domain

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
        /// A Routing Entry for the Kind reserved for the author Act names a Repo Role: the author Act
        /// resolves with no Repo Role, so such an entry could never match.
        case reservedKindNamesRepoRole(kind: String)
        case invalidProjectID(String)
        case projectIDMismatch(fileStem: String)
        case emptyArray
        case duplicateRepo(firstLine: Int)
        case notPositive(Int64)
        case invalidTimeOfDay(String)
        case noSpecificationSource
        case secondSpecificationSource(firstLine: Int)
        case undeclaredCLIAdapter(String)
        case workingRepoConflict(project: ProjectID, file: String)
        /// Two registry entries name one Linear workspace; reported on the second entry's `workspace`.
        case duplicateLinearWorkspace(firstInstallation: String, firstLine: Int)
        /// A Project's `installation` names no `[board.linear.installations.<name>]` in the machine file.
        case undeclaredLinearInstallation(String)
        /// A Message Template names `{name}`, which is not a token of its template. `key` is the
        /// template's own key (`commit_message`); `accepted` lists the tokens it does take.
        case unknownTemplateToken(name: String, key: String, accepted: [String])
        /// A Message Template has a `{` with no closing `}`.
        case unterminatedTemplateBrace(key: String)
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
        case .reservedKindNamesRepoRole(let kind):
            return "Kind \"\(kind)\" is reserved for the author Act, which resolves with no Repo Role; "
                + "remove repo_role (or use \"*\") so the entry can match"
        case .invalidProjectID(let value):
            return "Project ID must contain only letters, digits, underscores, and hyphens, got \"\(value)\""
        case .projectIDMismatch(let fileStem):
            return "Project ID does not match filename; file stem is \"\(fileStem)\""
        case .emptyArray:
            return "array must not be empty"
        case .duplicateRepo(let firstLine):
            return "repo name is already defined on line \(firstLine)"
        case .notPositive(let value):
            return "must be an integer >= 1, got \(value)"
        case .invalidTimeOfDay(let value):
            return "must be in HH:MM format with hours 00-23 and minutes 00-59, got \"\(value)\""
        case .noSpecificationSource:
            return "a Project must declare exactly one specification source: "
                + "a spec_source path or one repo with role \"spec\"; found none"
        case .secondSpecificationSource(let firstLine):
            return "a Project must declare exactly one specification source; "
                + "another is already declared on line \(firstLine)"
        case .undeclaredCLIAdapter(let cli):
            return "route names CLI \"\(cli)\", which has no [cli.\(cli)] adapter declaration"
        case .workingRepoConflict(let project, let file):
            return "repository is also declared as a working Repo by Project \"\(project.rawValue)\" (\(file))"
        case .duplicateLinearWorkspace(let firstInstallation, let firstLine):
            return "workspace is already used by installation \"\(firstInstallation)\" on line \(firstLine); "
                + "a Linear workspace is installed once"
        case .undeclaredLinearInstallation(let name):
            return "Project names installation \"\(name)\", which has no [board.linear.installations.\(name)] "
                + "in the machine file config.toml"
        case .unknownTemplateToken(let name, let key, let accepted):
            return "names {\(name)}, which is not a \(key) token; the tokens are \(accepted.joined(separator: ", "))"
        case .unterminatedTemplateBrace(let key):
            return "has a \"{\" with no closing \"}\"; a \(key) names its tokens as {name}"
        }
    }
}
