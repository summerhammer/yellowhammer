import Domain
import Foundation
import Journal

// The verifier dispatch (roadmap P10.5): one `verifier` pass through the Routing Table, exactly as
// ``AuthoringRoute`` routes an authoring pass, but never on a Route that wrote the Cycle's code.

extension FeatureVerification {
    /// Dispatches `pending` as one verifier pass and returns the Route that answered with the verdicts by
    /// clause key. A capability failure of a Route — a refusal, a non-zero exit, a `failed` result, or a
    /// result that does not cover exactly the dispatched clauses — moves on to the next Route, and records
    /// one `AuthoringRouteRejected` event (`pass: .verifier`) for it, as an authoring walk does, so the
    /// Night's account keeps each Route's own account. A usage-limited Route is deferred, not excluded, and
    /// records none. A Crashed-Unknown run, or an exhausted table, throws ``VerificationDispatchFault``.
    func dispatchVerifier(
        _ pending: [VerificationCandidate], checkouts: VerifierCheckouts, context: LandActFeatureContext
    ) async throws -> (Route, [String: VerifiedClause]) {
        let act = context.act
        let writers = try act.journal.attemptRoutes(cycleID: context.cycleID)
        let base = try instructionBase(pending, checkouts: checkouts, context: context)
        var tried: Set<Route> = Set(writers)
        var lastFailure: String?
        var ordinal: Int64 = 0
        while true {
            let request = RouteRequest(kind: .authoring, repoRole: nil, override: .none, excludedRoutes: tried)
            let resolution = try resolver.resolve(request, backingOffCLIs: act.journal.backingOffCLIs())
            guard case .resolved(let resolved) = resolution else {
                throw VerificationDispatchFault(reason: resolution.usageBackoffAccount
                    ?? exhaustedReason(writers: writers, lastFailure: lastFailure))
            }
            let route = resolved.route
            ordinal += 1
            // A dispatch that records no prompt (rehearsal) gets no capture request, as in `AuthoringRoute`.
            let provenance = dispatch.recordsPrompts
                ? try requestPromptCapture(context: context, ordinal: ordinal)
                : nil
            let dispatchRequest = Self.verifierRequest(
                base, route: route, ordinal: ordinal, runID: act.runID, provenance: provenance
            )
            let report: AgentDispatchReport
            do {
                report = try await dispatch.dispatch(dispatchRequest)
            } catch let refusal as AgentDispatchRefusal {
                tried.insert(route)
                lastFailure = "verifier on \(route) is unavailable: \(refusal)"
                try recordRejection(
                    VerifierRejection(cause: .unavailable, reason: "\(refusal)"),
                    route: route, ordinal: Int(ordinal), act: act
                )
                continue
            }
            try record(report.origin, route: route, ordinal: Int(ordinal), context: act)
            let judged = try judgeVerifier(report.outcome, pending: pending, route: route, act: act)
            if let verdicts = judged.verdicts { return (route, verdicts) }
            if !judged.usageLimited { tried.insert(route) }
            lastFailure = judged.failure
            if let rejection = judged.rejection {
                try recordRejection(rejection, route: route, ordinal: Int(ordinal), act: act)
            }
        }
    }

    /// Mints the verifier pass's prompt record id, builds its provenance, and journals the capture request
    /// before the dispatch.
    private func requestPromptCapture(context: LandActFeatureContext, ordinal: Int64) throws -> DispatchProvenance {
        let act = context.act
        let recordID = UUID().uuidString.lowercased()
        let provenance = DispatchProvenance(
            recordID: recordID,
            family: .verifier,
            projectID: act.journal.projectID.rawValue,
            runID: act.runID.rawValue,
            nightID: act.night.id,
            featureIssueID: context.feature.issueID,
            routeTry: Int(ordinal)
        )
        try act.journal.append(
            .promptCaptureRequested(
                recordID: recordID, pass: .verifier, cardID: nil, issueID: context.feature.issueID,
                attemptID: nil, round: nil, ordinal: Int(ordinal)
            ),
            act: act.act, runID: act.runID, nightID: act.night.id
        )
        return provenance
    }

