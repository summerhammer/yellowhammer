import Foundation

/// A reference from a Definition of Done clause to a specific, addressable location in the specification:
/// a story ID (`<epic>/<story>`) or a goal ID (`G1`..`GN` / anchor `{#...}` / slug).
public struct SpecCitation: Equatable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public var description: String { rawValue }

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(rawValue: String) {
        self.init(rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// The epic of a story ID citation (`<epic>/<story>`); nil for anything else (a goal ID, an anchor
    /// such as `{#g5}` or `#g5`, a slug, a path with more than one `/`). A story ID has exactly one `/`,
    /// both sides non-empty, no whitespace, and does not start with `#` or `{`.
    public var epic: String? {
        guard let first = rawValue.first, first != "#", first != "{" else { return nil }
        guard !rawValue.contains(where: \.isWhitespace) else { return nil }
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return String(parts[0])
    }
}

/// The result of resolving a ``SpecCitation`` against the Project's single specification source.
public struct SpecCitationResolution: Equatable, Sendable {
    public let citation: SpecCitation
    public let resolves: Bool
    public let resolvedPath: String?
    public let commit: String?
    public let repository: String?
    public let failureReason: String?

    public init(
        citation: SpecCitation,
        resolves: Bool,
        resolvedPath: String? = nil,
        commit: String? = nil,
        repository: String? = nil,
        failureReason: String? = nil
    ) {
        self.citation = citation
        self.resolves = resolves
        self.resolvedPath = resolvedPath
        self.commit = commit
        self.repository = repository
        self.failureReason = failureReason
    }

    public static func resolved(
        citation: SpecCitation,
        resolvedPath: String,
        commit: String,
        repository: String
    ) -> SpecCitationResolution {
        SpecCitationResolution(
            citation: citation,
            resolves: true,
            resolvedPath: resolvedPath,
            commit: commit,
            repository: repository,
            failureReason: nil
        )
    }

    public static func unresolved(
        citation: SpecCitation,
        reason: String,
        repository: String? = nil,
        commit: String? = nil
    ) -> SpecCitationResolution {
        SpecCitationResolution(
            citation: citation,
            resolves: false,
            resolvedPath: nil,
            commit: commit,
            repository: repository,
            failureReason: reason
        )
    }
}
