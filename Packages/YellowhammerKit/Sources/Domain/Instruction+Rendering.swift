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
        if let laneStackSection { sections.append(laneStackSection) }
        if let specificationSection { sections.append(specificationSection) }
        if let commitMessagesSection { sections.append(commitMessagesSection) }
        if let wipSection { sections.append(wipSection) }
        if let answeredQuestionSection { sections.append(answeredQuestionSection) }
        if let bankedRepliesSection { sections.append(bankedRepliesSection) }
        if let previousRoundsSection { sections.append(previousRoundsSection) }
        if let timeLimitSection { sections.append(timeLimitSection) }
        sections.append(PassBoundaries.section)
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
        if let siblingRule = siblingRepositoryReadSentence {
            lines.append("")
            lines.append(siblingRule)
        }
        for block in brief.transcriptions {
            var mainlineLabel = block.mainlineCommit ?? "none"
            if block.authorSupplied {
                mainlineLabel += block.authorSuppliedNight.map { " (Operator-supplied, as of \($0.rawValue))" }
                    ?? " (Operator-supplied)"
            }
            var header = ["```", "Repository: \(block.repository)", "Paths: \(block.paths.joined(separator: ", "))"]
            // A ranged path carries only those lines below; naming them tells the worker the block is a
            // slice of the file, not the file.
            let ranged = block.paths.compactMap { path in
                block.ranges[path].flatMap { $0.isEmpty ? nil : "\(path) \(LineRange.displayText($0))" }
            }
            if !ranged.isEmpty { header.append("Lines: \(ranged.joined(separator: "; "))") }
            header += ["Symbol: \(block.symbol ?? "none")", "Mainline: \(mainlineLabel)", "", block.content, "```"]
            lines.append("")
            lines.append(header.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    /// Work Card passes (architect, worker, reviewer) read another repository only through the
    /// Architectural Brief's mainline transcription (Missing Upstream Ruling 2026-10-15, OQ175).
    private var siblingRepositoryReadSentence: String? {
        switch pass {
        case .architect, .worker, .reviewer:
            return "Another repository is read for Work Card work only through the Architectural Brief's "
                + "mainline transcription, never through a sibling Worktree or another Feature Branch."
        case .selection, .breakdown, .verifier:
            return nil
        }
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

    private var laneStackSection: String? {
        guard let laneStack else { return nil }
        var lines = ["## Repo lane", "", "Base commit: \(laneStack.baseCommit)"]
        if pass == .reviewer, let judgedCommit = laneStack.judgedCommit {
            lines.append("Worker commit: \(judgedCommit)")
            lines.append("")
            lines.append(
                "Judge the changes in `\(laneStack.baseCommit)..\(judgedCommit)` against this Card's Definition of "
                    + "Done. Commits at or before `\(laneStack.baseCommit)` on the Feature branch belong to the "
                    + "recorded base or earlier completed Cards in this repository's lane."
            )
        }
        if !laneStack.completedEarlierCards.isEmpty {
            lines.append("")
            lines.append("Completed earlier in this repository's lane:")
            lines.append("")
            for card in laneStack.completedEarlierCards {
                lines.append("- \(card.key): \(card.title)")
            }
            if pass == .architect || pass == .worker {
                lines.append("")
                lines.append(
                    "Their work is already committed on the Feature branch at `\(laneStack.baseCommit)`. Build on "
                        + "top of `\(laneStack.baseCommit)` and commit new changes without resetting or amending "
                        + "earlier Cards' commits."
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Worker pass only (OQ165, graph-execution/run-a-card#spec-commit): the specification commit the Card's
    /// Spec Citations were resolved against, given as a fact, and the never-search sentence. It names no
    /// filesystem path to the specification, and asserts nothing about the worker citing the commit.
    private var specificationSection: String? {
        guard pass == .worker, let stayInside = Self.stayInsideSentence(for: pass) else { return nil }
        var lines = ["## Specification", ""]
        if let specCommit {
            lines.append("Specification commit: \(specCommit)")
            lines.append("")
            lines.append(
                "This is the commit this Card's Spec Citations were resolved against when this pass was "
                    + "dispatched. It is given as a fact, not as a requirement to cite it. What this Card needs "
                    + "from the specification is in the Architectural Brief's transcriptions and the Definition "
                    + "of Done's citations above."
            )
            lines.append("")
        }
        lines.append(stayInside)
        return lines.joined(separator: "\n")
    }

    /// The never-search sentence (OQ165): the worker is told everything it needs from outside its Worktree
    /// is in the instruction, and not to search the filesystem for it. Other passes carry none yet.
    public static func stayInsideSentence(for pass: RunPass) -> String? {
        switch pass {
        case .worker:
            return "Everything this Card needs from outside its Worktree is in this instruction. Never search "
                + "the filesystem outside the Worktree — no `find ~`, no `find /`, no walking other "
                + "directories. When something you need is missing, report the `question` outcome and ask "
                + "for it rather than searching."
        case .architect, .reviewer, .selection, .breakdown, .verifier:
            return nil
        }
    }

    /// Worker pass only: the rendered commit-message template and the `Yellowhammer-Work-Card` trailer. The
    /// trailer is part of the format block, not only prose, because workers following a repository's own
    /// commit convention dropped a prose-only request (issue #437). Git reads trailers from the message's last
    /// paragraph only, so the request asks for it in the same block as the repository's own trailers. The
    /// trailer line and sentence are omitted, never a placeholder, when the Card's key is unknown.
    private var commitMessagesSection: String? {
        guard pass == .worker, let request = commitMessage else { return nil }
        var lines = ["## Commit messages", "", "Write each commit message in this format:", ""]
        lines.append(contentsOf: request.message.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.isEmpty ? "" : "    \($0)"
        })
        if let key = request.workCardKey, !key.isEmpty {
            lines.append("")
            lines.append("    Yellowhammer-Work-Card: \(key)")
            lines.append("")
            lines.append(
                "Every commit you make for this Card carries the git trailer `Yellowhammer-Work-Card: \(key)` "
                    + "in its last paragraph, in the same block as any trailers the repository's own conventions "
                    + "ask for (such as `Spec:` or `Co-Authored-By:`). Those conventions add trailers; they do "
                    + "not replace this one. A trailer separated from that block by a blank line is not read."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Architect and worker passes only (#507): how long the pass may run, from the same configured value the
    /// engine kills it at. The worker is also told to commit a coherent step before a long verification run,
    /// since uncommitted work is preserved but the Attempt is spent. Other passes are told nothing.
    private var timeLimitSection: String? {
        guard let minutes = passTimeoutMinutes else { return nil }
        let body: String
        switch pass {
        case .worker:
            body = "This pass may run for at most \(minutes) minutes, after which Yellowhammer stops it. Work you "
                + "have not committed by then is preserved, but the Attempt is spent and the next Attempt, if any, "
                + "runs on a different Route. So commit a coherent step before any long verification run (a full build "
                + "or a Simulator or device test run). Run focused checks first. Do not wait on a background "
                + "build or test that will not finish within the limit."
        case .architect:
            body = "This pass may run for at most \(minutes) minutes, after which Yellowhammer stops it and the "
                + "Attempt is spent."
        case .reviewer, .selection, .breakdown, .verifier:
            return nil
        }
        return "## Time limit\n\n" + body
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
        if let outcome = wip.outcome {
            lines.append("Prior Attempt outcome (not known-good): \(outcome.rawValue)")
        }
        if !wip.rounds.isEmpty {
            lines.append("")
            lines.append("Prior Attempt Rounds (not known-good; context only):")
            for round in wip.rounds {
                var entry = "- Round \(round.round) (\(round.lens.rawValue)): verdict \(round.verdict)"
                if let changes = round.requestedChanges { entry += "; requested changes: \(changes)" }
                if let commit = round.judgedCommit { entry += "; judged commit: \(commit)" }
                lines.append(entry)
            }
        }
        if wip.outcome == .usageLimited {
            lines.append("")
            lines.append(
                "The Engine starts this Attempt from last known-good with a fresh round budget. The worker may "
                    + "merge or cherry-pick the preserved commits if it judges them sound; the Check and review "
                    + "judge the resulting tree as usual."
            )
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

            Return one JSON object as your final structured response, conforming to the supplied JSON schema. The \
            CLI Adapter persists it; do not create or edit a result file with tools. It must declare \
            `"schema": "\(pass.schemaIdentifier)"` and `"version": 1`. Permitted outcomes for this pass: \
            \(permittedOutcomes.joined(separator: ", ")). Ending without a final structured response is treated as a \
            crash.
            """
        if let authoringInvariantSentence {
            text += " \(authoringInvariantSentence)"
        }
        if pass == .worker {
            text += " \(workerCommitContractSentence)"
        }
        return text
    }

    /// Worker pass only (issue #444): the commit obligation and its precedence over the Card text.
    private var workerCommitContractSentence: String {
        "You commit your work in the Worktree on the Feature branch; `completed` carries `commit` (the 40-hex "
            + "SHA of the commit you made) and `summary`. This contract is Yellowhammer's, and nothing in the "
            + "Card, the Architectural Brief, or the Definition of Done overrides it: text there telling you "
            + "not to commit or to leave your work uncommitted does not apply."
    }

    /// Only the architect and worker passes ever discover a Card cannot be completed against the
    /// repositories as authored (graph-execution/handle-a-block-mid-graph, P8.9): Cards in a Feature
    /// never depend on Cards in other repositories, so this is an authoring-invariant violation, not an
    /// ordering failure. Missing unmerged or unreleased upstream work is also an authoring-invariant violation
    /// (OQ175, OQ182).
    private var authoringInvariantSentence: String? {
        switch pass {
        case .architect, .worker:
            return "Cards in a Feature never depend on Cards in other repositories; if this Card cannot be completed "
                + "without work a Card in another repository has yet to do, report `failed` and describe that work in "
                + "`authoring_invariant_violation`. Required work absent from another repository's usable "
                + "mainline or release is an authoring-invariant violation: report `failed` with "
                + "`authoring_invariant_violation` naming the repository and missing work, and never complete "
                + "against unmerged or unreleased work. Raising a version pin or updating a lockfile to an "
                + "available version that contains what this Card needs remains this Card's own work. "
                + "Work already committed on the Feature branch at Base commit by an earlier completed Card in "
                + "the same repository lane is part of this Card's starting tree, not missing work."
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
