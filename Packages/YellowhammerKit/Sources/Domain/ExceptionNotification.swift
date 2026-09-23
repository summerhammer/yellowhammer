/// The local Exception Notification for one Project's Night, posted by a one-shot headless launch of
/// `Yellowhammer.app` (morning-report/notify-the-operator-of-exceptions).
///
/// It accelerates a record that already exists: every event it announces is on the Night Card first.
/// Only *halted* and *closed* post locally — *opened* is recorded on the Night Card and posts nothing
/// (Decision Gates Ruling, G-10) — so `Event` has no `opened` case. Each notification names its
/// Project, and there is no combined notification across Projects.
///
/// `arguments` and `init(arguments:)` are the launch contract between `yh` and the app.
public struct ExceptionNotification: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        /// The Night halted; `reason` names why.
        case halted(reason: String)
        case closed
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
        /// Only a halted Night carries a reason.
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
        case .closed:
            arguments += ["--event", "closed"]
        }
        return arguments
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
        let reason = options["--reason"]
        switch options["--event"] {
        case nil:
            throw .missingEvent
        case "halted":
            guard let reason, !reason.allSatisfy(\.isWhitespace) else { throw .missingReason }
            self.init(project: project, event: .halted(reason: reason))
        case "closed":
            guard reason == nil else { throw .unexpectedReason }
            self.init(project: project, event: .closed)
        case let other?:
            throw .unknownEvent(other)
        }
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
        case .closed: "Night closed"
        }
    }
}
