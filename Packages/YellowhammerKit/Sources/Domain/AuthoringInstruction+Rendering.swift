extension AuthoringInstruction {
    /// Renders this instruction as deterministic Markdown, in a fixed section order. Sections whose
    /// payload is absent or empty are omitted entirely. Uses `\n` newlines only and ends with a single
    /// trailing newline; rendering the same instruction twice yields identical output.
    public func render() -> String {
        var sections: [String] = [header, specificationSection, repositoriesSection, authoringInvariantSection]
        if pass != .breakdown {
            sections.append(repoDependenciesSection)
            if let heldConsumersSection { sections.append(heldConsumersSection) }
        }
        if let namedFeatureSection { sections.append(namedFeatureSection) }
        if let adoptionSection { sections.append(adoptionSection) }
        if let refusedThisNightSection { sections.append(refusedThisNightSection) }
        if let selectedFeatureSection { sections.append(selectedFeatureSection) }
        sections.append(resultContractSection)
        return sections.joined(separator: "\n\n") + "\n"
    }

    private var header: String {
        switch pass {
        case .breakdown:
            "# Breakdown pass — author Act"
        default:
            "# Selection pass — author Act"
        }
    }

    private var specificationSection: String {
        """
        ## Specification

        Source: \(specificationSource.repositoryName)
        Path: \(specificationSource.path)
        Mainline: \(specificationMainline?.commit ?? "not resolved")
        """
    }

    private var repositoriesSection: String {
        var lines = ["## Repositories", ""]
        for repo in repos {
            lines.append("- \(repo.name)")
            lines.append("  Role: \(repo.role.rawValue)")
            lines.append("  Path: \(repo.path)")
            lines.append("  Mainline: \(mainlines[repo]?.commit ?? "not resolved")")
        }
        return lines.joined(separator: "\n")
    }

    /// Both passes: the invariant every Work Card meets. The selection pass adds the sequence rule across a
    /// declared Repo Dependency; the breakdown pass adds how a consumer Work Card reads its producers.
    private var authoringInvariantSection: String {
        var paragraphs = [
            "## Authoring invariant",
            "Every Work Card in a Feature must be completable and verifiable against the repositories as they "
                + "exist at authoring time: nothing a Work Card needs may be work another Work Card in the same "
                + "Feature has yet to do."
        ]
        if pass == .breakdown {
            paragraphs.append(
                "Every repository a Work Card reads from goes in its `contracts`. Bumping a version pin or "
                    + "updating a lockfile in a consumer repository is that consumer Work Card's own work."
            )
        } else {
            paragraphs.append(
                "A Feature never touches both ends of a declared Repo Dependency. Where the work spans one, "
                    + "select the upstream layer (the producer Repo) as its own Feature first and name the rest "
                    + "in `followed_by`; the consumer's work follows in a later Feature once the producer's has an "
                    + "Observed Merge and, for a `tag` edge, an Observed Release."
            )
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Selection pass only: every declared edge, consumer first.
    private var repoDependenciesSection: String {
        let edges = repos.flatMap { consumer in
            consumer.consumes.map { "- \(consumer.name) consumes \($0.producer) via \($0.via.rawValue)" }
        }
        return (["## Repo Dependencies", ""] + (edges.isEmpty ? ["None declared."] : edges)).joined(separator: "\n")
    }

    /// Selection pass only, and only when the release gate holds a consumer back tonight.
    private var heldConsumersSection: String? {
        guard !heldConsumers.isEmpty else { return nil }
        let bullets = heldConsumers.map {
            "- \($0.consumer): it reads \($0.producer) by tag, and no release of \($0.producer) contains "
                + "Feature \($0.producerFeature) yet. Do not select a Feature that touches \($0.consumer) tonight."
        }
        return (["## Held by the release gate tonight", ""] + bullets).joined(separator: "\n")
    }

    private var namedFeatureSection: String? {
        guard let namedFeature else { return nil }
        return "## Named Feature\n\nThe Operator named this Feature: \(namedFeature). Work on it and no other."
    }

    private var adoptionSection: String? {
        guard !adoptionCandidates.isEmpty else { return nil }
        let bullets = adoptionCandidates.map { "- \($0.issueID) (repository: \($0.repository))" }
        return (
            ["## Adoption candidates", "", "Blocked Cards left by a closed Feature, which a Feature may adopt:", ""]
                + bullets
        ).joined(separator: "\n")
    }

    /// Features refused earlier in this Night's re-selection walk (roadmap P11.6): must not be chosen again.
    private var refusedThisNightSection: String? {
        guard !refusedThisNight.isEmpty else { return nil }
        let bullets = refusedThisNight.map { "- \($0)" }
        let header = [
            "## Refused this Night", "",
            "Already refused earlier in this Night's re-selection walk; do not select again:", ""
        ]
        return (header + bullets).joined(separator: "\n")
    }

    private var selectedFeatureSection: String? {
        guard let feature = selectedFeature else { return nil }
        var lines = [
            "## Selected Feature", "",
            "Name: \(feature.name)",
            "Reasoning: \(feature.reasoning)",
            "Repositories: \(feature.repositories.joined(separator: ", "))"
        ]
        if let sequence = feature.sequence {
            lines.append("Preceded by: \(sequence.precededBy)")
            lines.append("Followed by: \(sequence.followedBy)")
            lines.append("Seam: \(sequence.seam)")
        }
        if !feature.adoptedCardIssueIDs.isEmpty {
            lines.append("Adopted Cards: \(feature.adoptedCardIssueIDs.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private var resultContractSection: String {
        """
        ## Result contract

        Return one JSON object as your final structured response, conforming to the supplied JSON schema. The \
        CLI Adapter persists it to `\(resultFilePath)`; do not create or edit that file with tools. It must declare \
        `"schema": "\(pass.schemaIdentifier)"` and `"version": 1`. Permitted outcomes for this pass: \
        \(permittedOutcomes.joined(separator: ", ")). \(fieldsSentence)\(descriptionBudgetSentence)\
        \(briefAudienceSentence) Ending without a final structured response is treated as a crash.
        """
    }

    /// Breakdown pass only: the size a Card's description must fit, kept apart from how a contract path is
    /// read. Contract files are not copied onto the Card, so what counts is its `brief` and Definition of
    /// Done. Empty for the selection pass, and when the board enforces no budget.
    private var descriptionBudgetSentence: String {
        guard pass == .breakdown, let descriptionBudget else { return "" }
        return " Separately from contract paths: a Card's description on the board holds its `brief` and "
            + "`definition_of_done`, and must fit the board's description budget of \(descriptionBudget.value) "
            + "\(descriptionBudget.limit.unit.plural); a Card over it makes the breakdown invalid output. "
            + "Contract files do not count against it."
    }

    /// Breakdown pass only: who reads a Card's `brief` (issue #444). Empty for the selection pass.
    private var briefAudienceSentence: String {
        guard pass == .breakdown else { return "" }
        return " A Card's `brief` is composed into the instruction of an autonomous worker agent CLI, which "
            + "commits its work to the Feature branch itself and reports the commit in its final structured "
            + "response. The `brief` states the approach, not completion criteria (the Definition of Done holds "
            + "those), and "
            + "must not tell the worker not to commit, to leave changes uncommitted, or that someone else commits."
    }

    private var permittedOutcomes: [String] {
        switch pass {
        case .breakdown: ["drafted", "failed"]
        default: ["selected", "no_selectable_feature", "halted", "failed"]
        }
    }

    private var fieldsSentence: String {
        switch pass {
        case .breakdown:
            return "`drafted` carries `definition_of_done` (clauses of `text` and `citation`, where `citation` "
                + "is a story ID `<epic>/<story>` or a goal ID) and `cards` "
                + "(each with `repository`, `kind`, `title`, `unit_of_work`, `brief`, `definition_of_done` "
                + "and `contracts` naming a `repository`, its `paths`, `ranges` and an optional `symbol`); "
                + "each contract path names one regular file at mainline, never a directory, a submodule or "
                + "a symbolic link; a path without a range is inlined whole into the worker's instruction, "
                + "so `ranges` bound what the worker receives; a `ranges` entry is "
                + "`{path, start, end}`, 1-based and inclusive, several are allowed per path, and every range "
                + "must lie within the file at mainline; `failed` carries `reason`."
        default:
            return "`selected` carries `name`, `reasoning`, `repositories`, `adopted_card_issue_ids` and an "
                + "optional `sequence` (`preceded_by`, `followed_by`, `seam`); `halted` carries `feature` "
                + "and `halt_cause` (`no-backward-compatible-seam` with `halt_seam`, "
                + "`repositories-undetermined`, or `contract-outside-project` with `halt_repository`); "
                + "`failed` carries `reason`."
        }
    }
}
