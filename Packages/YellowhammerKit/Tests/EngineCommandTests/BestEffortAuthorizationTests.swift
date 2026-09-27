import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// roadmap P17.5, item 1 (follow-up slice): `bestEffort` swallows every error a `try?` would, except an
// authorization failure, which it rethrows so the enclosing Act halts on it. `FeatureRollUpMaintenance
// .maintainRollUps` and `UnadoptedCardRefresh.refresh` are the two sites `EngineInvocation` calls
// through it; both now use the same primitive, so testing the primitive plus one integration through
// `maintainRollUps` covers both — `UnadoptedCardRefresh` is not independently re-tested here.

private struct SampleFault: Error, CustomStringConvertible {
    let description: String
}

@Suite("bestEffort authorization classification (P17.5)")
struct BestEffortAuthorizationTests {
    @Test("bestEffort swallows a non-authorization error and returns nil")
    func swallowsNonAuthorizationError() async throws {
        let result = try await bestEffort { () -> Int in
            throw SampleFault(description: "boom")
        }
        #expect(result == nil)
    }

    @Test("bestEffort rethrows an authorization failure instead of swallowing it")
    func rethrowsAuthorizationFailure() async throws {
        await #expect(throws: BoardError.self) {
            _ = try await bestEffort { () -> Int in
                throw BoardError.notAuthenticated("sign-in expired")
            }
        }
    }

    @Test("bestEffort returns the value on success")
    func returnsValueOnSuccess() async throws {
        let result = try await bestEffort { () -> Int in 42 }
        #expect(result == 42)
    }

    @Test("maintainRollUps halts on an authorization refusal instead of swallowing it")
    func maintainRollUpsHaltsOnAuthorizationRefusal() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        await world.board.refuseNext(.notAuthenticated("sign-in expired"))

        await #expect(throws: BoardError.self) {
            try await FeatureRollUpMaintenance.maintainRollUps(
                night: world.night, journal: journal, outbox: world.outbox
            )
        }
    }

    @Test("maintainRollUps stays best-effort for a non-authorization refusal (unreachable)")
    func maintainRollUpsStaysBestEffortForUnreachable() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        await world.board.refuseNext(.unreachable("timed out"))

        try await FeatureRollUpMaintenance.maintainRollUps(night: world.night, journal: journal, outbox: world.outbox)
    }
}
