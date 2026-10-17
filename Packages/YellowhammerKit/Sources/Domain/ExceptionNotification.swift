/// The local Exception Notification for one Project's Night, posted by a one-shot headless launch of
/// `Yellowhammer.app` (morning-report/notify-the-operator-of-exceptions).
///
/// It accelerates a record that already exists: every event it announces is on the Night Card first —
/// with one exception (OQ71, Halted-Without-Night-Card Notification Ruling): when a halted Act has no
/// Night Card to record on (none is open, or the halted comment write is aborted or permanently
/// failed), the local notification still posts as `.haltedUnrecorded`, since nothing else will tell the
/// Operator this Night halted. Only *halted*, *haltedUnrecorded* and *closed* post locally — *opened*
/// is recorded on the Night Card and posts nothing (Decision Gates Ruling, G-10) — so `Event` has no
/// `opened` case. *Closed* has a second copy, `.closedCompletionPending`, for the one write that is
/// still pending when the notification posts: the Night Card's completion (Transient Board Failure
/// Ruling, item 7). Each notification names its Project, and there is no combined notification across
/// Projects.
///
/// `arguments` and `init(arguments:)` are the launch contract between `yh` and the app.
public struct ExceptionNotification: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        /// The Night halted; `reason` names why.
        case halted(reason: String)
        /// The Night halted and nothing was recorded on the Night Card first (OQ71): either no Night
        /// Card is open, or the halted comment write was aborted or permanently failed.
        case haltedUnrecorded
        /// The Night closed. `failureLine` is the Night's failure line — the headline of its first unrecovered
        /// Failure Notice — when it has one; the copy carries it and adds no event
        /// (morning-report/notify-the-operator-of-exceptions).
        case closed(failureLine: String? = nil)
        /// The Night closed, but the Night Card's completion is still pending in the Outbox (the board
        /// could not be reached), so the Night Card is not updated yet (Transient Board Failure Ruling,
        /// item 7). `failureLine` is as for `closed`.
        case closedCompletionPending(failureLine: String? = nil)
        /// The Night-closing Act halted before it closed the Night (Transient Board Failure Ruling, item
        /// 12): the Night is not closed and its Night Card is not updated yet. `reason` names why it halted.
        case haltedNightOpen(reason: String)
    }

    public enum ArgumentError: Error, Equatable, Sendable {
        case missingValue(String)
        case unknownArgument(String)
        case duplicateArgument(String)
        case missingProject
        case invalidProject(String)
        case missingEvent
        case unknownEvent(String)
        /// A halted Night must name why it halted.
        case missingReason
        /// Only `halted` and `halted-night-open` carry a reason — `haltedUnrecorded` is a halted Night too,
        /// but names none.
        case unexpectedReason
    }

    /// The flag that switches the app into headless post mode.
    public static let postFlag = "--post-notification"

    public let project: ProjectID
    public let event: Event

    public init(project: ProjectID, event: Event) {
        self.project = project
        self.event = event
    }

    /// The launch arguments that post this notification, starting with `postFlag`.
    public var arguments: [String] {
        var arguments = [Self.postFlag, "--project", project.rawValue]
        switch event {
        case .halted(let reason):
            arguments += ["--event", "halted", "--reason", reason]
        case .haltedUnrecorded:
            arguments += ["--event", "halted-unrecorded"]
        case .closed(let failureLine):
            arguments += ["--event", "closed"] + Self.reasonArguments(failureLine)
        case .closedCompletionPending(let failureLine):
            arguments += ["--event", "closed-completion-pending"] + Self.reasonArguments(failureLine)
        case .haltedNightOpen(let reason):
            arguments += ["--event", "halted-night-open", "--reason", reason]
        }
        return arguments
    }

    /// `--reason <line>` for a failure line, nothing without one — the argv of a clean Night is unchanged.
    private static func reasonArguments(_ failureLine: String?) -> [String] {
        failureLine.map { ["--reason", $0] } ?? []
    }

    /// Reads a notification from a process's launch arguments.
    ///
    /// Returns `nil` when `postFlag` is absent — an ordinary launch. Arguments before `postFlag` are
    /// ignored, because the process name and whatever the launcher adds come first. Everything after
    /// it must be exactly this contract's options, or it throws.
    public init?(arguments: [String]) throws(ArgumentError) {
        guard let flagIndex = arguments.firstIndex(of: Self.postFlag) else { return nil }
        let options = try Self.options(arguments[arguments.index(after: flagIndex)...])
        guard let projectValue = options["--project"] else { throw .missingProject }
        guard let project = ProjectID(rawValue: projectValue) else {
            throw .invalidProject(projectValue)
        }
        let event = try Self.event(from: options)
        self.init(project: project, event: event)
    }

    /// The `Event` named by `--event`, validated against the `--reason` the same options carry —
    /// split out of `init(arguments:)` to keep it under the cyclomatic-complexity limit.
    private static func event(from options: [String: String]) throws(ArgumentError) -> Event {
        let reason = options["--reason"]
        let name = options["--event"]
        if let name, let reasonless = Self.reasonlessEvents[name] {
            guard reason == nil else { throw .unexpectedReason }
            return reasonless
        }
        switch name {
        case nil:
            throw .missingEvent
        case "halted":
            guard let reason, !reason.allSatisfy(\.isWhitespace) else { throw .missingReason }
            return .halted(reason: reason)
        case "halted-night-open":
            guard let reason, !reason.allSatisfy(\.isWhitespace) else { throw .missingReason }
            return .haltedNightOpen(reason: reason)
        case "closed":
            return .closed(failureLine: Self.failureLine(reason))
        case "closed-completion-pending":
            return .closedCompletionPending(failureLine: Self.failureLine(reason))
        case let other?:
            throw .unknownEvent(other)
        }
    }

    /// The events that carry no `--reason`, by their `--event` name.
    private static let reasonlessEvents: [String: Event] = ["halted-unrecorded": .haltedUnrecorded]

    /// A closed notification's optional failure line: a blank `--reason` is no line.
    private static func failureLine(_ reason: String?) -> String? {
        guard let reason, !reason.allSatisfy(\.isWhitespace) else { return nil }
        return reason
    }

    /// The `--name value` pairs after `postFlag`, each named at most once.
    private static func options(_ tail: ArraySlice<String>) throws(ArgumentError) -> [String: String] {
        var options: [String: String] = [:]
        var remaining = tail.makeIterator()
        while let name = remaining.next() {
            guard ["--project", "--event", "--reason"].contains(name) else {
                throw .unknownArgument(name)
            }
            guard let value = remaining.next() else { throw .missingValue(name) }
            guard options.updateValue(value, forKey: name) == nil else {
                throw .duplicateArgument(name)
            }
        }
        return options
    }

    /// The notification's title: the Project it belongs to, since N Projects post side by side.
    public var title: String { project.rawValue }

    /// The notification's body.
    public var body: String {
        switch event {
        case .halted(let reason): "Night halted: \(reason)"
        case .haltedUnrecorded:
            "\(project.rawValue) halted before its Night Card could be opened — nothing is recorded " +
                "on the board for this Night. Check the Journal or run yh status."
        case .closed(let failureLine): failureLine.map { "Night closed — \($0)" } ?? "Night closed"
        case .haltedNightOpen(let reason):
            "Night halted: \(reason) — the Night is not closed and its Night Card is not updated in Linear yet"
        case .closedCompletionPending(let failureLine):
            failureLine.map { "Night closed — \($0). The Night Card is not updated in Linear yet" }
                ?? "Night closed — the Night Card is not updated in Linear yet"
        }
    }
}
