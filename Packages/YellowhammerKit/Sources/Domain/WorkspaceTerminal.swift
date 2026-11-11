/// An opaque terminal handle issued by Orca ADE. Yellowhammer never parses it.
public struct TerminalHandle: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A newly created terminal and its session leader, not the agent CLI's process.
public struct WorkspaceTerminal: Hashable, Sendable {
    public let handle: TerminalHandle
    public let sessionLeaderPID: Int32

    public init(handle: TerminalHandle, sessionLeaderPID: Int32) {
        self.handle = handle
        self.sessionLeaderPID = sessionLeaderPID
    }
}

/// Metadata for a terminal Orca ADE still knows, including an orphaned terminal.
public struct WorkspaceTerminalState: Hashable, Sendable {
    public let orphaned: Bool
    /// Some runtime versions omit the session leader when showing a terminal.
    public let sessionLeaderPID: Int32?

    public init(orphaned: Bool, sessionLeaderPID: Int32?) {
        self.orphaned = orphaned
        self.sessionLeaderPID = sessionLeaderPID
    }
}
