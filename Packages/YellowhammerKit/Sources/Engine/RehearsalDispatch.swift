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
        .breakdown: .breakdownDrafted
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
        return AgentDispatchReport(outcome: fixture.outcome(), origin: .rehearsalFixture(fixture.rawValue))
    }
}
