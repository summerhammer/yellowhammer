import Domain
import Foundation
import Journal

public struct DoDClause: Equatable, Sendable {
    public var cid: String
    public var text: String
    public var citation: String
    public var citationProvenance: String

    public init(_ record: ClauseRecord) {
        self.cid = record.cid
        self.text = record.text
        self.citation = record.locationID
        self.citationProvenance = record.citationProvenance
    }

    public init(cid: String, text: String, citation: String, citationProvenance: String) {
        self.cid = cid
        self.text = text
        self.citation = citation
        self.citationProvenance = citationProvenance
    }
}

/// Account of a single Round within an Attempt.
public struct RoundAccount: Equatable, Sendable {
    public var lens: Lens
    public var verdict: String
    public var requestedChanges: String?
    public var judgedCommit: String?

    public init(lens: Lens, verdict: String, requestedChanges: String? = nil, judgedCommit: String? = nil) {
        self.lens = lens
        self.verdict = verdict
        self.requestedChanges = requestedChanges
        self.judgedCommit = judgedCommit
    }
}

public struct AttemptAccount: Equatable, Sendable {
    public var ordinal: Int
    public var route: Route
    public var checkResult: String
    public var rounds: [RoundAccount]
    public var outcome: String  // attempt.result, or "in progress" when open
    public var consumedHow: String?

    /// `checkRuns` is this Attempt's own `checkRan` runs, in append order (required, with no default: the
    /// Check result comes from them, never from Rounds, which only a failed judgement writes).
    public init(ordinal: Int, record: AttemptRecord, checkRuns: [CheckRunRecord]) {
        self.ordinal = ordinal
        self.route = record.route
        self.checkResult = Self.checkResult(checkDeclaredNone: record.checkDeclaredNone, runs: checkRuns)

        // Build round accounts
        self.rounds = record.rounds.map {
            RoundAccount(
                lens: $0.lens, verdict: $0.verdict, requestedChanges: $0.requestedChanges,
                judgedCommit: $0.judgedCommit
            )
        }

        // Outcome: result or "in progress"
        self.outcome = record.result ?? Self.inProgressWording

        self.consumedHow = record.consumedHow
    }

    static let noCheckWording = "green came from a model alone (`check = none`)"
    static let checkNotRunWording = "not run"
    static let inProgressWording = "in progress"

    /// The Check result of one Attempt, from its `checkRan` runs in append order: its last run's result,
    /// the commit it judged when recorded, and how many earlier runs failed (`passed on `b763aff` after 1
    /// failed run`). A passing Check writes no Round, so Rounds say nothing about the final result. Shared
    /// by the Managed Block and the Night Card so the two never word it differently.
    public static func checkResult(checkDeclaredNone: Bool, runs: [CheckRunRecord]) -> String {
        if checkDeclaredNone || runs.last?.result == .declaredNone {
            return noCheckWording
        }
        guard let last = runs.last else {
            return checkNotRunWording
        }
        let earlierFailures = runs.dropLast().filter { $0.result == .failed }.count
        return checkResult(last: last.result, judgedCommit: last.judgedCommit, earlierFailures: earlierFailures)
    }

    /// The wording of a Check result that ran: closed vocabulary, a commit and a count — never free text.
    static func checkResult(last: CheckRunResult, judgedCommit: String?, earlierFailures: Int) -> String {
        var text = last.rawValue
        if let judgedCommit {
            text += " on `\(judgedCommit)`"
        }
        if earlierFailures > 0 {
            text += " after \(earlierFailures) failed run\(earlierFailures == 1 ? "" : "s")"
        }
        return text
    }
}

/// A failed Adoption's notice for the Managed Block (roadmap P11.5): what moved in which repository,
/// naming the Feature that tried to adopt, and that a human turn is needed. Rendered only while the
/// Card is Waiting on You under `divergence` because of this refusal — never posted as a comment.
public struct AdoptionRefusalNotice: Equatable, Sendable {
    public var featureName: String
    public var staleBlocks: [AdoptionStaleBlock]

    public init(featureName: String, staleBlocks: [AdoptionStaleBlock]) {
        self.featureName = featureName
        self.staleBlocks = staleBlocks
    }

    func render() -> [String] {
        var lines = [
            "### Adoption not completed",
            "The Feature '\(featureName)' tried to adopt this Card, but its recorded contract had moved:"
        ]
        for block in staleBlocks {
            lines.append("- \(block.repository): \(block.changedPaths.joined(separator: ", "))")
        }
        lines.append(
            "This Card was not adopted. A human turn is needed: cancel it, or author the replacement " +
                "work as new work with fresh budgets."
        )
        return lines
    }
}

