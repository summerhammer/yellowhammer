import Foundation

/// A Project's Change Type: the `change_type` key, whose value fills the `{type}` token of every
/// Message Template (glossary → Change Type). A non-empty string, `feat` unless the Project says otherwise.
public struct ChangeType: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    /// The Change Type of a Project that declares none.
    public static let feat = ChangeType(uncheckedRawValue: "feat")

    /// Fails for an empty or whitespace-only string. Surrounding whitespace is trimmed.
    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }
}

/// One of a Project's configurable Message Templates (glossary → Message Template): a string with
/// `{token}` placeholders that is rendered by plain substitution, with no conditionals.
///
/// Each ``Kind`` accepts only its own tokens. A template is validated when it is made, so a value of
/// this type always renders.
///
/// Brace rules: text without braces is literal. A `{` opens a token that runs to the next `}`; the
/// text between must be one of the Kind's tokens, otherwise the template is refused
/// (``Refusal/unknownToken(_:)``, which also covers `{}` and a nested `{`). A `{` with no closing `}`
/// is refused too (``Refusal/unterminatedBrace``), as a typo in a token name would otherwise render
/// literally into a commit. A lone `}` is literal. There is no escape syntax for a literal `{`.
public struct MessageTemplate: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// Which template this is, and so which tokens it accepts and what its default is.
    public enum Kind: CaseIterable, Sendable {
        case pullRequestTitle
        case commitMessage
        case wipCommitMessage

        /// The configuration key that holds this template.
        public var key: String {
            switch self {
            case .pullRequestTitle: "pull_request_title"
            case .commitMessage: "commit_message"
            case .wipCommitMessage: "wip_commit_message"
            }
        }

        public var allowedTokens: Set<Token> {
            switch self {
            case .pullRequestTitle:
                [.type, .title, .key, .repository, .branch, .project, .partial, .scope]
            case .commitMessage:
                [.type, .title, .key, .repository, .scope, .cardKey, .cardTitle, .story]
            case .wipCommitMessage:
                [.type, .repository, .branch, .project]
            }
        }

        /// The built-in template used when the Project file does not set one.
        public var defaultText: String {
            switch self {
            case .pullRequestTitle: "{type}{scope}: {partial}{title}"
            case .commitMessage: "{type}{scope}: {card_title}"
            case .wipCommitMessage: "chore(wip): preserve uncommitted work on {branch}"
            }
        }
    }

    /// A placeholder name, written `{name}` in a template.
    public enum Token: String, CaseIterable, Hashable, Sendable, CustomStringConvertible {
        case type
        case title
        case key
        case repository
        case branch
        case project
        case partial
        case scope
        case cardKey = "card_key"
        case cardTitle = "card_title"
        case story

        public var description: String { "{\(rawValue)}" }
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// Empty, or only whitespace.
        case empty
        /// The name between the braces, not a token of the template's Kind.
        case unknownToken(String)
        /// A `{` with no `}` after it.
        case unterminatedBrace
    }

    public let kind: Kind
    public let text: String

    public var description: String { text }

    /// Refuses an empty template, an unknown token and an unterminated `{`.
    public init(_ text: String, kind: Kind) throws(Refusal) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .empty }
        _ = try Self.segments(of: text, kind: kind)
        self.kind = kind
        self.text = text
    }

    /// The built-in template of `kind`.
    public static func `default`(_ kind: Kind) -> MessageTemplate {
        // The built-in defaults use only their own Kind's tokens (asserted by DomainTests).
        MessageTemplate(uncheckedText: kind.defaultText, kind: kind)
    }

    private init(uncheckedText text: String, kind: Kind) {
        self.kind = kind
        self.text = text
    }

    /// Plain substitution. A token with no entry in `values` renders as the empty string. `{scope}` is
    /// substituted as given: callers pass it already self-formatted (`(auth)` or empty), so the
    /// renderer adds no punctuation.
    public func render(_ values: [Token: String]) -> String {
        guard let segments = try? Self.segments(of: text, kind: kind) else { return text }
        return segments.reduce(into: "") { result, segment in
            switch segment {
            case .literal(let literal): result += literal
            case .token(let token): result += values[token] ?? ""
            }
        }
    }

    private enum Segment {
        case literal(String)
        case token(Token)
    }

    private static func segments(of text: String, kind: Kind) throws(Refusal) -> [Segment] {
        let allowed = kind.allowedTokens
        var segments: [Segment] = []
        var literal = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "{" else {
                literal.append(character)
                index = text.index(after: index)
                continue
            }
            guard let close = text[index...].firstIndex(of: "}") else { throw .unterminatedBrace }
            let name = String(text[text.index(after: index)..<close])
            guard let token = Token(rawValue: name), allowed.contains(token) else {
                throw .unknownToken(name)
            }
            if !literal.isEmpty {
                segments.append(.literal(literal))
                literal = ""
            }
            segments.append(.token(token))
            index = text.index(after: close)
        }
        if !literal.isEmpty { segments.append(.literal(literal)) }
        return segments
    }
}
