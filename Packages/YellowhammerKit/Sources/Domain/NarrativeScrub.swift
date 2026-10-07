import Foundation

/// The one scrub every outbound narrative passes before it reaches Linear or GitHub (spec rulings
/// OQ146 and OQ147): Outbox comments and pull request text alike.
///
/// This is a floor, not a guarantee. It matches the credentials Yellowhammer holds *by value*, it
/// keeps no secret-pattern list, and it does not claim to be complete. Other secrets quoted from
/// Check output or agent reports (`.env` values, API keys in logs) can still reach Linear and GitHub
/// — that residual risk is R23, and OQ146/OQ147 accept it by name.
///
/// One pass, in this order:
/// 1. Each held credential value becomes `<redacted>`, wherever it appears and whatever surrounds it.
/// 2. A line shaped like an environment assignment (`NAME=value`, optionally `export `-prefixed) has
///    its value replaced. This is a shape rule, not a list of secret patterns.
/// 3. An absolute path under the home directory is trimmed to repo-relative (against a declared
///    repository root, else the nearest ancestor holding a `.git` entry, which covers Worktrees),
///    or else its home prefix becomes `~`, so posted text never names the Operator's home.
public struct NarrativeScrub: Sendable, Equatable {
    /// The marker that replaces a redacted value.
    public static let marker = "<redacted>"

    /// No scrubbing configured: ``apply(_:)`` returns its input unchanged.
    public static let none = NarrativeScrub()

    /// Credential values Yellowhammer holds (the Board Connection token pair, the GitHub credential),
    /// matched by value. Empty strings are ignored.
    public var credentials: [String]
    /// The absolute home path, such as `/Users/alice`. When nil, no path trimming happens.
    public var homeDirectory: String?
    /// Absolute paths of the declared working repositories, already tilde-expanded.
    public var repositoryRoots: [String]

    public init(credentials: [String] = [], homeDirectory: String? = nil, repositoryRoots: [String] = []) {
        self.credentials = credentials
        self.homeDirectory = homeDirectory
        self.repositoryRoots = repositoryRoots
    }

    /// `text` with the held credentials, environment values and home paths scrubbed.
    public func apply(_ text: String) -> String {
        var result = redactCredentials(in: text)
        result = redactEnvironmentValues(in: result)
        return trimHomePaths(in: result)
    }

    // MARK: Credentials

    private func redactCredentials(in text: String) -> String {
        let longestFirst = credentials.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        return longestFirst.reduce(text) { $0.replacingOccurrences(of: $1, with: Self.marker) }
    }

    // MARK: Environment assignments

    private static let environmentLine = try? NSRegularExpression(
        pattern: #"^([ \t]*(?:export[ \t]+)?[A-Z_][A-Z0-9_]*=).*$"#,
        options: [.anchorsMatchLines]
    )

    private func redactEnvironmentValues(in text: String) -> String {
        guard let regex = Self.environmentLine else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let template = "$1" + NSRegularExpression.escapedTemplate(for: Self.marker)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    // MARK: Home paths

    private static let terminators = #"\s'"`\)\]>,;:"#

    private func trimHomePaths(in text: String) -> String {
        guard let home = normalizedHome else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: home)
        let stops = Self.terminators
        let pattern = "(?<![\\w.~-])" + escaped + "(?=/|[" + stops + "]|$)(?:/[^" + stops + "]*)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let roots = repositoryRoots.compactMap(Self.stripTrailingSlash).sorted { $0.count > $1.count }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let path = String(result[range])
            result.replaceSubrange(range, with: trimmed(path, home: home, roots: roots))
        }
        return result
    }

    private var normalizedHome: String? {
        homeDirectory.flatMap(Self.stripTrailingSlash)
    }

    /// `path` without a trailing slash; nil for an empty or root-only path, which names nothing to trim.
    private static func stripTrailingSlash(_ path: String) -> String? {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }

    private func trimmed(_ path: String, home: String, roots: [String]) -> String {
        if let root = roots.first(where: { Self.isWithin(path, directory: $0) }) {
            return Self.relative(path, to: root)
        }
        if let repository = gitAncestor(of: path, home: home) {
            return Self.relative(path, to: repository)
        }
        return "~" + path.dropFirst(home.count)
    }

    private static func isWithin(_ path: String, directory: String) -> Bool {
        path == directory || path.hasPrefix(directory + "/")
    }

    private static func relative(_ path: String, to directory: String) -> String {
        path == directory ? "." : String(path.dropFirst(directory.count + 1))
    }

    /// The nearest directory at or above `path`, below the home directory, that holds a `.git` entry
    /// (a directory, or a file as in a git worktree).
    private func gitAncestor(of path: String, home: String) -> String? {
        var directory = path
        while directory.count > home.count, directory.hasPrefix(home + "/") {
            if FileManager.default.fileExists(atPath: directory + "/.git") {
                return directory
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }
}
