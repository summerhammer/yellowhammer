import Foundation

/// Whether two Markdown texts render to the same text — the comparison the Delta Read's edit
/// detection uses instead of byte equality.
///
/// Linear parses the Markdown of a Card's description and re-serialises it, so the copy read back from
/// the board is almost never byte-identical to the one Yellowhammer wrote: an indented code block comes
/// back fenced, `[` and `]` come back escaped, `- ` bullets become `* `, a bare `night.id` is
/// autolinked, and so on. Comparing bytes therefore mistook Linear's own rewrite for an Operator edit
/// (issue #433: 27 `TranscriptionStampVoided` events and a `ClauseInvalidated(cause: text_edited)` with
/// nobody having edited anything).
///
/// Two texts are "the same" when their rendered text is the same once every whitespace and newline
/// character is dropped. A link contributes its target as well, unless the target is only an autolink
/// of the link's own text, so an Operator re-pointing a real link still counts as an edit.
///
/// Accepted generosity: an edit that changes only whitespace, indentation, Markdown syntax (escapes,
/// fences, emphasis markers, bullet characters) or autolinks is not an edit. Anything that changes the
/// rendered text is. If either text cannot be parsed, the comparison falls back to raw string equality.
///
/// This is a comparison predicate only. The canonical form is never stored: the Journal keeps the text
/// Yellowhammer wrote, so a later comparison is against the original and not against a lossy digest.
enum MarkdownEquivalence {
    static func rendersSame(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let lhsCanonical = canonical(lhs), let rhsCanonical = canonical(rhs) else { return false }
        return lhsCanonical == rhsCanonical
    }

    /// The text a reader sees, minus whitespace, with each non-autolink link's target appended after
    /// its text. Nil when the Markdown cannot be parsed at all.
    private static func canonical(_ text: String) -> String? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return nil }
        var result = ""
        for run in parsed.runs {
            let runText = withoutWhitespace(String(parsed[run.range].characters))
            result += runText
            if let url = run.link, !isAutolink(url, of: runText) {
                result += url.absoluteString
            }
        }
        return result
    }

    private static func withoutWhitespace(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace && !$0.isNewline })
    }

    /// A link whose target is just its own text made into a link: the URL itself, or the text behind
    /// an `http://`, `https://` or `mailto:` scheme.
    private static func isAutolink(_ url: URL, of text: String) -> Bool {
        let target = url.absoluteString
        return [text, "http://" + text, "https://" + text, "mailto:" + text].contains(target)
    }
}
