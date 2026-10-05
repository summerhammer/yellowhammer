import Domain
import Foundation
import Journal

// The verifier dispatch (roadmap P10.5): one `verifier` pass through the Routing Table, exactly as
// ``AuthoringRoute`` routes an authoring pass, but never on a Route that wrote the Cycle's code.

extension FeatureVerification {
    /// Dispatches `pending` as one verifier pass and returns the Route that answered with the verdicts by
    /// clause key. A capability failure of a Route — a refusal, a non-zero exit, a `failed` result, or a
    /// result that does not cover exactly the dispatched clauses — moves on to the next Route; a
    /// Crashed-Unknown run, or an exhausted table, throws ``VerificationDispatchFault``.
    func dispatchVerifier(
        _ pending: [VerificationCandidate], context: LandActFeatureContext
    ) async throws -> (Route, [String: VerifiedClause]) {
        let act = context.act
        let writers = try act.journal.attemptRoutes(cycleID: context.cycleID)
        let base = try instructionBase(pending, context: context)
        var tried: Set<Route> = Set(writers)
        var lastFailure: String?
        var ordinal: Int64 = 0
        while true {
            let request = RouteRequest(kind: .authoring, repoRole: nil, override: .none, excludedRoutes: tried)
            guard case .resolved(let resolved) = try resolver.resolve(request) else {
                throw VerificationDispatchFault(reason: exhaustedReason(writers: writers, lastFailure: lastFailure))
            }
            let route = resolved.route
            ordinal += 1
            let instruction = VerificationInstruction(
                route: route, featureTitle: base.featureTitle, clauses: base.clauses,
                specificationSource: base.source, repositories: base.repositories, resultFilePath: ""
            )
            let dispatchRequest = AgentDispatchRequest(
                runID: act.runID, issueID: Self.runDirectoryName, attemptID: ordinal, route: route,
                pass: .verifier, instruction: .verification(instruction), worktreePath: base.source.path,
                additionalReadableDirectories: base.repositories.map(\.directory)
            )
            let report: AgentDispatchReport
            do {
                report = try await dispatch.dispatch(dispatchRequest)
            } catch let refusal as AgentDispatchRefusal {
                tried.insert(route)
                lastFailure = "verifier on \(route) is unavailable: \(refusal)"
                continue
            }
            try record(report.origin, route: route, ordinal: Int(ordinal), context: act)
            switch report.outcome {
            case .completed(let result):
                switch Self.verdicts(in: result, covering: pending) {
                case .success(let verdicts):
                    return (route, verdicts)
                case .failure(let failure):
                    tried.insert(route)
                    lastFailure = "verifier on \(route) \(failure)"
                }
            case .failed(let exitStatus):
                tried.insert(route)
                lastFailure = "verifier on \(route) exited with status \(exitStatus)"
            case .crashedUnknown(let cause):
                throw VerificationDispatchFault(
                    reason: "verifier on \(route) crashed with no outcome (\(cause)); a Crashed-Unknown run "
                        + "excludes no Route and ends Verification for this Act"
                )
            }
        }
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
            return .failure(VerdictFailure("answered with a result that is not a verifier result"))
        }
        switch verifier.outcome {
        case .failed(let reason):
            return .failure(VerdictFailure("reported failed: \(reason)"))
        case .reported(let clauses):
            var byKey: [String: VerifiedClause] = [:]
            for clause in clauses {
                byKey["\(clause.issueID)\u{1F}\(clause.cid)"] = clause
            }
            guard byKey.count == clauses.count, Set(byKey.keys) == Set(pending.map(\.key)) else {
                return .failure(VerdictFailure("did not judge exactly the clauses it was given"))
            }
            return .success(byKey)
        }
    }

    private struct VerdictFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Instruction inputs

    private struct InstructionBase {
        let featureTitle: String
        let clauses: [VerificationClause]
        let source: ProjectSpecificationSource
        let repositories: [VerificationRepository]
    }

    private func instructionBase(
        _ pending: [VerificationCandidate], context: LandActFeatureContext
    ) throws -> InstructionBase {
        let act = context.act
        guard let repositories = act.repositories, case .resolved(let source) = repositories.specificationSourceLookup
        else {
            throw VerificationFault(reason: "this Project has no single specification source to verify against")
        }
        var names = Set(try act.journal.touchedRepositories(featureID: context.feature.id))
        for card in try act.journal.cards(cycleID: context.cycleID) where card.state != .cancelled {
            names.insert(card.repository)
        }
        let touched = try names.sorted().map { name -> VerificationRepository in
            guard let repo = repositories.workingRepo(named: name) else {
                throw VerificationFault(reason: "the Feature touched repository \"\(name)\", which is not configured")
            }
            let held = try act.journal.heldWorktree(featureID: context.feature.id, repository: name)
            let directory = (held?.isHeld == true ? held?.path : nil) ?? repo.path
            let branch = try act.journal.resolvedFeatureBranch(feature: context.feature, repository: name)
            return VerificationRepository(
                name: name, directory: directory, featureBranch: branch?.name ?? "not recorded"
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
