import Domain
import Foundation
import Journal

/// Why Verification could not complete (roadmap P10.5), an engine fault: the land Act records it, keeps
/// the Cycle unlanded and skips every pull request so the next land firing retries.
public struct VerificationFault: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// Why the verifier dispatch ended without a usable answer: the Routing Table has no Route left — when
/// the only ones left are those that wrote the code, it says so — or a run crashed with no outcome.
public struct VerificationDispatchFault: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// Verification, clause by clause (roadmap P10.5; spec: verification/verify-a-feature-clause-by-clause),
/// the real ``FeatureVerifying``. It judges the Definition of Done as the Journal's `clause` table holds
/// it — authored before any code existed, never re-read from the board — once per Cycle.
///
/// The engine decides two outcomes itself and never asks the agent: a clause of a Card that did not
/// complete is `unmet` (so a Partial Landing always fails), and a clause whose Spec Citation no longer
/// resolves is `unresolved` — a citation for the Specification Author to repair, not unfinished work. The
/// rest are dispatched as one `verifier` pass through the Routing Table under the authoring Kind, on a
/// Route that wrote none of the Cycle's code ("a different agent from the one that wrote the code").
public struct FeatureVerification: FeatureVerifying, Sendable {
    /// The specification-source-relative run directory name a verifier request carries.
    public static let runDirectoryName = "verification"

    let resolver: RouteResolver
    let dispatch: any AgentDispatch
    let citations: any CitationResolving
    /// Makes the checkout of every repository the verifier is handed, at its recorded commit, and removes it.
    let checkouts: any VerifierCheckoutPreparing

    public init(
        resolver: RouteResolver, dispatch: any AgentDispatch, citations: any CitationResolving,
        checkouts: any VerifierCheckoutPreparing
    ) {
        self.resolver = resolver
        self.dispatch = dispatch
        self.citations = citations
        self.checkouts = checkouts
    }

    public func verify(_ context: LandActFeatureContext) async throws -> VerificationVerdict {
        let journal = context.act.journal
        if let existing = try journal.featureVerification(cycleID: context.cycleID) {
            // Judged once per Cycle: a retried land Act reuses the record, and only re-queues the write.
            try queueReport(existing, context: context)
            return Self.verdict(of: existing)
        }

        let candidates = try gatherClauses(context)
        guard !candidates.isEmpty else {
            throw VerificationFault(reason: "the Cycle has no Definition of Done clause to verify")
        }
        // OQ191 items 2, 5, 7 and 8: what was pushed is judged, in checkouts removed when Verification ends.
        // The judged commits are resolved every time; the checkouts are made only if a clause is dispatched.
        let plan = try await checkouts.plan(context, repositories: try verifiedRepositories(context))
        var prepared: VerifierCheckouts?
        defer { prepared.map { checkouts.release($0) } }

        var judged = try await decideByEngine(candidates, context: context)
        let pending = candidates.filter { judged[$0.key] == nil }

        var route: Route?
        if !pending.isEmpty {
            let made = try await checkouts.materialise(plan, context: context)
            prepared = made
            let (routeUsed, verdicts) = try await dispatchVerifier(pending, checkouts: made, context: context)
            route = routeUsed
            for candidate in pending {
                guard let verified = verdicts[candidate.key] else { continue }
                judged[candidate.key] = candidate.record(
                    verdict: verified.verdict, whatWasChecked: verified.whatWasChecked,
                    interpretation: verified.interpretation, judgedBy: .agent
                )
            }
        }

        let records = candidates.compactMap { judged[$0.key] }
        try journal.recordFeatureVerification(NewFeatureVerification(
            featureID: context.feature.id, cycleID: context.cycleID, route: route?.description,
            nightID: context.act.night.id, runID: context.act.runID, clauses: records,
            judgedCheckouts: plan.judgedCheckouts
        ))
        guard let recorded = try journal.featureVerification(cycleID: context.cycleID) else {
            throw VerificationFault(reason: "the Verification just recorded cannot be read back")
        }
        let verdict = Self.verdict(of: recorded)
        try journal.append(
            .featureVerified(
                cycleID: context.cycleID, met: recorded.clauses.filter { $0.verdict == .met }.count,
                unmet: recorded.clauses.filter { $0.verdict == .unmet }.count,
                unresolved: recorded.clauses.filter { $0.verdict == .unresolved }.count,
                notChecked: recorded.clauses.filter { $0.verdict == .notChecked }.count
            ),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )
        await reportUnpublishedHeads(plan.unpublishedHeads, context: context)
        try queueReport(recorded, context: context)
        return verdict
    }

    /// Reports each held Worktree whose HEAD was not its recorded commit as not published (OQ191 items 2 and 5;
    /// landing/open-one-pull-request-per-repository `#unpublished-commits-pin`), once this Verification is
    /// recorded, so the report names what it judged. A note, never a failure: it never throws and never blocks
    /// the Cycle. A reused record reports nothing again.
    private func reportUnpublishedHeads(_ unpublished: [UnpublishedHead], context: LandActFeatureContext) async {
        guard !unpublished.isEmpty else { return }
        let act = context.act
        let lanes = (try? act.journal.cards(cycleID: context.cycleID)).map { RepoLane.derive(from: $0) } ?? []
        for head in unpublished {
            _ = try? act.journal.append(
                .unpublishedCommitsReported(cycleID: context.cycleID, unpublished: head),
                act: act.act, runID: act.runID, nightID: act.night.id
            )
            let placement = UnpublishedCommitsReport.Placement(
                cycleID: context.cycleID, repository: head.repository, featureIssueID: context.feature.issueID,
                laneCards: lanes.first { $0.repository == head.repository }?.cards ?? []
            )
            await UnpublishedCommitsReport.post(
                UnpublishedCommitsReport.atVerification(head), kind: .verification, at: placement, outbox: act.outbox
            )
        }
    }

    /// The land Act's two-way verdict from a recorded Verification: all clauses met only when every clause
    /// is `met`; the remaining verdicts named separately as `<issue> <cid>` otherwise.
    static func verdict(of record: FeatureVerificationRecord) -> VerificationVerdict {
        func name(_ clause: ClauseVerificationRecord) -> String { "\(clause.issueID) \(clause.cid)" }
        return VerificationVerdict(
            allClausesMet: !record.clauses.isEmpty && record.clauses.allSatisfy { $0.verdict == .met },
            unmetClauses: record.clauses.filter { $0.verdict == .unmet }.map(name),
            unresolvedClauses: record.clauses.filter { $0.verdict == .unresolved }.map(name),
            notCheckedClauses: record.clauses.filter { $0.verdict == .notChecked }.map(name)
        )
    }

    /// Queues the report onto the Feature Issue's Managed Block, under a deterministic key. Every line of
    /// the report starts with one prefix, so a replay replaces the whole report and nothing else.
    private func queueReport(_ record: FeatureVerificationRecord, context: LandActFeatureContext) throws {
        guard let outbox = context.act.outbox else { return }
        let touched = try context.act.journal.touchedRepositories(featureID: context.feature.id).count
        let write = OutboxWrite(
            key: "land:\(context.cycleID):verification:\(context.feature.issueID)",
            write: .updateManagedBlockLine(
                issue: BoardObjectID(rawValue: context.feature.issueID),
                prefix: VerificationReport.managedBlockPrefix,
                line: VerificationReport(record: record, touchedRepositoryCount: touched).managedBlockLines()
            )
        )
        _ = try outbox.accept(write)
    }
}
