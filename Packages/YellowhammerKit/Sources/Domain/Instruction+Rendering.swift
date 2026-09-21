import Foundation

extension Instruction {
    /// Renders this instruction as deterministic Markdown, in a fixed section order. Payload sections
    /// are omitted entirely when their payload is nil or empty. Uses `\n` newlines only and ends with
    /// a single trailing newline; rendering the same instruction twice yields identical output.
    public func render() -> String {
        var sections: [String] = [
            header,
            cardSection,
            briefSection,
            definitionOfDoneSection,
            repositorySection
        ]
        if let wipSection { sections.append(wipSection) }
        if let answeredQuestionSection { sections.append(answeredQuestionSection) }
        if let bankedRepliesSection { sections.append(bankedRepliesSection) }
        if let previousRoundsSection { sections.append(previousRoundsSection) }
        sections.append(resultContractSection)
        return sections.joined(separator: "\n\n") + "\n"
    }

    private var header: String {
        "# \(pass.rawValue.capitalized) pass — Card \(card.key): \(card.title)"
    }

    private var cardSection: String {
        "## Card\n\n\(card.description ?? "No description.")"
    }

    private var briefSection: String {
        var lines = ["## Architectural Brief", "", brief.prose]
        for block in brief.transcriptions {
            let mainlineLabel: String
            if let commit = block.mainlineCommit {
                mainlineLabel = commit
            } else if block.authorSupplied {
                mainlineLabel = "Operator-supplied"
            } else {
                mainlineLabel = "none"
            }
            lines.append("")
            lines.append(
                """
                ```
                Repository: \(block.repository)
                Paths: \(block.paths.joined(separator: ", "))
                Symbol: \(block.symbol ?? "none")
                Mainline: \(mainlineLabel)

                \(block.content)
                ```
                """
            )
        }
        return lines.joined(separator: "\n")
    }

    private var definitionOfDoneSection: String {
        let bullets = definitionOfDone.map { clause -> String in
            if let citation = clause.citation {
                "- [\(clause.id)] \(clause.text) (Spec: \(citation))"
            } else {
                "- [\(clause.id)] \(clause.text)"
            }
        }
        return (["## Definition of Done", ""] + bullets).joined(separator: "\n")
    }

    private var repositorySection: String {
        let checkLine: String
        switch repository.check {
        case .none:
            checkLine = "none: declared `check = none`"
        case .command(let command):
            checkLine = command
        }
        return """
            ## Repository

            Repo: \(repository.repo.name)
            Role: \(repository.repo.role.rawValue)
            Worktree path: \(repository.worktreePath)
            Feature branch: \(repository.featureBranch)
            Check: \(checkLine)
            """
    }

    private var wipSection: String? {
        guard let wip = payloads.wip else { return nil }
        var lines = [
            "## Work in progress",
            "",
            "This is context carried from an interrupted attempt: it is not known-good, and the worker "
                + "decides what to keep.",
            "",
            "Commit: \(wip.commit)"
        ]
        if let note = wip.note {
            lines.append("Note: \(note)")
        }
        return lines.joined(separator: "\n")
    }

    private var answeredQuestionSection: String? {
        guard let answered = payloads.answeredQuestion else { return nil }
        var lines = [
            "## Your earlier question, answered",
            "",
            answered.question,
            "",
            "Asked on Night \(answered.askedOn)."
        ]
        for reply in answered.replies {
            lines.append("")
            lines.append("Operator-supplied reply (\(Self.isoFormatter.string(from: reply.repliedAt))): \(reply.body)")
        }
        return lines.joined(separator: "\n")
    }

    private var bankedRepliesSection: String? {
        guard !payloads.bankedReplies.isEmpty else { return nil }
        var lines = [
            "## Banked replies",
            "",
            "These replies are dated, Operator-supplied, unverified, and must be judged against the "
                + "repositories as they now stand."
        ]
        for reply in payloads.bankedReplies {
            lines.append("")
            lines.append("- Night \(reply.night), comment \(reply.commentID): \(reply.body)")
            for (repoName, commit) in reply.mainlineCommits.sorted(by: { $0.key < $1.key }) {
                lines.append("  - \(repoName): mainline as of that Night was \(commit)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private var previousRoundsSection: String? {
        guard !payloads.roundFeedback.isEmpty else { return nil }
        var lines = ["## Previous rounds", ""]
        for round in payloads.roundFeedback {
            var entry = "- Round \(round.round) (\(round.lens.rawValue)): verdict \(round.verdict)"
            if let requestedChanges = round.requestedChanges {
                entry += "; requested changes: \(requestedChanges)"
            }
            if let judgedCommit = round.judgedCommit {
                entry += "; judged commit: \(judgedCommit)"
            }
            lines.append(entry)
        }
        return lines.joined(separator: "\n")
    }

    private var resultContractSection: String {
        var text = """
            ## Result contract

            Write the result file to `\(resultFilePath)` on completion. It must declare \
            `"schema": "\(pass.schemaIdentifier)"` and `"version": 1`. Permitted outcomes for this pass: \
            \(permittedOutcomes.joined(separator: ", ")). An empty or missing result file is treated as a crash.
            """
        if let authoringInvariantSentence {
            text += " \(authoringInvariantSentence)"
        }
        return text
    }

    /// Only the architect and worker passes ever discover a Card cannot be completed against the
    /// repositories as authored (graph-execution/handle-a-block-mid-graph, P8.9): Cards in a Feature
    /// never depend on Cards, so this is an authoring-invariant violation, not an ordering failure.
    private var authoringInvariantSentence: String? {
        switch pass {
        case .architect, .worker:
            return "Cards in a Feature never depend on each other; if this Card cannot be completed "
                + "without work another Card has yet to do, report `failed` and describe that work in "
                + "`authoring_invariant_violation`."
        case .reviewer, .selection, .breakdown, .verifier:
            return nil
        }
    }

    private var permittedOutcomes: [String] {
        switch pass {
        case .architect: ["planned", "failed"]
        case .worker: ["completed", "question", "failed"]
        case .reviewer: ["approved", "changes_requested"]
        case .selection, .breakdown, .verifier: []
        }
    }

    private static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
