import Domain

/// The Operator's board identity, machine-configured and never validated at load time (Operator Identity
/// Ruling — 2026-09-23): a missing Operator identity is never a load-time failure, so this holds the
/// configured value and resolves it against the current board only when a write actually needs an
/// assignee.
///
/// OQ66: an Operator identity that is configured but no longer an active workspace member never Blocks
/// the Act and never refuses the write — the state is still written, only the assignment is skipped.
public struct OperatorIdentity: Equatable, Sendable {
    public let configured: BoardObjectID?

    public init(configured: BoardObjectID?) {
        self.configured = configured
    }

    /// No Operator identity configured.
    public static let none = OperatorIdentity(configured: nil)

    /// The assignee for a Waiting on You write: nil when unconfigured or when there is no board to check
    /// against; otherwise the configured identity when the board reports it an active workspace member,
    /// nil when the board reports it inactive or not found (OQ66). When the check itself fails — the
    /// board could not establish whether the identity is still active — this returns `configured`
    /// rather than guessing stale: the Outbox's own delivery handles a write that turns out to be wrong.
    public func assignee(on board: (any Board)?) async -> BoardObjectID? {
        guard let configured, let board else { return nil }
        do {
            return try await board.isActiveMember(configured) ? configured : nil
        } catch {
            return configured
        }
    }

    /// The workspace members setup offers as Operator candidates: active, not an app, and not
    /// Yellowhammer's own identity (Operator Identity Ruling, OQ66), sorted case-insensitively by
    /// `displayName`, then `name`, then `id`. This is the policy; the adapter only reports flags.
    public static func candidates(from members: [BoardMember]) -> [BoardMember] {
        members
            .filter { $0.isActive && !$0.isApp && !$0.isSelf }
            .sorted { lhs, rhs in
                let lhsDisplayName = lhs.displayName.lowercased()
                let rhsDisplayName = rhs.displayName.lowercased()
                if lhsDisplayName != rhsDisplayName { return lhsDisplayName < rhsDisplayName }
                let lhsName = lhs.name.lowercased()
                let rhsName = rhs.name.lowercased()
                if lhsName != rhsName { return lhsName < rhsName }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }
}
