import Domain
import Foundation

/// The editable Feature-level field lives in the authored prose, outside the Roll-up's Managed Block.
/// Only its section is repair input; the remaining Feature prose is preserved at delivery time.
enum FeatureDefinitionOfDone {
    static func render(_ clauses: [DefinitionOfDoneClauseDraft]) -> String {
        "## Definition of done\n\n" + clauses.map {
            "- [ ] \($0.text) (\($0.citation.rawValue))"
        }.joined(separator: "\n")
    }

    static func parse(_ description: String) -> (clauses: [DefinitionOfDoneClauseDraft], problems: [String]) {
        guard let prose = FeatureAuthoringProse.current(in: description), let range = sectionRange(in: prose) else {
            return ([], ["the Feature's Definition of Done section cannot be read; restore its heading and delimiters"])
        }
        let section = String(prose[range])
        let body = section.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        let parsed = CardManagedBlockParser.parse(block: "### Definition of Done\n" + body)
        return (
            parsed.clauses.map {
                DefinitionOfDoneClauseDraft(text: $0.text, citation: SpecCitation($0.citation ?? ""))
            },
            parsed.invalid.filter { $0.field == "definition of done" }
                .map { "Feature Definition of Done: \($0.reason)" }
        )
    }

    /// Replaces the one supported section, leaving the rest of the current region byte-for-byte intact.
    /// A pre-breakdown halt has no region: its newly authored field is appended without reading Operator prose.
    static func replace(in description: String, section: String) -> String? {
        guard let prose = FeatureAuthoringProse.current(in: description) else {
            return FeatureAuthoringProse.replace(in: description, prose: section)
        }
        guard let range = sectionRange(in: prose) else {
            return FeatureAuthoringProse.replace(in: description, prose: prose + "\n\n" + section)
        }
        var replacement = prose
        replacement.replaceSubrange(range, with: section)
        return FeatureAuthoringProse.replace(in: description, prose: replacement)
    }

    private static func sectionRange(in prose: String) -> Range<String.Index>? {
        let lines = prose.components(separatedBy: "\n")
        let masked = ArchitecturalBriefProseRegion.structureMasks(lines)
        let headings = lines.indices.filter {
            !masked.contains($0)
                && lines[$0].trimmingCharacters(in: .whitespaces).lowercased() == "## definition of done"
        }
        guard headings.count == 1, let first = headings.first else { return nil }
        let last = lines.indices.dropFirst(first + 1).first {
            !masked.contains($0)
                && lines[$0].trimmingCharacters(in: .whitespaces)
                    .range(of: "^#{1,6} ", options: .regularExpression) != nil
        } ?? lines.count
        let startOffset = lines.prefix(first).reduce(0) { $0 + $1.count + 1 }
        let endOffset = last == lines.count ? prose.count : lines.prefix(last).reduce(0) { $0 + $1.count + 1 }
        let start = prose.index(prose.startIndex, offsetBy: startOffset)
        var end = prose.index(prose.startIndex, offsetBy: endOffset)
        while end > start, prose[prose.index(before: end)].isNewline { end = prose.index(before: end) }
        return start..<end
    }
}
