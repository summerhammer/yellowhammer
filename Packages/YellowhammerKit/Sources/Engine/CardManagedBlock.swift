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
        attempts: [AttemptAccount]
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
        let stateLine: String
        if let blockReason = blockReason {
            stateLine = "**State:** \(state.rawValue) — \(blockReason)"
        } else {
            stateLine = "**State:** \(state.rawValue)"
        }
        lines.append(stateLine)

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

        // Footer
        lines.append(Self.footer)

        return lines.joined(separator: "\n")
    }

    private func renderTranscriptions() -> [String] {
        var lines: [String] = []
        for transcription in brief.transcriptions {
            lines.append("")
            let pathsStr = transcription.paths.joined(separator: ",")
            let symbolStr = transcription.symbol ?? "-"
            let commitStr: String
            if transcription.authorSupplied, let night = transcription.authorSuppliedNight {
                commitStr = "Operator-supplied as of \(night.rawValue)"
            } else if transcription.authorSupplied {
                commitStr = "Operator-supplied"
            } else {
                commitStr = transcription.mainlineCommit ?? "Operator-supplied"
            }
            let hashStr = transcription.contentHash
            let comment = "<!-- yh:transcription:start repo=\(transcription.repository) paths=\(pathsStr) " +
                "symbol=\(symbolStr) commit=\(commitStr) hash=\(hashStr) -->"
            lines.append(comment)
            lines.append(transcription.content)
            lines.append("<!-- yh:transcription:end -->")
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
                lines.append("- [ ] <!-- yh:clause:\(clause.cid) --> \(clause.text) (\(clause.citation))")
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
