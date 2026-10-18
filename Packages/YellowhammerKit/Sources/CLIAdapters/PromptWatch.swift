import Darwin
import Foundation

/// One macOS permission prompt seen on screen, and the process it was raised for (#555).
public struct PromptEvent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// `securityd` asked the user to allow a process to use a Keychain item.
        case keychain
    }

    public let kind: Kind
    /// The process the prompt is for. `nil` when the log line names none: such a prompt can never be
    /// attributed to a pass.
    public let clientPID: pid_t?
    /// Operator-facing: the prompt, the process and, when the line names it, the Keychain item.
    public let detail: String

    public init(kind: Kind, clientPID: pid_t?, detail: String) {
        self.kind = kind
        self.clientPID = clientPID
        self.detail = detail
    }
}

/// Where ``AgentCLIProcess`` learns that a macOS permission prompt is on screen. A local seam so tests
/// can stand in for the unified log — not a Port.
public protocol PromptSource: Sendable {
    /// Starts watching for one run, before its CLI is spawned, and returns once the watch is ready.
    /// `nil` when no watch could start: the run then goes unwatched, bounded by its pass timeout alone.
    func start() async -> (any PromptWatching)?
}

/// One run's watch. ``AgentCLIProcess`` stops it on every exit path, so it never outlives the pass.
public protocol PromptWatching: Sendable {
    /// The prompts seen since the previous call.
    func drain() async -> [PromptEvent]
    /// Ends the watch. Safe to call more than once.
    func stop() async
}

/// The default ``PromptSource``: `/usr/bin/log stream` for the life of one run, narrowed to the one
/// `securityd` line that says a Keychain prompt is being displayed. That line is logged at the default
/// level, so no `--info` or `--debug` is needed (measured 2026-10-18 on macOS 27):
///
///     process: /usr/sbin/securityd   subsystem: com.apple.securityd   category: kcacl
///     eventMessage: displaying keychain prompt for /usr/bin/security(7365); ACL: <AclValidationContext…>
///
/// TCC prompts are not watched: no retained `com.apple.TCC` line proves a dialog was shown rather than a
/// policy evaluated.
///
/// Known limitation: ending the pass does not dismiss the dialog. On macOS 27 the `SecurityAgent` window
/// stayed on screen after its client was killed, until someone answered it by hand (measured 2026-10-18).
/// The dialog names the item. An Operator who later clicks Always Allow on it widens that item's ACL to the
/// dead client's binary, so the Operator guidance stays Deny. Yellowhammer does not dismiss `SecurityAgent`
/// itself.
public struct UnifiedLogPromptSource: PromptSource {
    public static let predicate =
        #"process == "securityd" AND eventMessage BEGINSWITH "displaying keychain prompt for ""#

    /// How long ``start()`` waits for `log` to print its header, after which the stream is connected
    /// (measured at about 0.2 s). Past it, the run proceeds unwatched.
    public let readinessTimeout: Duration

    public init(readinessTimeout: Duration = .seconds(1)) {
        self.readinessTimeout = readinessTimeout
    }

    public func start() async -> (any PromptWatching)? {
        await PromptWatch.start(readinessTimeout: readinessTimeout)
    }
}

