import Domain

/// What every WIP Commit says and who it says it as (glossary → WIP Commit): a message rendered from the
/// Project's WIP Commit Message Template, a `Yellowhammer-WIP: <branch>` trailer, and one fixed author.
/// The same for every trigger — reconciliation, the fence before a new Attempt, on Block, and real-mode
/// Project removal. Nothing reads the message or the trailer back: the WIP ref and the Journal identify
/// a WIP Commit.
public struct WIPCommitMessage: Equatable, Sendable {
    public static let trailerKey = "Yellowhammer-WIP"
    public static let authorName = "Yellowhammer"
    public static let authorEmail = "noreply@yellowhammer.dev"

    public let template: MessageTemplate
    public let changeType: ChangeType
    public let project: String

    public init(
        template: MessageTemplate = .default(.wipCommitMessage), changeType: ChangeType = .feat, project: String = ""
    ) {
        self.template = template
        self.changeType = changeType
        self.project = project
    }

    /// The full commit message: the rendered template, a blank line, then the trailer.
    public func render(branch: FeatureBranch, repository: String) -> String {
        let subject = template.render([
            .type: changeType.rawValue,
            .repository: repository,
            .branch: branch.name,
            .project: project
        ])
        return "\(subject)\n\n\(Self.trailerKey): \(branch.name)"
    }
}