    /// One Route's failure as its `AuthoringRouteRejected` event records it: the class, and the account.
    private struct VerifierRejection {
        let cause: AuthoringRouteRejectionCause
        let reason: String
    }

    private struct JudgedVerifier {
        let verdicts: [String: VerifiedClause]?
        let failure: String?
        var usageLimited = false
        /// Set for a Route the walk excludes; nil for an answer and for a deferred, usage-limited Route.
        var rejection: VerifierRejection?
    }

    private func judgeVerifier(
        _ outcome: RunOutcome, pending: [VerificationCandidate], route: Route, act: ActContext
    ) throws -> JudgedVerifier {
        let failure: String
        let rejection: VerifierRejection
        switch outcome {
        case .completed(let result):
            switch Self.verdicts(in: result, covering: pending) {
            case .success(let verdicts): return JudgedVerifier(verdicts: verdicts, failure: nil)
            case .failure(let verdictFailure):
                failure = "verifier on \(route) \(verdictFailure)"
                rejection = VerifierRejection(cause: verdictFailure.cause, reason: verdictFailure.reason)
            }
        case .usageLimited:
            _ = try act.recordUsageLimit(outcome, route: route)
            return JudgedVerifier(
                verdicts: nil, failure: "\(route.cli) usage limit; Verification waits for CLI backoff",
                                  usageLimited: true)
        case .failed(let exitStatus):
            failure = "verifier on \(route) exited with status \(exitStatus)"
            rejection = VerifierRejection(cause: .exited, reason: failure)
        case .contractViolation(let error):
            failure = "verifier on \(route) broke the result contract: \(error)"
            rejection = VerifierRejection(cause: .brokeResultContract, reason: failure)
        case .timedOut(let after):
            failure = "verifier on \(route) ran out of time after \(after.wholeMinutes) min"
            rejection = VerifierRejection(cause: .timedOut, reason: failure)
        case .crashedUnknown(let cause):
            throw VerificationDispatchFault(reason: "verifier on \(route) crashed with no outcome (\(cause)); "
                + "a Crashed-Unknown run excludes no Route and ends Verification for this Act")
        }
        return JudgedVerifier(verdicts: nil, failure: failure, rejection: rejection)
    }

    private func recordRejection(
        _ rejection: VerifierRejection, route: Route, ordinal: Int, act: ActContext
    ) throws {
        try act.journal.append(
            .authoringRouteRejected(
                pass: .verifier, route: route.description, ordinal: ordinal, cause: rejection.cause,
                reason: rejection.reason
            ),
            act: act.act, runID: act.runID, nightID: act.night.id
        )
    }

    private static func verifierRequest(
        _ base: InstructionBase, route: Route, ordinal: Int64, runID: RunID,
        provenance: DispatchProvenance? = nil
    ) -> AgentDispatchRequest {
        let instruction = VerificationInstruction(
            route: route, featureTitle: base.featureTitle, clauses: base.clauses,
            specificationSource: base.source, repositories: base.repositories
        )
        return AgentDispatchRequest(
            runID: runID, issueID: runDirectoryName, attemptID: ordinal, route: route,
            pass: .verifier, instruction: .verification(instruction), worktreePath: base.source.path,
            additionalReadableDirectories: base.repositories.map(\.directory),
            provenance: provenance
        )
    }

    private func exhaustedReason(writers: [Route], lastFailure: String?) -> String {
        var reason = "the Routing Table has no Route left for the authoring Kind"
        if lastFailure == nil {
            let named = writers.map(\.description).sorted().joined(separator: ", ")
            reason = "no Route other than the ones that wrote the code"
                + (named.isEmpty ? "" : " (\(named))") + " is left in the Routing Table for the authoring Kind"
        }
        return lastFailure.map { "\(reason); last failure: \($0)" } ?? reason
    }

