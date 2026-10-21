import Domain
import Foundation
import Journal

// Resuming a repaired halted Feature (roadmap P22.5; spec: feature-authoring/select-the-next-feature,
// `#halted-authoring-repair`): the Operator moved a tracked halted Feature Card to Todo, and the author Act has
// already recorded that as a pending request (``HaltedFeatureRepair/observe(context:)``). Here the SAME Feature
// authors again from its checkpoint, under its own Feature Issue, with no fresh selection.

extension FeatureSelection {
    /// What comes before any fresh selection: an authoring transaction an earlier Act accepted and did not
    /// finish, then the Operator's repair of an existing halted Feature, which resumes that same Feature
    /// (roadmap P22.5; spec: feature-authoring/select-the-next-feature, `#halted-authoring-repair`).
    func resumeEarlierWork(_ context: ActContext) async throws -> FeatureAuthoringOutcome? {
        if let transaction, let resumed = try await transaction.resumeUnfinished(context) {
            return resumed
        }
        return try await resumeRepairedHalt(context)
    }

    /// Validates and resumes the oldest tracked halted Feature whose Feature Card the Operator moved to Todo; nil
    /// when there is none, or none can be acted on (another Feature occupies the slot), so selection goes on.
    ///
    /// The selector is not called when the halt's checkpoint holds the selection. The deterministic checks for the
    /// halt cause run first and spend no Attempt, no model call and no authoring-fault count; only a genuinely
    /// missing stage runs a model, and the Journal records why. Todo alone never clears the halt: only the plan
    /// the transaction durably accepts does.
    func resumeRepairedHalt(_ context: ActContext) async throws -> FeatureAuthoringOutcome? {
        guard let board = context.board, context.outbox != nil, transaction != nil else { return nil }
        let journal = context.journal
        for halt in try journal.liveAuthoringHalts() {
            guard let issueID = halt.issueID, let feature = FeatureName(rawValue: halt.featureName),
                  let checkpoint = try journal.authoringHaltCheckpoint(haltID: halt.id),
                  checkpoint.hasUnhandledRepairRequest
            else { continue }
            // Todo is read again here: the request was recorded earlier in this Act, and the Operator may since
            // have moved the Feature Card on.
            guard let object = try await board.reading.issue(BoardObjectID(rawValue: issueID)) else { continue }
            let scope = try await BoardStateScope.resolve(using: board)
            guard FeatureDisposition(workflowState: object.workflowState, scope: scope) == .ready else {
                try journal.withdrawAuthoringRepairRequest(haltID: halt.id)
                continue
            }
            if try journal.inFlightFeature() != nil {
                try await HaltedFeatureRepair.deferPending(reason: .featureInFlight, context: context)
                return nil
            }
            return try await repair(
                RepairRequest(halt: halt, feature: feature, checkpoint: checkpoint, todo: object.workflowState),
                context: context
            )
        }
        return nil
    }

    /// The Operator's pending request for one tracked halt, and the Todo they set.
    private struct RepairRequest {
        let halt: AuthoringHaltRecord
        let feature: FeatureName
        let checkpoint: AuthoringHaltCheckpoint
        let todo: BoardWorkflowState

        var issue: BoardObjectID? { halt.issueID.map(BoardObjectID.init(rawValue:)) }
    }

    private func repair(_ request: RepairRequest, context: ActContext) async throws -> FeatureAuthoringOutcome {
        let (halt, feature, checkpoint) = (request.halt, request.feature, request.checkpoint)
        let journal = context.journal
        guard let repositories = context.repositories, !repositories.workingRepos.isEmpty else {
            throw FeatureSelectionError.noRepositoriesConfigured
        }
        try journal.recordAuthoringRepairStep(
            feature: feature, step: "resumed", detail: halt.causeKind,
            nightID: context.night.id, act: context.act, runID: context.runID
        )
        let candidates = try journal.blockedCardsLeftByClosedFeatures().map {
            AdoptionCandidate(
                issueID: $0.issueID, repository: $0.repository, title: $0.title, blockReason: $0.blockReason
            )
        }
        let held = try await releaseGate?.heldConsumers(context) ?? []
        let scope = SelectionScope(repositories: repositories, candidates: candidates, held: held)

        let selection: SelectedFeature
        if let stored = checkpoint.selection {
            selection = stored
        } else {
            switch try await pinnedSelection(
                of: feature, scope: scope, board: try journal.selectionBoardState(), context: context
            ) {
            case .selected(let chosen): selection = chosen
            case .stopped(let outcome): return try await conclude(outcome, request, context: context)
            }
        }
        try journal.recordAuthoringRepairDiagnostic(haltID: halt.id, diagnostic: nil)
        var snapshot: HaltRepairSnapshot?
        if checkpoint.breakdown != nil {
            // The checkpoint holds the breakdown: the Operator's repair is what is on the Board now — the Feature
            // Card and its draft children — and nothing needs a model (roadmap P22.6).
            snapshot = try await HaltRepairSnapshot.take(halt: halt, checkpoint: checkpoint, context: context)
            if let snapshot, !snapshot.problems.isEmpty {
                _ = try AuthoringTransaction.invalidRepair(snapshot, diagnostics: snapshot.problems, context: context)
                return try await conclude(.halted, request, context: context)
            }
        } else if Self.haltCause(forRepositories: Set(selection.repositories).sorted(), in: repositories) == nil {
            // The breakdown is not part of the checkpoint (it is rebuilt, not reused), so it is the stage that runs.
            try journal.recordAuthoringRepairStep(
                feature: feature, step: "stage",
                detail: "breakdown: the checkpoint holds the selection and no accepted breakdown",
                nightID: context.night.id, act: context.act, runID: context.runID
            )
        }
        let outcome = try await validateAndRecord(
            selection, scope: scope, reselectionDepth: 0, repairing: true,
            ignoringFaultBound: halt.causeKind == "authoring-repeatedly-faulted", repairSnapshot: snapshot,
            context: context
        )
        return try await conclude(outcome, request, context: context)
    }

