/// A shipped template set beside the same template composed with Project instructions, split at the one
/// section the composition adds. `before` and `after` are Yellowhammer's locked text; `added` is the
/// Operator's section.
public struct ProjectInstructionsComparison: Equatable, Sendable {
    public let before: String
    public let added: String
    public let after: String
    /// The heading of the Yellowhammer section the added one sits immediately before, when there is one.
    public let precedesHeading: String?
    /// True when removing `added` from the customized template gives the shipped template exactly, so the
    /// contract is unchanged and not forked.
    public let isOnlyDifference: Bool

    /// Nil when `projectInstructions` adds nothing or the customized template carries no such section.
    public init?(shipped: String, customized: String, projectInstructions: String) {
        guard !ProjectInstructions.isEmpty(projectInstructions) else { return nil }
        let section = ProjectInstructionsSection.render(projectInstructions)
        guard let range = customized.range(of: section + "\n\n") else { return nil }
        before = String(customized[..<range.lowerBound])
        added = section
        after = String(customized[range.upperBound...])
        precedesHeading = after.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init)
        isOnlyDifference = before + after == shipped
    }
}