/// A Card's un-adopted standing (roadmap P12.1): rendered on the Card's own Managed Block header
/// beside its state, from the same derivation the Night Summary's standing line reads
/// (`JournalStore.unadoptedCards(asOf:)`), so the two figures never disagree.
public struct UnadoptedStanding: Equatable, Sendable {
    public var closedFeatureIssueID: String
    public var elapsedNights: Int

    public init(closedFeatureIssueID: String, elapsedNights: Int) {
        self.closedFeatureIssueID = closedFeatureIssueID
        self.elapsedNights = elapsedNights
    }
}

/// The reported repository and missing work from an authoring-invariant violation, rendered in the
/// Managed Block when a Card is Blocked under `authoring defect` (Missing Upstream Ruling 2026-10-15,
/// OQ175).
public struct AuthoringDefectNotice: Equatable, Sendable {
    public var detail: String

    public init(detail: String) {
        self.detail = detail
    }

    /// Extracts the reported violation from the durable `reason` recorded alongside
    /// `AuthoringInvariantBroken`. The report is model-authored and may itself contain quotes, so it
    /// ends at the reason's last quote: what follows it, the likely hole's issue ids, never has one.
    public static func extractDetail(from reason: String) -> String {
        guard let start = reason.range(of: "Reported: \"") else {
            return reason
        }
        let after = reason[start.upperBound...]
        if let end = after.lastIndex(of: "\"") {
            return String(after[..<end])
        }
        return String(after)
    }
}

public struct CardManagedBlock: Equatable, Sendable {
    public var kind: String
    public var repository: String
    public var scope: [String]
    /// The `Card override:` lines the Operator last saved, exactly as written (roadmap P22.7); none renders
    /// the empty form. Supported human input, so a rewrite carries it through unchanged — malformed or
    /// duplicated included — and every compaction rung keeps it.
    public var cardOverride: [String]
    public var state: CardState
    public var blockReason: String?
    public var lanePosition: Int
    public var laneLength: Int
    public var brief: ArchitecturalBrief
    public var definitionOfDone: [DoDClause]
    public var attempts: [AttemptAccount]
    /// The current budget epoch's Attempt consumption (roadmap P8.7), or nil for a Card with no Attempt
    /// in it yet. Read straight from the Journal (``AttemptHistory/consumption(inEpoch:)``): nothing here
    /// is model-authored.
    public var attemptConsumption: AttemptConsumption?
    /// The most Attempts one budget epoch may consume (`attempts_per_work_card`), when the block's builder
    /// holds it; nil renders the consumption account without a Bound to compare it to, rather than
    /// plumbing configuration through a layer that otherwise holds none.
    public var attemptsPerWorkCard: Int?
    /// Set when this Card is Blocked under `failure recurrence` (roadmap P8.8; OQ127): the recurring
    /// cause and how many Nights met it. Nil for every other Card.
    public var failureRecurrence: FailureRecurrence?
    /// The Card's latest adoption refusal (roadmap P11.5), rendered only while the Card is Waiting on
    /// You under `divergence` because of it; nil otherwise, or once a later readiness Divergence
    /// supersedes it. A second refusal replaces this notice rather than stacking beside it.
    public var adoptionRefusalNotice: AdoptionRefusalNotice?
    /// Set when this Card is left Blocked by a closed Feature (roadmap P12.1); nil for every other
    /// Card, and nil ⇒ the rendered output is byte-identical to before this field existed.
    public var unadoptedStanding: UnadoptedStanding?
    /// Set when this Card is Blocked under `authoring defect` (Missing Upstream Ruling 2026-10-15, OQ175):
    /// the reported repository and missing work from durable Journal data. Nil for every other Card.
    public var authoringDefectNotice: AuthoringDefectNotice?

    /// The Definition of Done section's one line while no clause is authored. The description room is
    /// measured against it, as the line n clauses replace.
    static let noClausesLine = "_No clauses authored._"

    public static let footer = "_Managed by Yellowhammer. This block is rewritten from the Journal; " +
        "write outside it and your text is kept._"

