import Domain
import Journal

// The authoring transaction's half of the description budget (spec: feature-authoring/author-the-cycle-and-
// card-dag, "description limit"): what the Route walk refuses as invalid breakdown output, and the check
// made again on the plan before anything is accepted into the Outbox.

extension AuthoringTransaction {
    /// The Route walk's acceptance of one drafted breakdown: why it is invalid output, or nil. A contract
    /// line range out of bounds at mainline, or a Work Card over the description budget, rejects it, and
    /// the next Route is tried. Everything else is judged after the walk, in the transaction's own order —
    /// a structurally invalid breakdown, a thin-spec Refusal, an unreadable contract and a Feature Card over
    /// the budget are accepted here and fault, halt or refuse there; so is a check that could not be made.
    func acceptance(
        of breakdown: FeatureBreakdown, for selection: SelectedFeature, context: ActContext
    ) async -> String? {
        let transcriptions = await AuthoringTranscriptions.resolve(breakdown, using: transcribing, context: context)
        if let rejection = AuthoringTranscriptions.rangeRejection(transcriptions) {
            return rejection
        }
        guard context.board?.descriptionBudget != nil, transcriptions.isReadable,
            (try? FeatureBreakdownValidation.validate(breakdown, for: selection)) != nil
        else { return nil }
        let resolution = await AuthoringCitations.resolve(breakdown, using: citations, context: context)
        guard !resolution.isThin,
            let measured = try? await measuredPlan(
                breakdown, for: selection, citations: resolution,
                transcriptions: transcriptions.cardTranscriptions, context: context
            ),
            let violation = measured.violation, violation.subject == .workCard
        else { return nil }
        return violation.reason
    }

    /// Plans the group, then measures every description it composes against the Board Connection's
    /// description budget: the first over it, the Feature Card's before any Work Card's, or nil when all
    /// fit or the board enforces no budget. A Work Card's room for its compacted Attempts is sized with the
    /// drafting's widest Route.
    func measuredPlan(
        _ breakdown: FeatureBreakdown, for selection: SelectedFeature,
        citations resolution: AuthoringCitationResolution, transcriptions: [[TranscriptionBlock]],
        repairing snapshot: HaltRepairSnapshot? = nil, context: ActContext
    ) async throws -> (plan: AuthoringPlan, violation: AuthoringBudgetViolation?) {
        guard let board = context.board else { throw AuthoringTransactionError.noBoard }
        let scope = try await BoardStateScope.resolve(using: board)
        let attempt = try context.journal.authoringTransactionCount(feature: selection.name.rawValue)
        let stopCreateKey = try AuthoringStopBoard.createKey(selection.name, context.journal)
        // Reuse a stop's Feature Issue only when this generation's stop created it: finalise reads the id
        // back from that create's entry, so an id some other key created would never finalise (issue #542).
        let stopCreated = try context.outbox.flatMap {
            try context.journal.outboxEntry(clientID: $0.clientID(for: stopCreateKey))?.result
        }
        let known = try AuthoringStopBoard.knownIssueID(selection.name, context.journal)
        let existing = known.flatMap { $0.rawValue == stopCreated ? $0 : nil }
        var planner = AuthoringPlanner(
            selection: selection, breakdown: breakdown, scope: scope, attempt: attempt,
            nightID: context.night.id, journal: context.journal, citations: resolution,
            transcriptions: transcriptions,
            existingFeatureIssueID: existing, stopCreateKey: stopCreateKey
        )
        planner.draftChildren = snapshot?.draftChildren ?? []
        var plan = try planner.plan()
        plan.repairSnapshot = snapshot
        guard let budget = board.descriptionBudget else { return (plan, nil) }
        let violation = try AuthoringDescriptionBudget(budget: budget, longestRoute: drafting.widestRoute).violation(
            plan: plan, planner: planner, breakdown: breakdown, transcriptions: transcriptions,
            journal: context.journal
        )
        return (plan, violation)
    }
}
