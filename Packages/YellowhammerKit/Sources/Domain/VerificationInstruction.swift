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

/// One Check result recorded for a Feature's Work Cards, never reconstructed from current configuration.
public struct VerificationCheckResult: Equatable, Sendable {
    /// A declared-none Check records no command; an absent value is not evidence of success.
    public let command: String?
    public let judgedCommit: String?
    public let exitStatus: Int32?

    public init(command: String?, judgedCommit: String?, exitStatus: Int32?) {
        self.command = command
        self.judgedCommit = judgedCommit
        self.exitStatus = exitStatus
    }
}

/// A repository the Feature touched: where its finished code is, the Feature Branch holding it, and the commit
/// the verifier judges there (spec: verification/verify-a-feature-clause-by-clause, `#judged-checkout`).
public struct VerificationRepository: Equatable, Sendable {
    public let name: String
    /// The directory holding the finished code: a checkout at ``judgedCommit`` — the held Worktree when every
    /// touched repository's is exact and clean, else a fresh checkout.
    public let directory: String
    public let featureBranch: String
    /// The commit judged: the Pushed Tip, or the recorded base commit when ``noPushedBranch``. Nil only where
    /// nothing was pushed by design (a Rehearsal Night).
    public let judgedCommit: String?
    /// The repository has the No-Pushed-Branch Outcome: ``judgedCommit`` is its recorded base commit.
    public let noPushedBranch: Bool
    /// The Journal's Check results for this Feature and repository, in append order.
    public let checkResults: [VerificationCheckResult]
    /// The Repo's configuration declares `check = none`: the Engine ran no Check here, and none is recorded.
    public let checkDeclaredNone: Bool

    public init(
        name: String, directory: String, featureBranch: String, judgedCommit: String? = nil,
        noPushedBranch: Bool = false, checkResults: [VerificationCheckResult] = [], checkDeclaredNone: Bool = false
    ) {
        self.name = name
        self.directory = directory
        self.featureBranch = featureBranch
        self.judgedCommit = judgedCommit
        self.noPushedBranch = noPushedBranch
        self.checkResults = checkResults
        self.checkDeclaredNone = checkDeclaredNone
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
        render(projectInstructions: nil)
    }

    /// The same rendering with the Project's instructions composed in just before `## Boundaries`. A nil or
    /// blank argument yields exactly ``render()``.
    public func render(projectInstructions: String?) -> String {
        let sections = ProjectInstructionsSection.insertingBeforeBoundaries(
            projectInstructions,
            into: [
                header, featureSection, rulesSection, clausesSection, repositoriesSection,
                PassBoundaries.section
            ]
        )
        return (sections + [resultContractSection]).joined(separator: "\n\n") + "\n"
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

        Each repository below is checked out at the commit you judge, named on its `Checkout at` line: its \
        Pushed Tip or, marked no pushed branch, its recorded base commit. Use the recorded Check results \
        below to judge clauses they cover, on any Route. A record whose judged commit is not the commit you \
        judge does not decide a clause: name that record beside the clause in `what_was_checked`. A record \
        with an unavailable command, judged commit or exit status cannot establish what ran successfully at \
        that commit.

        Report every build or test clause no recorded Check covers, naming the command it would need in \
        `what_was_checked`, so the Operator sees the gap in the Repo's Check command. Judge it when your \
        environment can check it; otherwise report `not checked`, naming that command and the missing \
        capability. A declared `check = none` supplies no Check result and covers no clause.

        When a repository below is marked `Check: none`, its build or test clauses have no Check because \
        the Repo's configuration chose none, not because your environment is broken. For such a clause you \
        cannot check, `what_was_checked` must open with that configuration choice, in these words: \
        "\(NoCheckAttribution.verifierLead(repository: "<name>"))" Name the command it would need next, \
        and the capability your environment lacked last, as secondary detail.
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
            if repository.checkDeclaredNone { lines.append("  Check: none (declared `check = none`)") }
            lines.append("  Checkout at: \(repository.judgedCommitLine)")
            if repository.checkResults.isEmpty {
                lines.append("  Recorded Check results: none")
            } else {
                lines.append("  Recorded Check results (Journal append order):")
                for result in repository.checkResults {
                    lines.append("  - Command: \(result.command ?? "not recorded")")
                    lines.append("    Judged commit: \(result.judgedCommit ?? "not recorded")")
                    lines.append("    Exit status: \(result.exitStatus.map(String.init) ?? "not recorded")")
                }
            }
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

extension VerificationRepository {
    /// The commit the checkout is at, as the instruction names it.
    fileprivate var judgedCommitLine: String {
        guard let judgedCommit else { return "not recorded (nothing was pushed)" }
        return noPushedBranch
            ? "\(judgedCommit) (no pushed branch: the recorded base commit)"
            : "\(judgedCommit) (the Pushed Tip)"
    }
}
