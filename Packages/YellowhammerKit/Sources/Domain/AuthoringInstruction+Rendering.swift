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
        if let boardStateSection { sections.append(boardStateSection) }
        if let refusedThisNightSection { sections.append(refusedThisNightSection) }
        if let selectedFeatureSection { sections.append(selectedFeatureSection) }
        if let descriptionBudgetSection { sections.append(descriptionBudgetSection) }
        if let earlierRejectionsSection { sections.append(earlierRejectionsSection) }
        sections.append(PassBoundaries.section)
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
            // A stacked repository's commit is `effective_base(R)` (roadmap P23.2): say whose tip it is.
            if let ref = mainlines[repo]?.ref, ref.hasPrefix("refs/yellowhammer/landed/") {
                lines.append("  Stacked on: \(ref), the landed tip of a Feature awaiting merge")
            }
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
        let bullets = heldConsumers.map { held in
            let why = switch held.hold {
            case .awaitingRelease:
                "it reads \(held.producer) by tag, and no release of \(held.producer) contains Feature "
                    + "\(held.producerFeature) yet."
            case .awaitingMerge:
                "it consumes \(held.producer), and Feature \(held.producerFeature) is implemented in "
                    + "\(held.producer) but awaits its Observed Merge there."
            }
            return "- \(held.consumer): \(why) Do not select a Feature that touches \(held.consumer) tonight."
        }
        return (["## Held by the release gate tonight", ""] + bullets).joined(separator: "\n")
    }

    private var namedFeatureSection: String? {
        guard let namedFeature else { return nil }
        return "## Named Feature\n\nThe Operator named this Feature: \(namedFeature). Work on it and no other."
    }

    private var adoptionSection: String? {
        guard !adoptionCandidates.isEmpty else { return nil }
        let bullets = adoptionCandidates.map { candidate in
            var bullet = "- \(candidate.issueID) (repository: \(candidate.repository))"
            if let title = candidate.title, !title.isEmpty { bullet += ": \(title)" }
            if let reason = candidate.blockReason, !reason.isEmpty { bullet += " — blocked: \(reason)" }
            return bullet
        }
        return (
            ["## Adoption candidates", "", "Blocked Cards left by a closed Feature, which a Feature may adopt:", ""]
                + bullets
        ).joined(separator: "\n")
    }

    /// Selection pass only: what the Journal already knows of this Project's board, so the pass has no
    /// reason to search for state. Adoption candidates are rendered in their own section; they only decide
    /// whether there is anything to say at all.
    private var boardStateSection: String? {
        guard pass != .breakdown, let boardState else { return nil }
        if boardState.isEmpty && adoptionCandidates.isEmpty {
            return "## Board state\n\nNo Feature has been authored for this Project yet."
        }
        var groups: [String] = []
        if !boardState.features.isEmpty {
            let bullets = boardState.features.map { feature in
                feature.name.map { "- \($0) (\(feature.identifier)): \(feature.outcome)" }
                    ?? "- \(feature.identifier): \(feature.outcome)"
            }
            groups.append((["Features already authored for this Project, most recent first:", ""] + bullets)
                .joined(separator: "\n"))
        }
        if let unmergedGroup { groups.append(unmergedGroup) }
        if !boardState.waitingCards.isEmpty {
            let bullets = boardState.waitingCards.map {
                "- \($0.identifier) (repository: \($0.repository)): \($0.title) — waiting on you: \($0.reason)"
            }
            groups.append((["Cards in Waiting on You:", ""] + bullets).joined(separator: "\n"))
        }
        if groups.isEmpty {
            groups.append("Blocked Cards left by closed Features are listed under Adoption candidates.")
        }
        return (["## Board state"] + groups).joined(separator: "\n\n")
    }

    /// Every Feature in the Unmerged Feature Stack U (roadmap P23.2; spec: feature-authoring/
    /// select-the-next-feature, `#effective-base`), oldest first: already implemented, awaiting merge, and never
    /// to be selected again. Human identifiers and branch names only.
    private var unmergedGroup: String? {
        guard let boardState, !boardState.unmergedFeatures.isEmpty else { return nil }
        let bullets = boardState.unmergedFeatures.map { feature in
            let label = feature.name.map { "\($0) (\(feature.identifier))" } ?? feature.identifier
            let branches = feature.unmergedBranches.map { "\($0.repository) at branch `\($0.branch)`" }
            return "- \(label): touches \(feature.touchedRepositories.joined(separator: ", ")); awaiting merge in "
                + branches.joined(separator: ", ")
        }
        let header = "Features already implemented and awaiting merge, oldest first. Do not select any of these "
            + "again; the next Feature is authored on top of their branches:"
        return ([header, ""] + bullets).joined(separator: "\n")
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
        CLI Adapter persists it; do not create or edit a result file with tools. It must declare \
        `"schema": "\(pass.schemaIdentifier)"` and `"version": 1`. Permitted outcomes for this pass: \
        \(permittedOutcomes.joined(separator: ", ")). \(fieldsSentence)\(trackedContractPathSentence)\
        \(descriptionBudgetSentence)\(briefAudienceSentence) Ending without a final structured response is \
        treated as a crash.
        """
    }

    /// Breakdown pass only: a contract path is read from git at the repository's mainline commit, not from
    /// the working copy the pass browses, which can hold untracked, build-generated files (issue #523).
    /// Empty for the selection pass.
    private var trackedContractPathSentence: String {
        guard pass == .breakdown else { return "" }
        return " A contract path is read from git at the `Mainline` commit its repository shows under "
            + "Repositories, not from the working copy at its `Path`: it must be a file git tracks at that "
            + "commit. The working copy can hold files git does not track — a generated Xcode workspace and "
            + "its `Package.resolved`, `DerivedData`, `node_modules`, `.build` — and those are never contracts; "
            + "name the committed file they are generated from instead. Before naming a path, check it with "
            + "`git -C <Path> cat-file -e <Mainline>:<path>`, or list the tracked tree with "
            + "`git -C <Path> ls-tree -r --name-only <Mainline>`; a path absent at that commit halts the "
            + "whole Feature."
    }

    /// Breakdown pass only: points at the description budget, kept apart from how a contract path is read.
    /// Empty for the selection pass, and when the board enforces no budget.
    private var descriptionBudgetSentence: String {
        guard pass == .breakdown, descriptionRoom != nil else { return "" }
        return " Separately from contract paths: every Work Card's whole description must fit the board's "
            + "description budget, as Description budget sets out; a Card over it makes the breakdown "
            + "invalid output."
    }

    /// Breakdown pass only: what a Work Card's whole description is made of and how much room each
    /// repository's Card has, from the same rendering the budget check measures. Section names come from
    /// ``WorkCardDescriptionSection``, the check's own vocabulary. Plain integers: Domain formats no locale.
    private var descriptionBudgetSection: String? {
        guard pass == .breakdown, let descriptionRoom else { return nil }
        let unit = descriptionRoom.budget.limit.unit.plural
        let sections: [String] = WorkCardDescriptionSection.allCases.map { section in
            let detail: String = switch section {
            case .brief:
                "the Card's `brief`, as written."
            case .transcriptionReferences:
                "one reference per `contracts` entry, \(descriptionRoom.referenceOverhead) \(unit) each, plus "
                    + "\(descriptionRoom.pathOverhead) per path it names, plus about twice the length of its "
                    + "`repository` and of each path, range and `symbol` it names (each is written in a hidden "
                    + "stamp and in the visible line). File contents are not copied onto the Card."
            case .definitionOfDone:
                "one line per clause in the Card's `definition_of_done`, \(descriptionRoom.clauseOverhead) "
                    + "\(unit) each plus its `text` and `citation`."
            case .unitOfWork:
                "the Card's `unit_of_work`, as written."
            case .restOfManagedBlock:
                "fixed by the engine, except for the Card's `kind`, which it names."
            }
            return "- \(section.title): \(detail)"
        }
        let rooms = descriptionRoom.rooms.map { "- \($0.repository): \($0.room) \(unit)" }
        let lines = [
            "## Description budget", "",
            "Each Work Card's description on the board must fit the board's description budget of "
                + "\(descriptionRoom.budget.value) \(unit). The whole composed description counts, in these "
                + "sections:", ""
        ] + sections + [
            "",
            "Room left after \(WorkCardDescriptionSection.restOfManagedBlock.title), for a Card's `kind` and the "
                + "four sections above:", ""
        ] + rooms
        return lines.joined(separator: "\n")
    }

    /// Any pass: the invalid-output rejections of earlier Routes in this walk, so this Route drafts
    /// something that avoids them instead of repeating the refused drafting.
    private var earlierRejectionsSection: String? {
        guard !earlierRejections.isEmpty else { return nil }
        let lines = [
            "## Rejected on an earlier Route", "",
            "This pass was already drafted on another Route and rejected as invalid output. Draft one that "
                + "avoids the rejection; for a description over the budget, cut the sections it names as "
                + "largest:", ""
        ] + earlierRejections.map { "- \($0)" }
        return lines.joined(separator: "\n")
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
