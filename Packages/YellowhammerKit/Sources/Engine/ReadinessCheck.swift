import Domain
import Foundation
import Journal
import Repositories

/// Tests whether a Transcription Block's recorded paths have changed since it was recorded, without
/// the Readiness Check needing to know it is talking to git.
public protocol ProvenanceTesting: Sendable {
    func evaluate(
        _ blocks: [TranscriptionBlock], projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> CardProvenanceReport
}

/// Resolves a Spec Citation against a Project's specification source, without the Readiness Check
/// needing to know it is talking to git.
public protocol CitationResolving: Sendable {
    func resolve(
        _ citation: SpecCitation, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> SpecCitationResolution
}

/// Why an Operator-edited Transcription Block reference could not be read from local mainline.
public struct ReferenceReadFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// Reads an Operator-edited Transcription Block reference from local mainline, without the Readiness Check
/// needing to know it is talking to git. Never throws for an unreadable reference: that is a
/// ``ReferenceReadFailure``, which makes the Card not Ready.
public protocol ReferenceReading: Sendable {
    func read(
        _ record: TranscriptionBlockRecord, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> Result<TranscriptionBlock, ReferenceReadFailure>
}

extension MainlineReader: ReferenceReading {
    public func read(
        _ record: TranscriptionBlockRecord, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> Result<TranscriptionBlock, ReferenceReadFailure> {
        do {
            return .success(try await readEditedReference(
                repository: record.repository, paths: record.paths, ranges: record.ranges, symbol: record.symbol,
                commit: record.mainlineCommit, in: projectRepositories, mainlines: mainlines
            ))
        } catch {
            return .failure(ReferenceReadFailure(reason: "\(error)"))
        }
    }
}

extension ProvenanceDiffTester: ProvenanceTesting {
    public func evaluate(
        _ blocks: [TranscriptionBlock], projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> CardProvenanceReport {
        await evaluateTranscriptionBlocks(blocks, projectRepositories: projectRepositories, mainlines: mainlines)
    }
}

extension MainlineReader: CitationResolving {
    public func resolve(
        _ citation: SpecCitation, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> SpecCitationResolution {
        await resolveCitation(citation, in: projectRepositories, mainlines: mainlines)
    }
}

/// Why a Card is not Ready to dispatch.
public enum ReadinessFailure: Equatable, Sendable, CustomStringConvertible {
    case briefMissing
    case definitionOfDoneMissing
    case citationUnresolved(cid: String, citation: String, reason: String)
    case transcriptionUntestable(repository: String, reason: String)
    case repositoriesUnconfigured
    /// An Operator-edited Transcription Block reference that cannot be read (or parsed): the Card is not
    /// Ready, and the reason goes on the Card.
    case referenceUnreadable(repository: String, reference: String, reason: String)
    /// An input field the Operator edited inside the Managed Block (`scope`, `definition of done`) that
    /// Yellowhammer cannot read. It stays on the board as written and is not imported.
    case inputUnreadable(field: String, reason: String)
    /// The `Card override:` line is malformed or duplicated (routing/resolve-a-route-for-a-card). It is kept
    /// on the board as written and the Card does not dispatch on a silent fallback to normal routing.
    case cardOverrideMalformed(reason: String)

    public var description: String {
        switch self {
        case .briefMissing:
            "the Card has no Architectural Brief"
        case .definitionOfDoneMissing:
            "the Card has no Definition of Done clause"
        case .citationUnresolved(let cid, let citation, let reason):
            "clause \(cid)'s Spec Citation '\(citation)' does not resolve: \(reason)"
        case .transcriptionUntestable(let repository, let reason):
            "the Transcription Block for repository '\(repository)' could not be tested: \(reason)"
        case .repositoriesUnconfigured:
            "the Project has no repositories configured"
        case .referenceUnreadable(_, let reference, let reason):
            "the edited Transcription Block reference \(reference) could not be read: \(reason)"
        case .cardOverrideMalformed(let reason):
            "the Card override cannot be read, so it was kept as written: \(reason)"
        case .inputUnreadable(let field, let reason):
            "the Operator's edit to the Card's \(field) cannot be read, so it was kept as written and not "
                + "imported: \(reason)"
        }
    }
}

/// A Card the Readiness Check found Ready to dispatch: its brief and its Definition of Done, as the
/// Journal holds them.
public struct CardReadiness: Equatable, Sendable {
    public var brief: ArchitecturalBrief
    public var clauses: [ClauseRecord]
    /// The specification commit the first resolving Spec Citation resolved against; nil when none did
    /// (OQ165, graph-execution/run-a-card#spec-commit).
    public var specCommit: String?

