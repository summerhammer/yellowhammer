import Domain
import Foundation
import Journal

/// What became of one delivered entry.
public struct OutboxDelivery: Equatable, Sendable {
    public let entry: OutboxEntry
    public let outcome: Outcome

    public enum Outcome: Equatable, Sendable {
        /// The board applied it now; a create carries the created id.
        case applied(BoardObjectID?)
        /// The board had already applied a write under this client id — a replay after a crash or a lost
        /// response — and the entry is recorded as applied without duplicating anything.
        case alreadyApplied(BoardObjectID)
        /// Never sent: the description could not be fenced.
        case aborted(reason: String)
        /// Sent and refused for good, or given up after repeated transient failures. Recorded for the Night Summary.
        case failed(reason: String)
        /// Still pending: re-attempted on a later delivery.
        case deferred(Deferral)
    }

    public enum Deferral: Equatable, Sendable {
        /// The board refused for its rate limit. The budget is installation-wide.
        case rateLimited(retryAfter: Duration?)
        /// The board could not be reached or its answer could not be read.
        case transient(String)
        /// This run does not hold the Card's Lease; the write waits for the run that does.
        case cardLeaseNotHeld(String)
        /// An earlier entry stopped delivery before this one's turn.
        case behindAnotherEntry
    }
}

/// Every delivery one `deliverPending` made, in order.
public struct OutboxDeliveryReport: Equatable, Sendable {
    public let deliveries: [OutboxDelivery]

    public init(deliveries: [OutboxDelivery]) {
        self.deliveries = deliveries
    }

    public var applied: [OutboxDelivery] {
        deliveries.filter {
            switch $0.outcome {
            case .applied, .alreadyApplied: true
            default: false
            }
        }
    }

    public var failed: [OutboxDelivery] {
        deliveries.filter {
            if case .failed = $0.outcome { return true }
            return false
        }
    }
}

public enum OutboxError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The run's Act-scoped Lease is lost: it expired, or another run took the Project. Nothing more is written.
    case staleRun(JournalError)
    /// An `updateIssue` carried a description. A description is written only by the fenced rewrite.
    case descriptionNotFenced(key: String)
    /// A create names a parent entry that is not applied: the group is out of order or broken.
    case parentNotApplied(entryID: Int64, parentKey: String)
    case payloadUnreadable(entryID: Int64)
    case archivedIssue(BoardObjectID)

    public var description: String {
        switch self {
        case .staleRun(let error):
            "the run no longer holds the Project, so nothing more is written to the board: \(error)"
        case .descriptionNotFenced(let key):
            "write \(key) carries a description; a description is written only through rewriteManagedBlock"
        case .parentNotApplied(let entryID, let parentKey):
            "Outbox entry \(entryID) names parent \(parentKey), which is not applied"
        case .archivedIssue(let issue):
            "issue \(issue.rawValue) is archived"
        case .payloadUnreadable(let entryID):
            "Outbox entry \(entryID) has a payload that does not name its issue"
        }
    }
}
