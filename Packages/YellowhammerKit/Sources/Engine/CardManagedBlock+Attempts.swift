import Domain
import Foundation
import Journal

/// How far a Work Card's Attempts section is compacted (spec: board-projection/maintain-the-managed-block,
/// "budget on rewrite"). The default is the full rendering.
struct AttemptsCompaction: Equatable {
    /// The oldest this many Attempts keep a one-line account instead of their detail.
    var oneLineCount = 0
    /// Every Attempt but the latest collapses into one "N earlier Attempts" line.
    var collapsesEarlier = false
    /// The latest Attempt's detail is a one-line account too.
    var latestIsOneLine = false
    /// When set, the whole Attempts section is this text instead: the room a later rewrite needs
    /// (``CardManagedBlock/widestCompactedAttemptsSection(longestRoute:)``).
    var reservedSection: String?
}

extension CardManagedBlock {
    /// The renderings of this block from the full one to the most compacted, for a write that must stay
    /// within the Board Connection's description budget; the first is always ``render()``. Detail leaves
    /// the Attempts section in this order: each older Attempt, oldest first, keeps a one-line account;
    /// then every account but the latest collapses into one line; last, the latest Attempt is a one-line
    /// account too. Fully compacted, the section is at most two lines beside its consumption line.
    /// Everything else in the block is untouched, so the parser reads every rendering the same.
    public func renderings() -> [String] {
        let count = attempts.count
        var rungs = [AttemptsCompaction()]
        if count > 1 {
            rungs += (1..<count).map { AttemptsCompaction(oneLineCount: $0) }
            rungs.append(AttemptsCompaction(collapsesEarlier: true))
        }
        if count > 0 {
            rungs.append(AttemptsCompaction(collapsesEarlier: count > 1, latestIsOneLine: true))
        }
        var result: [String] = []
        for rung in rungs {
            let rendered = render(compaction: rung)
            if result.last != rendered { result.append(rendered) }
        }
        return result
    }

    /// The Attempts section at its most compacted, at its widest: the longest Route id, the longest Check
    /// and outcome wording of the closed vocabulary (a commit is 40 characters; no wording here is free
    /// text), and two-digit counts, with the consumption account and the collapsed-earlier line. What a Work
    /// Card must leave room for at authoring, so that a later rewrite can always compact to fit. It stands
    /// in for the `_No Attempt yet._` section.
    public static func widestCompactedAttemptsSection(longestRoute: Route) -> String {
        let checks = CheckRunResult.allCases.filter { $0 != .declaredNone }.map {
            AttemptAccount.checkResult(last: $0, judgedCommit: String(repeating: "f", count: 40), earlierFailures: 99)
        } + [AttemptAccount.noCheckWording, AttemptAccount.checkNotRunWording]
        let outcomes = AttemptOutcome.allCases.map(\.rawValue) + [AttemptAccount.inProgressWording]
        let consumption = AttemptConsumption(
            consumed: 99, routesFailed: 99, roundsExhausted: 99, crashedUnknown: 99, succeeded: 99, notConsumed: 99
        )
        var lines = ["", "### Attempts", "- \(consumption.description) of 99 allowed"]
        lines.append(earlierAttemptsLine(count: 99))
        lines.append(attemptLine(
            ordinal: 99, route: longestRoute.description, check: checks.max { $0.count < $1.count } ?? "",
            rounds: 99, outcome: outcomes.max { $0.count < $1.count } ?? ""
        ))
        return lines.joined(separator: "\n")
    }

    /// This block as a later rewrite would render it at its largest: its Attempts section replaced by the
    /// widest fully compacted one, whatever Attempts it holds now.
    func renderReservingAttempts(longestRoute: Route) -> String {
        render(compaction: AttemptsCompaction(
            reservedSection: Self.widestCompactedAttemptsSection(longestRoute: longestRoute)
        ))
    }

    static func earlierAttemptsLine(count: Int) -> String {
        "- \(count) earlier Attempt\(count == 1 ? "" : "s") — see the Journal"
    }

