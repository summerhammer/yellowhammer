import Domain
import Foundation
import Journal

/// How a Card's run ended, before the Journal is told.
enum CardRunEnd: Sendable {
    /// The reviewer approved after a passing (or declared-none) Check.
    case approved(commit: String)
    /// An Attempt-ending outcome: a failed run, a reported failure, or the worker's question.
    case ending(AttemptEnding)
    /// The round budget ran out with the work still not approved — red from the Check, or changes the
    /// reviewer asked for — and the last Round was already recorded: `lens` is that Round's Lens. Ending
    /// the Attempt `rounds-exhausted` and deciding whether the Attempt budget blocks the Card is `conclude`'s.
    case roundsExhausted(lens: Lens)
}

/// A pass that ended the Attempt instead of yielding a result: thrown inside the sequence, caught by it.
private struct PassStop: Error {
    let ending: AttemptEnding
}

extension CardRun {
    /// Architect, then worker, then the Check, then reviewer, stopping at the first that ends the run.
    func runPasses(frame: CardRunFrame) async throws -> CardRunEnd {
        do {
            return try await sequence(frame: frame)
        } catch let stop as PassStop {
            return .ending(stop.ending)
        }
    }

    private func sequence(frame: CardRunFrame) async throws -> CardRunEnd {
        let architect = try await runPass(.architect, frame: frame)
        guard case .architect(let plan) = architect.result else {
            throw CardRunError.unexpectedResult(expected: .architect, found: architect.result.pass)
        }
        if case .failed(let reason) = plan.outcome {
            return .ending(.hardFailure(.reported(reason: reason)))
        }

        guard let attempt = frame.attempt else {
            preconditionFailure("a pass is dispatched only after the Attempt is recorded")
        }

        // The worker's opaque session, kept in memory only for as long as this run lasts, so a Round on
        // either Lens resumes the same conversation. Not persisted across Acts.
        var worked = try await work(frame: frame, payloads: .none, resumeSession: nil)
        while true {
            switch try await runCheckLoop(frame: frame, attemptID: attempt.id, worked: worked) {
            case .exhausted:
                return .roundsExhausted(lens: .check)
            case .passed(let commit, let session):
                worked = (commit: commit, session: session)
            }

            let reviewer = try await runPass(.reviewer, frame: frame)
            guard case .reviewer(let judged) = reviewer.result else {
                throw CardRunError.unexpectedResult(expected: .reviewer, found: reviewer.result.pass)
            }
            switch judged.outcome {
            case .approved:
                return .approved(commit: worked.commit)
            case .changesRequested(let judgedCommit, _, let requestedChanges):
                // A review Round of this Attempt, never a new Attempt: same worker, Route, Worktree. Both
                // Lenses share the one round budget, so the Check's own Rounds count against it too.
                let (rounds, budget) = try await recordReviewRound(
                    frame: frame, attemptID: attempt.id, judgedCommit: judgedCommit,
                    requestedChanges: requestedChanges.joined(separator: "\n")
                )
                guard budget.allowsAnotherRound else {
                    // The round budget is spent: the worker is not dispatched again on this Attempt.
                    return .roundsExhausted(lens: .review)
                }
                worked = try await work(
                    frame: frame, payloads: InstructionPayloads(roundFeedback: Self.feedback(of: rounds)),
                    resumeSession: worked.session
                )
            }
        }
    }

    /// One worker pass; a question or a reported failure ends the Attempt (thrown as a `PassStop`).
    func work(
        frame: CardRunFrame, payloads: InstructionPayloads, resumeSession: String?
    ) async throws -> (commit: String, session: String?) {
        let worker = try await runPass(.worker, frame: frame, payloads: payloads, resumeSession: resumeSession)
        guard case .worker(let work) = worker.result else {
            throw CardRunError.unexpectedResult(expected: .worker, found: worker.result.pass)
        }
        switch work.outcome {
        case .completed(let commit, _):
            return (commit, worker.session)
        case .question:
            throw PassStop(ending: .question)
        case .failed(let reason):
            throw PassStop(ending: .hardFailure(.reported(reason: reason)))
        }
    }

