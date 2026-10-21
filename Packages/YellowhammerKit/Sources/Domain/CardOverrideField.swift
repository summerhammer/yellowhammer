/// The Card override as the Operator edits it: one top-level `Card override: <full cli/model/effort>` line
/// in a Work Card's Managed Block, outside fenced code and the prose brief (spec: routing/
/// resolve-a-route-for-a-card, board-projection/maintain-the-managed-block; glossary: Card override).
///
/// The field is supported human input, so what is held is the line text exactly as the board spells it —
/// valid, malformed or duplicated — and ``reading`` judges it. The exact empty form is ``emptyLine``
/// (no trailing space); a nonempty value has exactly one space after the colon. Only this designated line
/// is ever read: no other description text is scanned for something route-like.
public enum CardOverrideField {
    /// The line's label, the colon included.
    public static let prefix = "Card override:"

    /// The empty form: no Card override, normal routing defaults.
    public static let emptyLine = prefix

    /// Whether a Managed Block line is a Card override line: at the top level (no indentation), starting
    /// with the label.
    public static func isFieldLine(_ line: String) -> Bool {
        line.hasPrefix(prefix)
    }

    /// The lines to render for what the Journal holds: the empty form when it holds none.
    public static func renderedLines(_ held: [String]) -> [String] {
        held.isEmpty ? [emptyLine] : held
    }

    /// What the held lines say. Judged by the exact spelling: nothing is trimmed, so a trailing space, a
    /// second separator space or a route with a space inside is malformed, not forgiven.
    public enum Reading: Equatable, Sendable {
        /// Absent or empty: the Card is routed by its Work Kind and Repo Role as usual.
        case unset
        /// One complete value, to be matched against the Routing Table and otherwise split in three.
        case value(String)
        /// Retained as written and refused at the Readiness Check; never silently dropped.
        case malformed(reason: String)
    }

    public static func reading(of held: [String]) -> Reading {
        let lines = held.filter(isFieldLine)
        guard lines.count <= 1 else {
            let shown = lines.map { "`\($0)`" }.joined(separator: ", ")
            return .malformed(
                reason: "the description has \(lines.count) `\(prefix)` lines (\(shown)); keep exactly one"
            )
        }
        guard let line = lines.first, line != emptyLine else { return .unset }
        let separator = prefix + " "
        guard line.hasPrefix(separator) else {
            return .malformed(reason: "`\(line)` needs exactly one space after the colon")
        }
        let value = String(line.dropFirst(separator.count))
        if value.isEmpty {
            return .malformed(reason: "`\(line)` has a trailing space; write the empty form as `\(emptyLine)`")
        }
        if value.first?.isWhitespace == true {
            return .malformed(reason: "`\(line)` needs exactly one space after the colon")
        }
        if value.last?.isWhitespace == true {
            return .malformed(reason: "`\(line)` has trailing whitespace; the route is read exactly as written")
        }
        return .value(value)
    }
}
