import Domain
import Foundation
import Journal

// The repaired halted Feature's half of the authoring transaction (roadmap P22.6; spec: feature-authoring/
// select-the-next-feature, `#halted-authoring-repair`). The Operator repaired the halted Feature Card and its
// draft children and moved the Feature to Todo; the snapshot of those children is validated with the SAME
// validators a machine-authored plan meets, spending no model call, no Attempt and no authoring-fault count, and
// an accepted plan reuses the drafts under their existing issue ids.

extension AuthoringTransaction {
    public func authorRepaired(
        _ selection: SelectedFeature, snapshot: HaltRepairSnapshot, reselectionDepth: Int, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        guard context.outbox != nil, context.board != nil else { throw AuthoringTransactionError.noBoard }
        let revalidated = try await AdoptionRevalidation.revalidate(
            selection, provenance: provenance, context: context, failedAdoptionsMax: failedAdoptionsMax
        )
        let selection = revalidated.selection
        let breakdown = snapshot.breakdown

        do {
            try FeatureBreakdownValidation.validate(breakdown, for: selection)
        } catch let error as FeatureBreakdownError {
            return try Self.invalidRepair(snapshot, diagnostics: [Self.diagnostic(error, snapshot)], context: context)
        }
        let overlaps = ContractOverlapCheck.overlaps(in: breakdown, scopes: snapshot.scopes)
        if !overlaps.isEmpty {
            let cause = AuthoringHaltCause.breakdownConsumesOwnFeatureWork(overlaps: overlaps)
            return try Self.invalidRepair(snapshot, diagnostics: [cause.description], context: context)
        }
        let resolution = await AuthoringCitations.resolve(breakdown, using: citations, context: context)
        if resolution.isThin {
            return try Self.invalidRepair(
                snapshot, diagnostics: Self.thinDiagnostics(resolution, snapshot), context: context
            )
        }
        let transcriptions = await AuthoringTranscriptions.resolve(breakdown, using: transcribing, context: context)
        if !transcriptions.invalidRanges.isEmpty {
            return try Self.invalidRepair(snapshot, diagnostics: transcriptions.invalidRanges, context: context)
        }
        if !transcriptions.isReadable {
            return try Self.invalidRepair(
                snapshot,
                diagnostics: [AuthoringHaltCause.contractUnreadable(contracts: transcriptions.unreadable).description],
                context: context
            )
        }
        return try await accept(
            selection, breakdown: breakdown, resolution: resolution, transcriptions: transcriptions,
            repairing: snapshot, context: context
        )
    }

    /// An invalid repair keeps the drafts, the accepted outputs and the Operator's edits as they are: the
    /// diagnostic (which child, which rule) is kept for the comment the same halted Feature gets, and nothing
    /// is recorded as an authoring fault.
    static func invalidRepair(
        _ snapshot: HaltRepairSnapshot, diagnostics: [String], context: ActContext
    ) throws -> FeatureAuthoringOutcome {
        try context.journal.recordAuthoringRepairDiagnostic(
            haltID: snapshot.haltID, diagnostic: diagnostics.map { "- \($0)" }.joined(separator: "\n")
        )
        return .halted
    }

    private static func diagnostic(_ error: FeatureBreakdownError, _ snapshot: HaltRepairSnapshot) -> String {
        func child(_ position: Int) -> String {
            snapshot.children[safe: position - 1]?.label ?? "Card \(position)"
        }
        func child(titled title: String) -> String {
            snapshot.children.first { $0.title == title }?.label ?? "'\(title)'"
        }
        switch error {
        case .emptyTitle(let position): return "\(child(position)): it has an empty title"
        case .emptyBrief(let position): return "\(child(position)): it has an empty Architectural Brief"
        case .briefContradictsWorkerContract(let position, let phrase):
            return "\(child(position)): its Architectural Brief contains \"\(phrase)\", which contradicts the "
                + "worker contract: the worker commits its own work and reports the commit"
        case .reservedKind(let title, let kind):
            return "\(child(titled: title)): its Kind '\(kind)' is reserved for the author Act"
        case .repositoryOutsideSelection(let title, let repository):
            return "\(child(titled: title)): it names repository '\(repository)', which the Feature's selection "
                + "did not resolve to"
        case .noCards: return "the Feature has no Work Card draft left and the selection adopts none"
        }
    }

    private static func thinDiagnostics(
        _ resolution: AuthoringCitationResolution, _ snapshot: HaltRepairSnapshot
    ) -> [String] {
        var lines: [String] = []
        if resolution.featureClauses.isEmpty { lines.append("the Feature has no citable Definition of Done clause") }
        for (index, clauses) in resolution.cardClauses.enumerated() where clauses.isEmpty {
            let label = snapshot.children.indices.contains(index) ? snapshot.children[index].label : "Card \(index + 1)"
            let reasons = resolution.uncitable.filter { $0.workCardTitle == snapshot.children[safe: index]?.title }
                .map { "\"\($0.text)\": \($0.reason)" }
            lines.append(
                "\(label): it has no citable Definition of Done clause"
                    + (reasons.isEmpty ? "" : " (" + reasons.joined(separator: "; ") + ")")
            )
        }
        return lines
    }
}

extension AuthoringTransaction {
    /// The contract-overlap floor (``ContractOverlapCheck``): a Work Card reading what another Work Card of this
    /// Feature writes is an Authoring Halt, recorded with no model call and no Route walk — nil when there is none.
    func haltIfConsumingOwnWork(
        _ breakdown: FeatureBreakdown, for selection: SelectedFeature, context: ActContext
    ) async throws -> FeatureAuthoringOutcome? {
        let overlaps = ContractOverlapCheck.overlaps(in: breakdown)
        guard !overlaps.isEmpty else { return nil }
        return try await AuthoringHalt.record(
            feature: selection.name, cause: .breakdownConsumesOwnFeatureWork(overlaps: overlaps),
            selection: selection, breakdown: breakdown, context: context
        )
    }

    /// A finalise that wrote nothing because the Feature Issue already belongs to a Feature is a failed
    /// transaction, never an authored one (issue #538). Every entry is applied, so there is nothing for the
    /// Outbox to roll back (an undo here would hit the earlier Feature's own issues). Recording the failure
    /// closes the plan, so the next selection gets fresh keys, and its adoption re-parents the Card.
    func recordNothingAuthored(
        _ plan: FeatureAuthoringAcceptedPayload, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        // Read on the Night Card, so it names no issue id: the plan's Feature key in the Journal does.
        let reason = "its Feature Issue already belongs to an earlier Feature, so this transaction authored nothing"
        guard let feature = FeatureName(rawValue: plan.name) else { return .authoringRolledBack }
        return try await recordFault(
            feature: feature, reason: reason,
            event: .featureAuthoringFailed(name: plan.name, groupKey: plan.groupKey, reason: reason),
            operationKey: "transaction:\(plan.groupKey)", context: context
        )
    }

    /// A repaired draft's declared scope was validated with the repair; it becomes the Card's own.
    static func recordRepairedScopes(_ plan: FeatureAuthoringAcceptedPayload, journal: JournalStore) throws {
        for planned in plan.cards where !planned.declaredScope.isEmpty {
            if let issueID = planned.existingIssueID, let row = try journal.card(issueID: issueID) {
                try journal.recordDeclaredScope(cardID: row.id, paths: planned.declaredScope)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
