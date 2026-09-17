import Engine
import Journal

/// The build Act's `CardRunner` until running a Card is implemented (roadmap P8.4): every lane stops
/// on its first runnable Card rather than dispatching nothing silently.
struct DispatchPendingCardRunner: CardRunner {
    func run(card: CardRecord, in lane: RepoLane, context: BuildActContext, readiness: CardReadiness) async throws {
        throw CardRunPendingError(issueID: card.issueID)
    }
}

struct CardRunPendingError: Error, Equatable, Sendable, CustomStringConvertible {
    let issueID: String

    var description: String {
        "Running Card \(issueID) is not implemented yet (roadmap P8.4); the lane stopped before dispatching it"
    }
}
