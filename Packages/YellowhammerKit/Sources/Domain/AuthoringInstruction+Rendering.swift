extension AuthoringInstruction {
    /// Renders this instruction as deterministic Markdown, in a fixed section order. Sections whose
    /// payload is absent or empty are omitted entirely. Uses `\n` newlines only and ends with a single
    /// trailing newline; rendering the same instruction twice yields identical output.
    public func render() -> String {
        var sections: [String] = [header, specificationSection, repositoriesSection]
        if let namedFeatureSection { sections.append(namedFeatureSection) }
        if let adoptionSection { sections.append(adoptionSection) }
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

        Write the result file to `\(resultFilePath)` on completion. It must declare \
        `"schema": "\(pass.schemaIdentifier)"` and `"version": 1`. Permitted outcomes for this pass: \
        \(permittedOutcomes.joined(separator: ", ")). \(fieldsSentence) An empty or missing result file \
        is treated as a crash.
        """
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
            return "`drafted` carries `definition_of_done` (clauses of `text` and `citation`) and `cards` "
                + "(each with `repository`, `kind`, `title`, `unit_of_work`, `brief`, `definition_of_done` "
                + "and `contracts` naming a `repository`, its `paths` and an optional `symbol`); `failed` "
                + "carries `reason`."
        default:
            return "`selected` carries `name`, `reasoning`, `repositories`, `adopted_card_issue_ids` and an "
                + "optional `sequence` (`preceded_by`, `followed_by`, `seam`); `halted` carries `feature` "
                + "and `halt_cause` (`no-backward-compatible-seam` with `halt_seam`, "
                + "`repositories-undetermined`, or `contract-outside-project` with `halt_repository`); "
                + "`failed` carries `reason`."
        }
    }
}