    public init(
        kind: String,
        repository: String,
        scope: [String] = [],
        cardOverride: [String] = [],
        state: CardState,
        blockReason: String? = nil,
        lanePosition: Int,
        laneLength: Int,
        brief: ArchitecturalBrief,
        definitionOfDone: [DoDClause],
        attempts: [AttemptAccount],
        attemptConsumption: AttemptConsumption? = nil,
        attemptsPerWorkCard: Int? = nil,
        failureRecurrence: FailureRecurrence? = nil,
        adoptionRefusalNotice: AdoptionRefusalNotice? = nil,
        unadoptedStanding: UnadoptedStanding? = nil,
        authoringDefectNotice: AuthoringDefectNotice? = nil
    ) {
        self.kind = kind
        self.repository = repository
        self.scope = scope
        self.cardOverride = cardOverride
        self.state = state
        self.blockReason = blockReason
        self.lanePosition = lanePosition
        self.laneLength = laneLength
        self.brief = brief
        self.definitionOfDone = definitionOfDone
        self.attempts = attempts
        self.attemptConsumption = attemptConsumption
        self.attemptsPerWorkCard = attemptsPerWorkCard
        self.failureRecurrence = failureRecurrence
        self.adoptionRefusalNotice = adoptionRefusalNotice
        self.unadoptedStanding = unadoptedStanding
        self.authoringDefectNotice = authoringDefectNotice
    }

    public func render() -> String {
        render(compaction: AttemptsCompaction())
    }

    func render(compaction: AttemptsCompaction) -> String {
        var lines: [String] = []

        // Blocked headline: the precise Block Reason and the next action lead the managed content, so
        // the State line below does not repeat the reason.
        let headlineReason = blockReason.flatMap { state == .blocked ? BlockReason(rawValue: $0) : nil }
        if let headlineReason {
            lines.append(headlineReason.blockedHeadline)
            if let note = headlineReason.blockedNote { lines.append(note) }
        }

        // Kind line
        lines.append("**Kind:** `\(kind)`")

        // Repository line
        lines.append("**Repository:** `\(repository)`")

        // Scope line
        if scope.isEmpty {
            lines.append("**Scope:** _none declared_")
        } else {
            lines.append("**Scope:** \(scope.map { "`\($0)`" }.joined(separator: ", "))")
        }

        // Card override line: supported input, outside the prose brief, rendered even when empty so the
        // Operator has the field to fill in.
        lines.append(contentsOf: CardOverrideField.renderedLines(cardOverride))

        // State line
        var stateLine: String
        if let blockReason = blockReason, headlineReason == nil {
            stateLine = "**State:** \(state.rawValue) — \(blockReason)"
        } else {
            stateLine = "**State:** \(state.rawValue)"
        }
        if let unadoptedStanding {
            let nightWord = unadoptedStanding.elapsedNights == 1 ? "Night" : "Nights"
            stateLine += " · un-adopted for \(unadoptedStanding.elapsedNights) \(nightWord) since Feature " +
                "`\(unadoptedStanding.closedFeatureIssueID)` closed"
        }
        lines.append(stateLine)
        if let failureRecurrence {
            lines.append("**Failure-Cause Recurrence:** \(failureRecurrence.reason)")
        }
        if let authoringDefectNotice {
            lines.append("**Authoring Defect:** \(authoringDefectNotice.detail)")
        }

        // Repo Lane position
        lines.append("**Repo Lane position:** \(lanePosition) of \(laneLength)")

        // Architectural Brief section
        lines.append("")
        lines.append("### Architectural Brief")
        lines.append(contentsOf: ArchitecturalBriefProseRegion.render(brief.prose))

        // Transcriptions
        lines.append(contentsOf: renderTranscriptions())

        // Definition of Done section
        lines.append(contentsOf: renderDefinitionOfDone())

        // Attempts section
        lines.append(contentsOf: renderAttempts(compaction: compaction))

        if let adoptionRefusalNotice {
            lines.append("")
            lines.append(contentsOf: adoptionRefusalNotice.render())
        }

        // Footer
        lines.append(Self.footer)

        return lines.joined(separator: "\n")
    }

    func renderTranscriptions() -> [String] {
        brief.transcriptions.flatMap { TranscriptionBlockLine.render($0) }
    }

    func renderDefinitionOfDone() -> [String] {
        var lines: [String] = []
        lines.append("")
        lines.append("### Definition of Done")
        if definitionOfDone.isEmpty {
            lines.append(Self.noClausesLine)
        } else {
            for clause in definitionOfDone {
                lines.append(
                    DefinitionOfDoneClauseLine.render(cid: clause.cid, text: clause.text, citation: clause.citation)
                )
            }
        }
        return lines
    }
}