/// The unified-log watch of one run: a `/usr/bin/log stream` child writing NDJSON to a private
/// temporary file, which ``drain()`` reads on from where it last stopped. A file, not a pipe, so
/// nothing has to read in the background between polls.
///
/// The stream runs under ``watchdogScript``, in a process group of its own, so a `yh` that dies without
/// running Swift code (SIGKILL, a kernel kill, a crash) takes the stream down with it (#579): nothing
/// resident is left behind.
actor PromptWatch: PromptWatching {
    /// `sh -c` script: `$1` is the pid of the process the stream must not outlive, `$2` the file it writes,
    /// and `$3…` the stream command. Polls once a second; when the watched process or the stream is gone it
    /// ends the stream and deletes the file, which only the watchdog is left to do after a SIGKILL.
    static let watchdogScript = """
        watched=$1; output=$2; shift 2
        "$@" &
        stream=$!
        while kill -0 "$watched" 2>/dev/null && kill -0 "$stream" 2>/dev/null; do sleep 1; done
        kill "$stream" 2>/dev/null
        rm -f "$output"
        """

    private let pid: pid_t
    private let output: URL
    private var handle: FileHandle?
    private var partialLine = Data()
    private var stopped = false

    private init(pid: pid_t, output: URL, handle: FileHandle) {
        self.pid = pid
        self.output = output
        self.handle = handle
    }

    static func start(readinessTimeout: Duration) async -> PromptWatch? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-prompt-watch-\(UUID().uuidString).ndjson")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forReadingFrom: output)
        else { return nil }

        let spawned = ProcessGroup.spawn(
            executable: "/bin/sh",
            arguments: [
                "-c", watchdogScript, "sh", String(getpid()), output.path,
                "/usr/bin/log", "stream", "--style", "ndjson", "--predicate", UnifiedLogPromptSource.predicate
            ],
            environment: ProcessInfo.processInfo.environment,
            worktreePath: "/",
            outputPath: nil,
            standardOutputPath: output.path
        )
        guard case .success(let pid) = spawned else {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
            return nil
        }

        let watch = PromptWatch(pid: pid, output: output, handle: handle)
        guard await watch.awaitHeader(within: readinessTimeout) else {
            await watch.stop()
            return nil
        }
        return watch
    }

    /// `log` prints `Filtering the log data using …` once its stream is connected.
    private func awaitHeader(within timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let size = try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int, size > 0 {
                return true
            }
            if ProcessGroup.reapNonBlocking(pid: pid) != nil {
                stopped = true
                return false
            }
            await AgentCLIProcess.sleepThroughCancellation(for: .milliseconds(20))
        }
        return false
    }

    func drain() -> [PromptEvent] {
        guard let handle, let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        partialLine.append(data)
        var events: [PromptEvent] = []
        while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partialLine[partialLine.startIndex..<newline]
            partialLine = Data(partialLine[partialLine.index(after: newline)...])
            if let event = PromptLogLine.parse(Data(line)) {
                events.append(event)
            }
        }
        return events
    }

    /// SIGTERMs the watchdog's process group (it leads one: the shell, `log` and its `sleep`), reaps the
    /// shell (SIGKILL to the group after a second), and deletes the file.
    func stop() async {
        defer {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: output)
        }
        guard !stopped else { return }
        stopped = true
        ProcessGroup.signal(group: pid, SIGTERM)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if ProcessGroup.reapNonBlocking(pid: pid) != nil { return }
            await AgentCLIProcess.sleepThroughCancellation(for: .milliseconds(10))
        }
        ProcessGroup.signal(group: pid, SIGKILL)
        ProcessGroup.reapBlocking(pid: pid)
    }
}

/// Reads one `log stream --style ndjson` line into a ``PromptEvent``. Pure, so it is tested on lines
/// captured from a real prompt.
public enum PromptLogLine {
    private struct Entry: Decodable {
        let processImagePath: String?
        let eventMessage: String?
    }

    static let keychainPromptPrefix = "displaying keychain prompt for "

    /// `nil` for anything that is not `securityd` saying it displays a Keychain prompt for a process —
    /// `log`'s plain-text header included.
    public static func parse(_ line: Data) -> PromptEvent? {
        guard line.first == UInt8(ascii: "{"),
              let entry = try? JSONDecoder().decode(Entry.self, from: line),
              entry.processImagePath?.hasSuffix("/securityd") == true,
              let message = entry.eventMessage
        else { return nil }
        return parseKeychainPrompt(message)
    }

    /// `displaying keychain prompt for <path>(<pid>)`, optionally followed by `; ACL: <acl>`. The path may
    /// hold spaces and parentheses, so the pid is the last parenthesised number before the ACL.
    static func parseKeychainPrompt(_ message: String) -> PromptEvent? {
        guard message.hasPrefix(keychainPromptPrefix) else { return nil }
        let rest = message.dropFirst(keychainPromptPrefix.count)
        let aclMarker = rest.range(of: "; ACL: ")
        let client = aclMarker.map { rest[..<$0.lowerBound] } ?? rest
        guard client.hasSuffix(")"), let open = client.lastIndex(of: "(") else { return nil }
        let path = client[..<open]
        guard !path.isEmpty, let pid = pid_t(client[client.index(after: open)..<client.index(before: client.endIndex)])
        else { return nil }

        var detail = "Keychain prompt for \(path) (pid \(pid))"
        if let aclMarker, let item = keychainItem(in: rest[aclMarker.upperBound...]) {
            detail += ", item \(item)"
        }
        return PromptEvent(kind: .keychain, clientPID: pid, detail: detail)
    }

    /// The `desc:` of the ACL's first `KeychainPromptAclSubject`: the item the prompt asks about.
    private static func keychainItem(in acl: Substring) -> Substring? {
        guard let subject = acl.range(of: "KeychainPromptAclSubject("),
              let desc = acl[subject.upperBound...].range(of: "desc:")
        else { return nil }
        let item = acl[desc.upperBound...].prefix { $0 != ")" && $0 != ">" }
        return item.isEmpty ? nil : item
    }
}