    /// One pass: composes its instruction, dispatches it in the lane's Worktree and records the step. A
    /// failed run, or a route the machine cannot run at all, ends the Attempt (thrown as a `PassStop`).
    private func runPass(
        _ pass: RunPass, frame: CardRunFrame, payloads: InstructionPayloads = .none, resumeSession: String? = nil
    ) async throws -> (result: DispatchResult, session: String?) {
        guard let attempt = frame.attempt, let route = frame.route else {
            preconditionFailure("a pass is dispatched only after the Route is resolved and the Attempt recorded")
        }
        try frame.revalidateLease()
        // A new Attempt's preserved work is context, not a starting tree (OQ60): merged onto every
        // pass instruction of this Attempt unless the caller already carries its own `wip` payload.
        let effectivePayloads = payloads.wip == nil && frame.wipContext != nil
            ? InstructionPayloads(
                wip: frame.wipContext, answeredQuestion: payloads.answeredQuestion,
                bankedReplies: payloads.bankedReplies, roundFeedback: payloads.roundFeedback
            )
            : payloads
        let request = AgentDispatchRequest(
            runID: frame.context.act.runID, issueID: frame.card.issueID, attemptID: attempt.id, route: route,
            pass: pass, instruction: instruction(for: pass, route: route, frame: frame, payloads: effectivePayloads),
            worktreePath: frame.worktree.path, resumeSession: resumeSession
        )
        let report: AgentDispatchReport
        do {
            report = try await dispatch.dispatch(request)
        } catch let refusal as AgentDispatchRefusal {
            // A route the machine cannot run is a capability failure of that Route, never an engine fault.
            try frame.record(Self.step(of: pass), detail: "route unavailable")
            throw PassStop(ending: .hardFailure(.reported(reason: "route unavailable: \(refusal)")))
        }
        try frame.record(Self.step(of: pass), detail: Self.describe(report.outcome))
        if let ending = AttemptEnding(failedRun: report.outcome) {
            throw PassStop(ending: ending)
        }
        guard case .completed(let result) = report.outcome else {
            preconditionFailure("a run that did not fail completed")
        }
        return (result, report.session)
    }

    /// The instruction for one pass, from the Card, its Brief and Definition of Done, its repository and
    /// the Route. The result file path is the Dispatch seam's to stamp: it owns the run directory.
    private func instruction(
        for pass: RunPass, route: Route, frame: CardRunFrame, payloads: InstructionPayloads
    ) -> Instruction {
        // `Engine` has its own DoDClause (the Managed Block's); the Instruction takes Domain's.
        let clauses = frame.readiness.clauses.map { clause in
            Domain.DoDClause(
                id: clause.cid, text: clause.text,
                citation: clause.locationID.isEmpty ? nil : SpecCitation(clause.locationID)
            )
        }
        let repo = frame.repository ?? Repo(
            name: frame.card.repository, path: frame.worktree.path, role: RepoRole(rawValue: "unconfigured")
        )
        return Instruction(
            pass: pass, card: frame.instructionCard, brief: frame.readiness.brief, definitionOfDone: clauses,
            repository: InstructionRepository(
                repo: repo, worktreePath: frame.worktree.path, featureBranch: frame.branch.name,
                check: frame.check
            ),
            route: route, payloads: payloads, resultFilePath: ""
        )
    }

    private static func step(of pass: RunPass) -> CardRunStep {
        switch pass {
        case .architect: .architect
        case .worker: .worker
        case .reviewer: .reviewer
        }
    }

    /// The kind of a run's outcome, never anything the model wrote.
    private static func describe(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .completed: "completed"
        case .failed(let status): "failed(exit status \(status))"
        case .crashedUnknown: "crashed-unknown"
        }
    }

    static func describe(_ result: RepositoryCheckResult) -> String {
        switch result {
        case .passed: "passed"
        case .failed: "failed"
        case .declaredNone: "declared none"
        }
    }
}