    public init(brief: ArchitecturalBrief, clauses: [ClauseRecord], specCommit: String? = nil) {
        self.brief = brief
        self.clauses = clauses
        self.specCommit = specCommit
    }
}

/// A Card found to have diverged: at least one Transcription Block's provenance test returned `.stale`.
public struct DivergenceFinding: Equatable, Sendable {
    public var repository: String
    public var changedPaths: [String]
    public var consecutiveDivergences: Int

    public init(repository: String, changedPaths: [String], consecutiveDivergences: Int) {
        self.repository = repository
        self.changedPaths = changedPaths
        self.consecutiveDivergences = consecutiveDivergences
    }
}

/// A Card refused before dispatch because its declared scope falls under a repository's protected path
/// (bounds/refuse-protected-paths-before-dispatch, roadmap P8.3).
///
/// This is a scoping check, not a sandbox: the refusal happens before dispatch, and nothing prevents a
/// dispatched agent from touching a protected path during its run.
public struct ProtectedPathRefusal: Equatable, Sendable {
    public var repository: String
    public var declaredPath: String
    public var protectedPath: String

    public init(repository: String, declaredPath: String, protectedPath: String) {
        self.repository = repository
        self.declaredPath = declaredPath
        self.protectedPath = protectedPath
    }
}

/// The Readiness Check's outcome for one Card.
public enum ReadinessVerdict: Equatable, Sendable {
    case ready(CardReadiness)
    case notReady([ReadinessFailure])
    case diverged(DivergenceFinding)
    /// The Card's declared scope falls under a protected path; it was not dispatched and consumed no
    /// Attempt. This is a scoping check, not a sandbox — see ``ProtectedPathRefusal``.
    case refused(ProtectedPathRefusal)
}

/// Runs at dispatch, for each Card the lane is about to run (board-projection/check-card-readiness-at-dispatch,
/// roadmap P8.2): a Card is Ready only if it has an Architectural Brief, a Definition of Done with at
/// least one clause, and every clause's Spec Citation resolves. Never throws for a readiness outcome —
/// only a Journal or Outbox fault propagates.
public struct ReadinessCheck: Sendable {
    let provenance: any ProvenanceTesting
    let citations: any CitationResolving
    let references: any ReferenceReading

    public init(
        provenance: any ProvenanceTesting, citations: any CitationResolving,
        references: any ReferenceReading = MainlineReader()
    ) {
        self.provenance = provenance
        self.citations = citations
        self.references = references
    }

    /// Evaluates one Card: reconciles the board's copy of its Managed Block into the Journal first (an
    /// Operator's edit takes effect before readiness is judged against it), then checks structure,
    /// citations and provenance in that order.
    ///
    /// Any board write this check makes (a comment, a Divergence transition, a minted clause's
    /// re-render) needs this Card's Lease, so it is claimed here rather than leaving every write deferred
    /// until dispatch claims it. A Ready Card keeps it: the lane dispatches it next and the Card run
    /// takes the Lease over. Any other verdict, or a fault, releases it here — the lane moves on without
    /// the Card, and a Lease left behind would stop every other Act writing the Card until its TTL ran
    /// out.
    public func evaluate(card: CardRecord, context: BuildActContext) async throws -> ReadinessVerdict {
        let journal = context.act.journal
        let runID = context.act.runID
        _ = try journal.claimCardLease(cardID: card.id, runID: runID)
        let verdict: ReadinessVerdict
        do {
            verdict = try await judge(card: card, context: context)
        } catch {
            _ = try? journal.releaseCardLease(cardID: card.id, runID: runID)
            throw error
        }
        if case .ready = verdict { return verdict }
        _ = try journal.releaseCardLease(cardID: card.id, runID: runID)
        return verdict
    }

