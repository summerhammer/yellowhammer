import Domain
import Foundation
import Journal

/// How a Card's run ended, before the Journal is told.
enum CardRunEnd: Sendable {
    /// The reviewer approved after a passing (or declared-none) Check.
    case approved(commit: String)
    /// An Attempt-ending outcome: a failed run, a reported failure, or the worker's question.
    case ending(AttemptEnding)
    /// A Round is owed: the reviewer asked for changes. (A failed Check's Round is recorded as it happens, in
    /// the Check's own loop; the review's loop is P8.6.)
    case round(RoundRequest)
    /// The Round budget ran out with the work still red, and the Round was already recorded: the Attempt
    /// stays open and the reviewer never saw the code. Blocking the Card is P8.6/P8.7.
    case roundsExhausted(lens: Lens)
}

/// A Round the run owes, with what the next Round on the same worker needs (Rounds are P8.6).
struct RoundRequest: Sendable {
    let lens: Lens
    let verdict: String
    let requestedChanges: String?
    let judgedCommit: String
    /// The worker's opaque session, so a later Round resumes the same conversation. Not persisted: keeping
    /// it across Acts needs a Journal column (P8.6).
    let workerSession: String?
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
        var worked = try await work(frame: frame, payloads: .none, resumeSession: nil)
        while true {
            let checked = try await runCheck(frame: frame, attemptID: attempt.id)
            guard case .failed(let output, let exitStatus) = checked else { break }

            // A failed Check is a Round of this Attempt, never a new Attempt: same worker, Route, Worktree.
            let (rounds, budget) = try await recordCheckRound(
                frame: frame, attemptID: attempt.id, commit: worked.commit, output: output, exitStatus: exitStatus
            )
            guard budget.allowsAnotherRound else {
                // A reviewer never sees red code.
                return .roundsExhausted(lens: .check)
            }
            worked = try await work(
                frame: frame, payloads: InstructionPayloads(roundFeedback: Self.feedback(of: rounds)),
                resumeSession: worked.session
            )
        }

        return try await review(frame: frame, commit: worked.commit, workerSession: worked.session)
    }

    /// One worker pass; a question or a reported failure ends the Attempt (thrown as a `PassStop`).
    private func work(
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

    private func review(frame: CardRunFrame, commit: String, workerSession: String?) async throws -> CardRunEnd {
        let reviewer = try await runPass(.reviewer, frame: frame)
        guard case .reviewer(let judged) = reviewer.result else {
            throw CardRunError.unexpectedResult(expected: .reviewer, found: reviewer.result.pass)
        }
        switch judged.outcome {
        case .approved:
            return .approved(commit: commit)
        case .changesRequested(let judgedCommit, _, let requestedChanges):
            return .round(RoundRequest(
                lens: .review, verdict: "changes requested",
                requestedChanges: requestedChanges.joined(separator: "\n"), judgedCommit: judgedCommit,
                workerSession: workerSession
            ))
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
        let request = AgentDispatchRequest(
            runID: frame.context.act.runID, issueID: frame.card.issueID, attemptID: attempt.id, route: route,
            pass: pass, instruction: instruction(for: pass, route: route, frame: frame, payloads: payloads),
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
