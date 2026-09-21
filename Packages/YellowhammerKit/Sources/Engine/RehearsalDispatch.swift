import Domain
import Synchronization

/// The Dispatch seam for a Rehearsal Night: it never spawns anything (a rehearsal Night never dispatches
/// an agent CLI), and answers each pass from the result files shipped with the engine. The default script
/// is a clean run — architect plans, worker completes, reviewer approves; the author Act's selection selects
/// one Feature and its breakdown drafts one Card — and a test drives a failure by
/// scripting another fixture for a pass.
public final class RehearsalDispatch: AgentDispatch, Sendable {
    public static let defaultScript: [RunPass: RehearsalResultFixture] = [
        .architect: .architectPlanned,
        .worker: .workerCompleted,
        .reviewer: .reviewerApproved,
        .selection: .selectionSelected,
        .breakdown: .breakdownDrafted,
        .verifier: .verifierReported
    ]

    private let script: [RunPass: RehearsalResultFixture]
    private let requests = Mutex<[AgentDispatchRequest]>([])

    /// `script` overrides the default fixture for the passes it names.
    public init(script: [RunPass: RehearsalResultFixture] = [:]) {
        self.script = Self.defaultScript.merging(script) { _, scripted in scripted }
    }

    /// Every request answered so far, in order.
    public var answered: [AgentDispatchRequest] { requests.withLock { $0 } }

    public func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        requests.withLock { $0.append(request) }
        guard let fixture = script[request.pass] else {
            preconditionFailure("RehearsalDispatch has no fixture for pass \(request.pass)")
        }
        let outcome = fixture == .verifierReported ? Self.verifierOutcome(for: request) : fixture.outcome()
        return AgentDispatchReport(outcome: outcome, origin: .rehearsalFixture(fixture.rawValue))
    }

    /// The `verifier-reported` fixture cannot know the clause ids it will be asked about, so it is
    /// synthesized from the request: every clause its ``VerificationInstruction`` names is reported `met`
    /// under fixed rehearsal copy. It asserts nothing about any code — a rehearsal Night reads none.
    private static func verifierOutcome(for request: AgentDispatchRequest) -> RunOutcome {
        guard case .verification(let instruction) = request.instruction else {
            preconditionFailure("a verifier request carries a verification instruction")
        }
        let clauses = instruction.clauses.map {
            VerifiedClause(
                cid: $0.cid, issueID: $0.issueID, verdict: .met,
                whatWasChecked: "Fixture data: a rehearsal Night reads no code.",
                interpretation: "Fixture data: the clause as written."
            )
        }
        return .completed(.verifier(VerifierResult(outcome: .reported(clauses: clauses))))
    }
}