    /// The readiness judgement itself, under the Card Lease ``evaluate(card:context:)`` holds.
    private func judge(card: CardRecord, context: BuildActContext) async throws -> ReadinessVerdict {
        let journal = context.act.journal

        let board = try reconcileBoardCopy(card: card, context: context)
        var rewriteNeeded = board.rewriteNeeded
        let reads = try await readUnreadReferences(card: card, context: context)
        rewriteNeeded = rewriteNeeded || reads.anyRead
        // One Managed Block rewrite per evaluation, from the Journal as it now stands: an unread edit is
        // rendered verbatim, so a rewrite never overwrites an Operator's edit with the old reference.
        if rewriteNeeded { try await rewriteManagedBlock(card: card, context: context) }

        let matches = try protectedPathMatches(card: card, context: context)
        if let match = matches.first {
            // Overreach retains precedence over all other readiness failures except Divergence.
            if let repositories = context.act.repositories {
                let blocks = try journal.transcriptionBlocks(cardID: card.id).filter(\.isRead)
                let report = await provenance.evaluate(
                    blocks.map(\.block), projectRepositories: repositories, mainlines: context.recordedBaseMainlines
                )
                if report.hasDivergence {
                    try recordOverlaps(matches, card: card, context: context)
                    return try await recordDivergence(report: report, card: card, context: context)
                }
            }
            return try await recordRefusal(match: match, overlaps: matches, card: card, context: context)
        }

        let prose = try journal.architecturalBriefProse(cardID: card.id)
        let blocks = try journal.transcriptionBlocks(cardID: card.id)
        let clauses = try journal.clauses(issueID: card.issueID)
        let repositories = context.act.repositories

        var failures = structuralFailures(prose: prose, blocks: blocks, clauses: clauses)
        // An input the Operator left unreadable is retained as written and not imported, so the Journal still
        // holds the value it had before: judging the Card against that would dispatch on unvalidated input.
        failures += board.invalid.map { .inputUnreadable(field: $0.field, reason: $0.reason) }
        if case .malformed(let reason) = CardOverrideField.reading(of: try journal.cardOverrideLines(cardID: card.id)) {
            failures.append(.cardOverrideMalformed(reason: reason))
        }
        failures += reads.failures
        let citationCheck = await citationFailures(clauses: clauses, repositories: repositories, context: context)
        failures += citationCheck.failures

        if let repositories {
            switch try await provenanceStep(blocks: blocks, repositories: repositories, card: card, context: context) {
            case .diverged(let verdict):
                return verdict
            case .failures(let provenanceFailures):
                failures += provenanceFailures
            }
        }

        if !failures.isEmpty {
            try await recordFailure(failures: failures, card: card, context: context)
            return .notReady(failures)
        }

        try journal.append(
            .readinessCheckPassed(cardID: card.id, issueID: card.issueID),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )
        let brief = ArchitecturalBrief(prose: prose ?? "", transcriptions: blocks.map(\.block))
        return .ready(CardReadiness(brief: brief, clauses: clauses, specCommit: citationCheck.specCommit))
    }

    /// Tests every declared path against this repository's configured Protected Paths.
    private func protectedPathMatches(card: CardRecord, context: BuildActContext) throws -> [ProtectedPathRefusal] {
        let declaredScope = try context.act.journal.declaredScope(cardID: card.id)
        let protectedPaths = context.act.repositories?.workingRepo(named: card.repository)?.protectedPaths ?? []
        return declaredScope.flatMap { path in
            protectedPaths.compactMap { protectedPath in
                guard let match = ProtectedPaths.match(declaredScope: [path], protectedPaths: [protectedPath]) else {
                    return nil
                }
                return ProtectedPathRefusal(
                    repository: card.repository, declaredPath: match.declaredPath, protectedPath: match.protectedPath
                )
            }
        }
    }

