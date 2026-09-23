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
        }
    }
}

/// A Card the Readiness Check found Ready to dispatch: its brief and its Definition of Done, as the
/// Journal holds them.
public struct CardReadiness: Equatable, Sendable {
    public var brief: ArchitecturalBrief
    public var clauses: [ClauseRecord]

    public init(brief: ArchitecturalBrief, clauses: [ClauseRecord]) {
        self.brief = brief
        self.clauses = clauses
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
    /// The Operator's board identity for Waiting on You assignment, when configured.
    let `operator`: BoardObjectID?

    public init(provenance: any ProvenanceTesting, citations: any CitationResolving, operator: BoardObjectID? = nil) {
        self.provenance = provenance
        self.citations = citations
        self.operator = `operator`
    }

    /// Evaluates one Card: reconciles the board's copy of its Managed Block into the Journal first (an
    /// Operator's edit takes effect before readiness is judged against it), then checks structure,
    /// citations and provenance in that order.
    public func evaluate(card: CardRecord, context: BuildActContext) async throws -> ReadinessVerdict {
        let journal = context.act.journal

        // Any board write this check makes (a comment, a Divergence transition, a minted clause's
        // re-render) is about to run under this Card's Lease anyway — the lane is about to dispatch
        // it — so it is claimed here rather than leaving every write deferred until dispatch claims it.
        _ = try journal.claimCardLease(cardID: card.id, runID: context.act.runID)

        try await reconcileBoardCopy(card: card, context: context)

        if let match = try protectedPathMatch(card: card, context: context) {
            return try await recordRefusal(match: match, card: card, context: context)
        }

        let prose = try journal.architecturalBriefProse(cardID: card.id)
        let blocks = try journal.transcriptionBlocks(cardID: card.id)
        let clauses = try journal.clauses(issueID: card.issueID)
        let repositories = context.act.repositories

        var failures = structuralFailures(prose: prose, blocks: blocks, clauses: clauses)
        failures += await citationFailures(clauses: clauses, repositories: repositories, context: context)

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
        return .ready(CardReadiness(brief: brief, clauses: clauses))
    }

    /// Tests the Card's declared scope against its repository's configured protected paths, after the
    /// board copy is reconciled and before any other readiness work (P8.3).
    private func protectedPathMatch(card: CardRecord, context: BuildActContext) throws -> ProtectedPathRefusal? {
        let declaredScope = try context.act.journal.declaredScope(cardID: card.id)
        guard !declaredScope.isEmpty else { return nil }
        let protectedPaths = context.act.repositories?.workingRepo(named: card.repository)?.protectedPaths ?? []
        guard !protectedPaths.isEmpty,
              let match = ProtectedPaths.match(declaredScope: declaredScope, protectedPaths: protectedPaths)
        else {
            return nil
        }
        return ProtectedPathRefusal(
            repository: card.repository, declaredPath: match.declaredPath, protectedPath: match.protectedPath
        )
    }

    /// Parses the board's current copy of the Card's Managed Block (from the Delta Read) and folds any
    /// Operator edit into the Journal, before readiness is judged against it.
    private func reconcileBoardCopy(card: CardRecord, context: BuildActContext) async throws {
        let change = context.deltaRead?.cardChanges.first { $0.card.id == card.id }
        guard let description = change?.object.description,
              case .success(let parts) = ManagedBlockFence.parts(of: description) else {
            return
        }
        let parsed = CardManagedBlockParser.parse(block: parts.block)
        try await reconcile(parsed: parsed, card: card, context: context)
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
    private func citationFailures(
        clauses: [ClauseRecord], repositories: ProjectRepositories?, context: BuildActContext
    ) async -> [ReadinessFailure] {
        guard let repositories else {
            return [.repositoriesUnconfigured]
        }
        var failures: [ReadinessFailure] = []
        for clause in clauses {
            let citation = SpecCitation(clause.locationID)
            let resolution = await citations.resolve(citation, in: repositories, mainlines: context.act.mainlines)
            if !resolution.resolves {
                failures.append(.citationUnresolved(
                    cid: clause.cid, citation: clause.locationID,
                    reason: resolution.failureReason ?? "the citation could not be resolved"
                ))
            }
        }
        return failures
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
        let report = await provenance.evaluate(
            blocks.map(\.block), projectRepositories: repositories, mainlines: context.act.mainlines
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