    static func attemptLine(ordinal: Int, route: String, check: String, rounds: Int, outcome: String) -> String {
        "- Attempt \(ordinal) — `\(route)` · Check: \(check) · Rounds: \(rounds) · Outcome: \(outcome)"
    }

    func renderAttempts(compaction: AttemptsCompaction) -> [String] {
        if let reserved = compaction.reservedSection {
            return reserved.components(separatedBy: "\n")
        }
        var lines: [String] = []
        lines.append("")
        lines.append("### Attempts")
        if attempts.isEmpty {
            lines.append("_No Attempt yet._")
            return lines
        }
        if let attemptConsumption {
            let bound = attemptsPerWorkCard.map { " of \($0) allowed" } ?? ""
            lines.append("- \(attemptConsumption.description)\(bound)")
        }
        let latestIndex = attempts.count - 1
        if compaction.collapsesEarlier, latestIndex > 0 {
            lines.append(Self.earlierAttemptsLine(count: latestIndex))
        }
        for (index, attempt) in attempts.enumerated() {
            if compaction.collapsesEarlier, index < latestIndex { continue }
            if index < compaction.oneLineCount || (index == latestIndex && compaction.latestIsOneLine) {
                lines.append(Self.attemptLine(
                    ordinal: attempt.ordinal, route: attempt.route.description, check: attempt.checkResult,
                    rounds: attempt.rounds.count, outcome: attempt.outcome
                ))
                continue
            }
            if index > 0 {
                lines.append("")
            }
            lines.append(contentsOf: renderAttemptDetail(attempt))
        }
        return lines
    }

    private func renderAttemptDetail(_ attempt: AttemptAccount) -> [String] {
        var lines = ["#### Attempt \(attempt.ordinal) — `\(attempt.route.description)`"]
        lines.append("- Check: \(attempt.checkResult)")
        if attempt.rounds.isEmpty {
            lines.append("- Rounds: none")
        } else {
            let roundTexts = attempt.rounds.enumerated().map { roundIndex, round in
                "\(roundIndex + 1). \(round.lens.rawValue) — \(round.verdict)"
            }
            lines.append("- Rounds: \(roundTexts.joined(separator: "; "))")
            lines.append(contentsOf: renderRoundDetails(attempt.rounds))
        }
        lines.append("- Outcome: \(attempt.outcome)")
        if let consumedHow = attempt.consumedHow {
            lines.append("- Consumed: \(consumedHow)")
        }
        return lines
    }

    /// The judged commit and requested changes of each Round that has one: the one-line summary above
    /// names every Round, this fills in what it judged. Quoted (`> `) so neither a heading nor a list
    /// marker in a model's text can be read back as part of the Managed Block's own markdown.
    private func renderRoundDetails(_ rounds: [RoundAccount]) -> [String] {
        var lines: [String] = []
        for (index, round) in rounds.enumerated() {
            let ordinal = index + 1
            if let commit = round.judgedCommit {
                lines.append("  - Round \(ordinal) judged commit: `\(commit)`")
            }
            if let requestedChanges = round.requestedChanges, !requestedChanges.isEmpty {
                lines.append("  - Round \(ordinal) requested changes:")
                lines.append(contentsOf: Self.quoteRequestedChanges(requestedChanges))
            }
        }
        return lines
    }

    /// The Round's requested changes, capped and quoted for the Managed Block: over the character limit,
    /// truncated with an explicit marker (the full text is in the Round's own Card comment and the
    /// Journal); every line prefixed so it can never start a Markdown heading or list item of its own.
    private static let requestedChangesLimit = 500

    private static func quoteRequestedChanges(_ text: String) -> [String] {
        let capped = text.count > requestedChangesLimit
            ? "\(text.prefix(requestedChangesLimit))… truncated"
            : text
        return capped.components(separatedBy: "\n").map { "    > \($0)" }
    }
}