    /// Parses the board's current copy of the Card's Managed Block (from the Delta Read) and folds any
    /// Operator edit into the Journal, before readiness is judged against it.
    /// Returns whether the Card's Managed Block needs a rewrite as a result, and the input fields the Operator
    /// left unreadable.
    private func reconcileBoardCopy(
        card: CardRecord, context: BuildActContext
    ) throws -> (rewriteNeeded: Bool, invalid: [InvalidBlockInput]) {
        let change = context.deltaRead?.cardChanges.first { $0.card.id == card.id }
        guard let description = change?.object.description,
              case .success(let parts) = ManagedBlockFence.parts(of: description) else {
            return (false, [])
        }
        let parsed = CardManagedBlockParser.parse(block: parts.block)
        let imported = try CardInputReconciler(context).reconcile(parsed: parsed, card: card)
        return (imported.needsRewrite, imported.invalid)
    }

    /// The Journal-only failures: a missing brief, an empty Definition of Done, and (in place of
    /// citation and provenance work) an unconfigured Project.
    private func structuralFailures(
        prose: String?, blocks: [TranscriptionBlockRecord], clauses: [ClauseRecord]
    ) -> [ReadinessFailure] {
        var failures: [ReadinessFailure] = []
        let proseEmpty = (prose ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if proseEmpty, blocks.isEmpty {
            failures.append(.briefMissing)
        }
        if clauses.isEmpty {
            failures.append(.definitionOfDoneMissing)
        }
        return failures
    }

    /// Every clause whose Spec Citation does not resolve, or a single `.repositoriesUnconfigured` when
    /// the Project has no repositories to resolve against.
    ///
    /// Also yields the commit of the first resolving citation, in clause order: the specification commit
    /// the Readiness Check resolved against (OQ165, graph-execution/run-a-card#spec-commit).
    private func citationFailures(
        clauses: [ClauseRecord], repositories: ProjectRepositories?, context: BuildActContext
    ) async -> CitationCheck {
        guard let repositories else {
            return CitationCheck(failures: [.repositoriesUnconfigured], specCommit: nil)
        }
        var check = CitationCheck(failures: [], specCommit: nil)
        for clause in clauses {
            let citation = SpecCitation(clause.locationID)
            let resolution = await citations.resolve(
                citation, in: repositories, mainlines: context.recordedBaseMainlines
            )
            if resolution.resolves {
                if check.specCommit == nil { check.specCommit = resolution.commit }
            } else {
                check.failures.append(.citationUnresolved(
                    cid: clause.cid, citation: clause.locationID,
                    reason: resolution.failureReason ?? "the citation could not be resolved"
                ))
            }
        }
        return check
    }

    private struct CitationCheck {
        var failures: [ReadinessFailure]
        var specCommit: String?
    }

    private enum ProvenanceOutcome {
        case diverged(ReadinessVerdict)
        case failures([ReadinessFailure])
    }

    /// Tests every Transcription Block's provenance. A Divergence short-circuits straight to the
    /// verdict; otherwise every untestable block becomes a failure and a clean pass resets the Card's
    /// consecutive-Divergence counter.
    private func provenanceStep(
        blocks: [TranscriptionBlockRecord], repositories: ProjectRepositories, card: CardRecord,
        context: BuildActContext
    ) async throws -> ProvenanceOutcome {
        // Only READ records are tested: an unread one is already a failure, and has no commit to diff from.
        let report = await provenance.evaluate(
            blocks.filter(\.isRead).map(\.block), projectRepositories: repositories,
            mainlines: context.recordedBaseMainlines
        )
        var failures: [ReadinessFailure] = []
        for result in report.results {
            if case .untestable(let reason) = result.verdict {
                failures.append(.transcriptionUntestable(repository: result.repository, reason: reason))
            }
        }
        if report.hasDivergence {
            return .diverged(try await recordDivergence(report: report, card: card, context: context))
        }
        try context.act.journal.resetConsecutiveDivergences(cardID: card.id)
        return .failures(failures)
    }
}
