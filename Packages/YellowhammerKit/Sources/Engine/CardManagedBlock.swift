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

    public init(ordinal: Int, record: AttemptRecord) {
        self.ordinal = ordinal
        self.route = record.route

        // Determine check result
        if record.checkDeclaredNone {
            self.checkResult = "green came from a model alone (`check = none`)"
        } else {
            // Find the last round with lens == .check
            if let checkRound = record.rounds.last(where: { $0.lens == .check }) {
                self.checkResult = checkRound.verdict
            } else {
                self.checkResult = "not recorded"
            }
        }

        // Build round accounts
        self.rounds = record.rounds.map {
            RoundAccount(
                lens: $0.lens, verdict: $0.verdict, requestedChanges: $0.requestedChanges,
                judgedCommit: $0.judgedCommit
            )
        }

        // Outcome: result or "in progress"
        self.outcome = record.result ?? "in progress"

        self.consumedHow = record.consumedHow
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

public struct CardManagedBlock: Equatable, Sendable {
    public var kind: String
    public var repository: String
    public var scope: [String]
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
    /// Set when Failure-Cause Recurrence promoted this Blocked Card to Triage (roadmap P8.8); nil for a
    /// first occurrence, which Blocks like any other.
    public var triagePromotion: TriagePromotion?
    /// The Card's latest adoption refusal (roadmap P11.5), rendered only while the Card is Waiting on
    /// You under `divergence` because of it; nil otherwise, or once a later readiness Divergence
    /// supersedes it. A second refusal replaces this notice rather than stacking beside it.
    public var adoptionRefusalNotice: AdoptionRefusalNotice?
    /// Set when this Card is left Blocked by a closed Feature (roadmap P12.1); nil for every other
    /// Card, and nil ⇒ the rendered output is byte-identical to before this field existed.
    public var unadoptedStanding: UnadoptedStanding?

    public static let footer = "_Managed by Yellowhammer. This block is rewritten from the Journal; " +
        "write outside it and your text is kept._"

    public init(
        kind: String,
        repository: String,
        scope: [String] = [],
        state: CardState,
        blockReason: String? = nil,
        lanePosition: Int,
        laneLength: Int,
        brief: ArchitecturalBrief,
        definitionOfDone: [DoDClause],
        attempts: [AttemptAccount],
        attemptConsumption: AttemptConsumption? = nil,
        attemptsPerWorkCard: Int? = nil,
        triagePromotion: TriagePromotion? = nil,
        adoptionRefusalNotice: AdoptionRefusalNotice? = nil,
        unadoptedStanding: UnadoptedStanding? = nil
    ) {
        self.kind = kind
        self.repository = repository
        self.scope = scope
        self.state = state
        self.blockReason = blockReason
        self.lanePosition = lanePosition
        self.laneLength = laneLength
        self.brief = brief
        self.definitionOfDone = definitionOfDone
        self.attempts = attempts
        self.attemptConsumption = attemptConsumption
        self.attemptsPerWorkCard = attemptsPerWorkCard
        self.triagePromotion = triagePromotion
        self.adoptionRefusalNotice = adoptionRefusalNotice
        self.unadoptedStanding = unadoptedStanding
    }

    public func render() -> String {
        var lines: [String] = []

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

        // State line
        var stateLine: String
        if let blockReason = blockReason {
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
        if let triagePromotion {
            lines.append("**Promoted to Triage:** \(triagePromotion.reason)")
        }

        // Repo Lane position
        lines.append("**Repo Lane position:** \(lanePosition) of \(laneLength)")

        // Architectural Brief section
        lines.append("")
        lines.append("### Architectural Brief")
        lines.append(brief.prose)

        // Transcriptions
        lines.append(contentsOf: renderTranscriptions())

        // Definition of Done section
        lines.append(contentsOf: renderDefinitionOfDone())

        // Attempts section
        lines.append(contentsOf: renderAttempts())

        if let adoptionRefusalNotice {
            lines.append("")
            lines.append(contentsOf: adoptionRefusalNotice.render())
        }

        // Footer
        lines.append(Self.footer)

        return lines.joined(separator: "\n")
    }

    private func renderTranscriptions() -> [String] {
        var lines: [String] = []
        for transcription in brief.transcriptions {
            let commitStr: String
            if transcription.authorSupplied, let night = transcription.authorSuppliedNight {
                commitStr = "Operator-supplied as of \(night.rawValue)"
            } else if transcription.authorSupplied {
                commitStr = "Operator-supplied"
            } else {
                commitStr = transcription.mainlineCommit ?? "Operator-supplied"
            }
            lines.append(contentsOf: TranscriptionBlockLine.render(transcription, commitField: commitStr))
        }
        return lines
    }

    private func renderDefinitionOfDone() -> [String] {
        var lines: [String] = []
        lines.append("")
        lines.append("### Definition of Done")
        if definitionOfDone.isEmpty {
            lines.append("_No clauses authored._")
        } else {
            for clause in definitionOfDone {
                lines.append(
                    DefinitionOfDoneClauseLine.render(cid: clause.cid, text: clause.text, citation: clause.citation)
                )
            }
        }
        return lines
    }

    private func renderAttempts() -> [String] {
        var lines: [String] = []
        lines.append("")
        lines.append("### Attempts")
        if attempts.isEmpty {
            lines.append("_No Attempt yet._")
        } else {
            if let attemptConsumption {
                let bound = attemptsPerWorkCard.map { " of \($0) allowed" } ?? ""
                lines.append("- \(attemptConsumption.description)\(bound)")
            }
            for (index, attempt) in attempts.enumerated() {
                if index > 0 {
                    lines.append("")
                }
                lines.append("#### Attempt \(attempt.ordinal) — `\(attempt.route.description)`")
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
            }
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
