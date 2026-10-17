/// One Definition of Done clause handed to the verifier to judge (roadmap P10.5).
public struct VerificationClause: Equatable, Sendable {
    /// The issue the clause belongs to — the Feature Issue or a Card. Clause ids are unique only within it.
    public let issueID: String
    public let cid: String
    public let text: String
    /// The Spec Citation's location in the specification source.
    public let location: String

    public init(issueID: String, cid: String, text: String, location: String) {
        self.issueID = issueID
        self.cid = cid
        self.text = text
        self.location = location
    }
}

/// A repository the Feature touched: where its finished code is, and the Feature Branch holding it.
public struct VerificationRepository: Equatable, Sendable {
    public let name: String
    /// The directory holding the finished code: the held Worktree when one is held, else the repository.
    public let directory: String
    public let featureBranch: String

    public init(name: String, directory: String, featureBranch: String) {
        self.name = name
        self.directory = directory
        self.featureBranch = featureBranch
    }
}

/// The instruction Yellowhammer composes for the verifier pass (roadmap P10.5; spec:
/// verification/verify-a-feature-clause-by-clause). Deterministic data plus a rendering, like
/// ``AuthoringInstruction``. The pass is read-only and judges each clause individually.
public struct VerificationInstruction: Equatable, Sendable {
    public let route: Route
    /// How the Feature is named to the verifier.
    public let featureTitle: String
    public let clauses: [VerificationClause]
    public let specificationSource: ProjectSpecificationSource
    public let repositories: [VerificationRepository]

    public init(
        route: Route,
        featureTitle: String,
        clauses: [VerificationClause],
        specificationSource: ProjectSpecificationSource,
        repositories: [VerificationRepository]
    ) {
        self.route = route
        self.featureTitle = featureTitle
        self.clauses = clauses
        self.specificationSource = specificationSource
        self.repositories = repositories
    }

    /// Deterministic Markdown in a fixed section order, `\n` newlines, one trailing newline.
    public func render() -> String {
        [
            header, featureSection, rulesSection, clausesSection, repositoriesSection, PassBoundaries.section,
            resultContractSection
        ].joined(separator: "\n\n") + "\n"
    }

    private var header: String { "# Verification pass — land Act" }

    private var featureSection: String {
        """
        ## Feature

        Feature: \(featureTitle)
        Specification source: \(specificationSource.repositoryName)
        Specification path: \(specificationSource.path)
        """
    }

    private var rulesSection: String {
        """
        ## Rules

        This pass is read-only: change nothing. You read the specification source and the finished code in \
        the repositories you are given, and may run commands that change nothing. You are guaranteed \
        neither network access nor a writable directory; whether you have either depends on your Route. \
        Judge each clause below individually, against its Spec Citation in the specification source and the \
        finished code in the repositories. For every clause state what you checked and the interpretation of \
        the clause you verified it under. Report `met`, `unmet` or `not checked` for each clause and never \
        an aggregate verdict such as "passed". Report `not checked` when you could not perform the check the \
        clause needs in your environment, naming in `what_was_checked` the capability that was missing: \
        network access, a writable directory, or a tool. Report every clause listed, and no other.
        """
    }

    private var clausesSection: String {
        var lines = ["## Clauses to judge", ""]
        for clause in clauses {
            lines.append("- \(clause.issueID) \(clause.cid): \(clause.text)")
            lines.append("  Spec Citation: \(clause.location)")
        }
        return lines.joined(separator: "\n")
    }

    private var repositoriesSection: String {
        var lines = ["## Repositories", ""]
        for repository in repositories {
            lines.append("- \(repository.name)")
            lines.append("  Finished code: \(repository.directory)")
            lines.append("  Feature Branch: \(repository.featureBranch)")
        }
        return lines.joined(separator: "\n")
    }

    private var resultContractSection: String {
        """
        ## Result contract

        Return one JSON object as your final structured response, conforming to the supplied JSON schema. The \
        CLI Adapter persists it; do not create or edit a result file with tools. It must declare \
        `"schema": "\(RunPass.verifier.schemaIdentifier)"` and `"version": 1`. Permitted outcomes for \
        this pass: reported, failed. `reported` carries `clauses`, one entry per clause with `issue_id`, \
        `cid`, `verdict` (`met`, `unmet` or `not checked`), `what_was_checked` and `interpretation`; `failed` carries \
        `reason`. Ending without a final structured response is treated as a crash.
        """
    }
}