    /// The verdicts a completed result carries, or why it is a capability failure: `failed`, not a
    /// verifier result, or not covering exactly the dispatched `(issue, cid)` set.
    private static func verdicts(
        in result: DispatchResult, covering pending: [VerificationCandidate]
    ) -> Result<[String: VerifiedClause], VerdictFailure> {
        guard case .verifier(let verifier) = result else {
            return .failure(VerdictFailure(
                cause: .invalidOutput, reason: "answered with a result that is not a verifier result"
            ))
        }
        switch verifier.outcome {
        case .failed(let reason):
            return .failure(VerdictFailure(
                cause: .reportedFailed, reason: reason, description: "reported failed: \(reason)"
            ))
        case .reported(let clauses):
            var byKey: [String: VerifiedClause] = [:]
            for clause in clauses {
                byKey["\(clause.issueID)\u{1F}\(clause.cid)"] = clause
            }
            guard byKey.count == clauses.count, Set(byKey.keys) == Set(pending.map(\.key)) else {
                return .failure(VerdictFailure(
                    cause: .invalidOutput, reason: "did not judge exactly the clauses it was given"
                ))
            }
            return .success(byKey)
        }
    }

    /// Why a completed result is a capability failure: its rejection class, the account its event records, and
    /// the walk's last-failure wording (after `verifier on <Route> `).
    private struct VerdictFailure: Error, CustomStringConvertible {
        let cause: AuthoringRouteRejectionCause
        let reason: String
        let description: String

        init(cause: AuthoringRouteRejectionCause, reason: String, description: String? = nil) {
            self.cause = cause
            self.reason = reason
            self.description = description ?? reason
        }
    }

    // MARK: - Instruction inputs

    private struct InstructionBase {
        let featureTitle: String
        let clauses: [VerificationClause]
        let source: ProjectSpecificationSource
        let repositories: [VerificationRepository]
    }

    /// Every repository the verifier is handed, sorted: the Feature's `touched_repos`, not N, and the repository
    /// of every live Card of the Cycle.
    func verifiedRepositories(_ context: LandActFeatureContext) throws -> [String] {
        let journal = context.act.journal
        var names = Set(try journal.touchedRepositories(featureID: context.feature.id))
        let cards = try journal.cards(cycleID: context.cycleID)
        for card in cards where card.state != .shelved && !card.isRemovedFromBoard {
            names.insert(card.repository)
        }
        return names.sorted()
    }

    private func instructionBase(
        _ pending: [VerificationCandidate], checkouts: VerifierCheckouts, context: LandActFeatureContext
    ) throws -> InstructionBase {
        let act = context.act
        guard let repositories = act.repositories, case .resolved(let source) = repositories.specificationSourceLookup
        else {
            throw VerificationFault(reason: "this Project has no single specification source to verify against")
        }
        let noCheckRepositories = Set(try act.journal.repositoriesDeclaringNoCheck(cycleID: context.cycleID))
        let touched = try verifiedRepositories(context).map { name -> VerificationRepository in
            guard let checkout = checkouts.byRepository[name] else {
                throw VerificationFault(reason: "no checkout was made of repository \"\(name)\" for the verifier")
            }
            let branch = try act.journal.resolvedFeatureBranch(feature: context.feature, repository: name)
            return VerificationRepository(
                name: name, directory: checkout.directory, featureBranch: branch?.name ?? "not recorded",
                judgedCommit: checkout.judged?.commit, noPushedBranch: checkout.judged?.noPushedBranch ?? false,
                checkResults: try act.journal.checkRuns(featureID: context.feature.id, repository: name).map {
                    VerificationCheckResult(
                        command: $0.command, judgedCommit: $0.judgedCommit, exitStatus: $0.exitStatus
                    )
                },
                checkDeclaredNone: noCheckRepositories.contains(name)
            )
        }
        return InstructionBase(
            featureTitle: context.feature.issueID,
            clauses: pending.map {
                VerificationClause(
                    issueID: $0.clause.issueID, cid: $0.clause.cid, text: $0.clause.text,
                    location: $0.clause.locationID
                )
            },
            source: source, repositories: touched
        )
    }

    private func record(_ origin: AgentDispatchOrigin, route: Route, ordinal: Int, context: ActContext) throws {
        let fixture: String?
        switch origin {
        case .agentCLIProcess: fixture = nil
        case .rehearsalFixture(let name): fixture = name
        }
        try context.journal.append(
            .authoringDispatched(pass: .verifier, route: route.description, ordinal: ordinal, fixture: fixture),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
    }
}
