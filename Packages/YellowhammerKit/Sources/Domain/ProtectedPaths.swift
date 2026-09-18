import Foundation

/// Matches a Card's declared scope against a repository's configured protected paths, for the
/// pre-dispatch refusal (bounds/refuse-protected-paths-before-dispatch, roadmap P8.3).
public enum ProtectedPaths {
    /// The limitation every user-facing description of Protected Paths must state (spec R3).
    public static let limitation = "Protected Paths is a scoping check, not a sandbox: the refusal " +
        "happens before dispatch, and nothing prevents a dispatched agent from touching a protected " +
        "path during its run."

    /// A declared scope path that falls under a repository's protected path.
    public struct Match: Equatable, Sendable {
        public let declaredPath: String
        public let protectedPath: String

        public init(declaredPath: String, protectedPath: String) {
            self.declaredPath = declaredPath
            self.protectedPath = protectedPath
        }
    }

    /// The first match between a Card's declared scope and a repository's protected paths, in
    /// declared-scope order then protected-path order, or nil when none match.
    ///
    /// Paths are normalised (trimmed; a leading "./" or "/" and a trailing "/" stripped; repeated "/"
    /// collapsed) and compared component-wise: either path's components must be a prefix of the
    /// other's. Matching is case-sensitive; empty or blank entries on either side never match.
    public static func match(declaredScope: [String], protectedPaths: [String]) -> Match? {
        for declared in declaredScope {
            guard let declaredComponents = normalizedComponents(declared) else { continue }
            for protectedPath in protectedPaths {
                guard let protectedComponents = normalizedComponents(protectedPath) else { continue }
                if isPrefix(declaredComponents, of: protectedComponents)
                    || isPrefix(protectedComponents, of: declaredComponents) {
                    return Match(declaredPath: declared, protectedPath: protectedPath)
                }
            }
        }
        return nil
    }

    private static func isPrefix(_ prefix: [String], of other: [String]) -> Bool {
        guard prefix.count <= other.count else { return false }
        return Array(other[0..<prefix.count]) == prefix
    }

    private static func normalizedComponents(_ path: String) -> [String]? {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("./") {
            trimmed.removeFirst(2)
        }
        while trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return components.isEmpty ? nil : components
    }
}
