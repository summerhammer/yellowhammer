import Foundation

/// One process a normal-exit sweep found still running after its agent CLI leader exited, and
/// signalled — a background tool process the CLI started (claude's Bash tool `setsid`s; codex
/// makes tool commands group leaders), reparented to `launchd` at the leader's exit rather than at
/// its reap. Reported so a caller can see what was cleaned up; nothing in the engine consumes it
/// yet.
public struct LeftoverProcess: Equatable, Sendable {
    public let pid: pid_t
    public let commandName: String
    public let processGroup: pid_t
    public let session: pid_t

    public init(pid: pid_t, commandName: String, processGroup: pid_t, session: pid_t) {
        self.pid = pid
        self.commandName = commandName
        self.processGroup = processGroup
        self.session = session
    }
}