    private enum PinnedSelection {
        case selected(SelectedFeature)
        case stopped(FeatureAuthoringOutcome)
    }

    /// The halt was recorded before the selector chose a Feature, so there is no selection to resume: the selector
    /// is the genuinely missing stage, and it runs pinned to this Feature's name — never to choose another.
    private func pinnedSelection(
        of feature: FeatureName, scope: SelectionScope, board: SelectionBoardState, context: ActContext
    ) async throws -> PinnedSelection {
        let journal = context.journal
        try journal.recordAuthoringRepairStep(
            feature: feature, step: "stage",
            detail: "selection: the halt predates the selector's choice of a Feature, so it runs pinned to this one",
            nightID: context.night.id, act: context.act, runID: context.runID
        )
        let source = try Self.specificationSource(scope.repositories)
        let request = FeatureSelectionRequest(
            specificationSource: source,
            specificationMainline: Self.specificationMainline(source, mainlines: context.mainlines),
            repos: scope.repositories.workingRepos, mainlines: context.mainlines, namedFeature: feature,
            adoptionCandidates: scope.candidates, heldConsumers: scope.held, boardState: board
        )
        let outcome: FeatureSelectionOutcome
        do {
            outcome = try await selector.select(request, context: context)
        } catch let fault as AuthoringDispatchFault {
            try journal.append(
                .featureSelectionFailed(reason: fault.reason),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            return .stopped(.authoringRolledBack)
        }
        switch outcome {
        case .selected(let chosen) where chosen.name == feature:
            return .selected(chosen)
        case .halted(let name, let cause) where name == feature:
            return .stopped(try await AuthoringHalt.record(feature: feature, cause: cause, context: context))
        case .selected, .halted, .noSelectableFeature:
            // A pinned selector that answers about another Feature, or none, did not do the stage it was asked
            // for: an authoring fault, recorded like a failed selection.
            try journal.append(
                .featureSelectionFailed(reason: "the selector did not answer for Feature '\(feature)'"),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            return .stopped(.authoringRolledBack)
        }
    }

    /// What a validation's outcome means for the request: accepted, still halted (feedback, and the halted
    /// position restored), or left to be retried. A handled request is not validated again.
    private func conclude(
        _ outcome: FeatureAuthoringOutcome, _ request: RepairRequest, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        let journal = context.journal
        let (halt, feature) = (request.halt, request.feature)
        guard let issue = request.issue else { return outcome }
        let seq = request.checkpoint.repairSeq
        switch outcome {
        case .authored:
            try journal.markAuthoringRepairHandled(haltID: halt.id, seq: seq)
            try journal.recordAuthoringRepairStep(
                feature: feature, step: "accepted",
                nightID: context.night.id, act: context.act, runID: context.runID
            )
            try await HaltedFeatureRepair.postCommentOnce(
                key: HaltedFeatureRepair.commentKey(halt: halt, seq: seq, kind: "accepted"), issue: issue,
                body: "Repair of Feature '\(feature)' is accepted: it continues as this same Feature.",
                context: context
            )
        case .halted:
            try await stillHalted(request, context: context)
        case .refused:
            try journal.markAuthoringRepairHandled(haltID: halt.id, seq: seq)
        case .authoringRolledBack where halt.causeKind == "authoring-repeatedly-faulted":
            // The Operator's Todo was the intervention this halt waits for, and the attempt faulted again.
            try await stillHalted(request, context: context)
        case .authoringRolledBack, .authoringPending, .releaseGateHeld, .noWorkAvailable:
            // Not concluded: an accepted plan still delivering is finished by a later Act (the halt clears when it
            // is), and a plan that fails there leaves this request unhandled for the next validation.
            break
        }
        return outcome
    }

    /// An invalid or empty repair: the same Feature stays halted with a diagnostic comment, and the halted
    /// position is restored under a write decided against the Todo the Operator set. It spent no Attempt and no
    /// authoring fault, and it did not touch the clock.
    private func stillHalted(_ request: RepairRequest, context: ActContext) async throws {
        let journal = context.journal
        let (halt, feature, seq) = (request.halt, request.feature, request.checkpoint.repairSeq)
        guard let issue = request.issue else { return }
        let current = try journal.authoringHalts(feature: feature).first { $0.id == halt.id } ?? halt
        try journal.markAuthoringRepairHandled(haltID: halt.id, seq: seq)
        try journal.recordAuthoringRepairStep(
            feature: feature, step: "invalid", detail: current.causeKind,
            nightID: context.night.id, act: context.act, runID: context.runID
        )
        let found = try journal.authoringHaltCheckpoint(haltID: halt.id)?.repairDiagnostic
        let diagnostic = found.map { "\n\nWhat to fix:\n\($0)" } ?? ""
        try await HaltedFeatureRepair.postCommentOnce(
            key: HaltedFeatureRepair.commentKey(halt: halt, seq: seq, kind: "invalid"), issue: issue,
            body: """
                Repair of Feature '\(feature)' is not accepted: the halt still holds, so the Feature stays halted \
                and keeps its checkpoint, its drafts and your edits.

                \(current.content)\(diagnostic)
                """,
            context: context
        )
        try await HaltedFeatureRepair.restoreHaltedPosition(
            halt: current, seq: seq, todo: request.todo, context: context
        )
    }
}
