import Foundation

/// The Night's account laid along time: every entry in the order it happened, the scale the Night is drawn
/// on, and where a playhead opens.
///
/// A plain value, worked out once per account. A view that follows a playhead re-renders on every frame of a
/// drag, so everything that sorts or scans the whole account is here, and a ``NightMoment`` only searches it.
public struct NightTimeline: Sendable {
    public let account: NightAccount
    /// The whole Night.
    public let scale: NightTimeScale
    /// Every entry of every run, in the order it occurred. Entries that occurred at the same time keep the
    /// order of the account.
    public let items: [Item]
    /// When each problem entry occurred, earliest first.
    public let problemTimes: [Date]
    /// Where the playhead opens: the Night's first problem, else its opening.
    public let opening: Date

    public init(account: NightAccount) {
        let recorded = account.runs.flatMap { run in run.entries.map { Item(run: run, entry: $0) } }
        // Sorted on the position in the account as well as the time, so ties never depend on the sort's
        // stability.
        let ordered = recorded.enumerated().sorted { lhs, rhs in
            let (left, right) = (lhs.element.entry.occurredAt, rhs.element.entry.occurredAt)
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        let items = ordered.map(\.element)
        let problemTimes = items.filter(\.entry.isProblem).map(\.entry.occurredAt)

        self.account = account
        self.scale = NightTimeScale(account: account)
        self.items = items
        self.problemTimes = problemTimes
        self.opening = problemTimes.first ?? account.openedAt
    }

    /// The Night at `time`.
    public func moment(at time: Date) -> NightMoment {
        NightMoment(timeline: self, time: time)
    }

    /// One entry with the run that recorded it.
    public struct Item: Identifiable, Equatable, Sendable {
        public let run: NightAccount.ActRun
        public let entry: NightAccount.Entry

        /// The entry's row id in the Journal.
        public var id: Int64 { entry.id }
    }
}
