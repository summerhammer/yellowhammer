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
    /// The absolute path the CLI must write its result file to.
    public let resultFilePath: String

    public init(
        route: Route,
        featureTitle: String,
        clauses: [VerificationClause],
        specificationSource: ProjectSpecificationSource,
        repositories: [VerificationRepository],
        resultFilePath: String
    ) {
        self.route = route
        self.featureTitle = featureTitle
        self.clauses = clauses
        self.specificationSource = specificationSource
        self.repositories = repositories
        self.resultFilePath = resultFilePath
    }

    /// This instruction with its result file path replaced.
    public func withResultFilePath(_ path: String) -> VerificationInstruction {
        VerificationInstruction(
            route: route, featureTitle: featureTitle, clauses: clauses,
            specificationSource: specificationSource, repositories: repositories, resultFilePath: path
        )
    }

    /// Deterministic Markdown in a fixed section order, `\n` newlines, one trailing newline.
    public func render() -> String {
        [header, featureSection, rulesSection, clausesSection, repositoriesSection, resultContractSection]
            .joined(separator: "\n\n") + "\n"
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

        This pass is read-only: change nothing. Judge each clause below individually, against its Spec \
        Citation in the specification source and the finished code in the repositories. For every clause \
        state what you checked and the interpretation of the clause you verified it under. Report `met` \
        or `unmet` for each clause and never an aggregate verdict such as "passed". Report every clause \
        listed, and no other.
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

        Write the result file to `\(resultFilePath)` on completion. It must declare \
        `"schema": "\(RunPass.verifier.schemaIdentifier)"` and `"version": 1`. Permitted outcomes for \
        this pass: reported, failed. `reported` carries `clauses`, one entry per clause with `issue_id`, \
        `cid`, `verdict` (`met` or `unmet`), `what_was_checked` and `interpretation`; `failed` carries \
        `reason`. An empty or missing result file is treated as a crash.
        """
    }
}
