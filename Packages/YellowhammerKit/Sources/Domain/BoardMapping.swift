/// One thing a Board Mapping can name: a workflow state or a `Card Type` label on the board (glossary:
/// Board Mapping; board-projection/provision-the-board). The raw value is the key in a Project file's
/// `[board.linear.mapping]` table, and the key the Journal records a persisted id under.
public enum BoardMappingRole: String, CaseIterable, Sendable, Codable {
    // The two custom workflow states Yellowhammer provisions.
    case waitingOnYou = "waiting_on_you"
    case blocked
    // The team's native states, selected by workflow category.
    case unstarted
    case started
    case completed
    case canceled
    // The three `Card Type` labels.
    case featureCard = "feature_card"
    case workCard = "work_card"
    case nightCard = "night_card"

    /// The two roles Yellowhammer provisions as its own workflow states.
    public static let customStates: [BoardMappingRole] = [.waitingOnYou, .blocked]
    /// The four roles the team's native states fill.
    public static let nativeStates: [BoardMappingRole] = [.unstarted, .started, .completed, .canceled]
    /// The three `Card Type` label roles.
    public static let cardTypeLabels: [BoardMappingRole] = [.featureCard, .workCard, .nightCard]

    /// The category the mapped workflow state must have; nil for a label role. Yellowhammer's spelling
    /// of Linear's `canceled` type is ``BoardWorkflowStateCategory/shelved``.
    public var category: BoardWorkflowStateCategory? {
        switch self {
        case .waitingOnYou, .blocked, .started: .started
        case .unstarted: .unstarted
        case .completed: .completed
        case .canceled: .shelved
        case .featureCard, .workCard, .nightCard: nil
        }
    }

    public var isLabel: Bool { category == nil }

    /// The name Yellowhammer provisions for a custom state; nil for any other role.
    public var customStateName: String? {
        switch self {
        case .waitingOnYou: "Waiting on You"
        case .blocked: "Blocked"
        default: nil
        }
    }

    /// The Card Type a label role stands for; nil for a workflow-state role.
    public var cardType: CardType? {
        switch self {
        case .featureCard: .featureCard
        case .workCard: .workCard
        case .nightCard: .nightCard
        default: nil
        }
    }

    public init(cardType: CardType) {
        switch cardType {
        case .featureCard: self = .featureCard
        case .workCard: self = .workCard
        case .nightCard: self = .nightCard
        }
    }
}

/// The Board Mapping a Project declares in `[board.linear.mapping]`: ids of existing board objects that
/// stand in for what Yellowhammer would otherwise provision or select by category. Ids are opaque
/// (ADR-001); verifying one exists with the right category is the Engine's, against the board.
public struct BoardMapping: Equatable, Sendable {
    public var ids: [BoardMappingRole: BoardObjectID]

    /// Keys of retired mapping entries the file still carried (`block_reason`, `override`,
    /// `kept_in_flight`, `abandoned`). Accepted and ignored: they neither fail the load nor cause setup to
    /// recreate the state or group they once mapped.
    public var retiredKeys: [String]

    public static let empty = BoardMapping()

    /// Every key a retired mapping entry may still be spelled with.
    public static let retiredKeyNames: Set<String> = ["block_reason", "override", "kept_in_flight", "abandoned"]

    public init(ids: [BoardMappingRole: BoardObjectID] = [:], retiredKeys: [String] = []) {
        self.ids = ids
        self.retiredKeys = retiredKeys
    }

    public subscript(role: BoardMappingRole) -> BoardObjectID? { ids[role] }

    public var isEmpty: Bool { ids.isEmpty }
}

/// Where a persisted board-object id came from (board-projection/provision-the-board).
public enum BoardFootprintSource: String, Sendable, Codable {
    /// Yellowhammer created the object itself.
    case provisioned
    /// The Operator named it in a Board Mapping.
    case mapped
    /// An existing same-name object accepted as Yellowhammer's own on this Project's Journal provenance.
    case bootstrapped
}

/// One resolved id of the footprint, as the Journal holds it for a team.
public struct BoardFootprintRecord: Equatable, Sendable {
    public var team: BoardObjectID
    public var role: BoardMappingRole
    public var objectID: BoardObjectID
    public var source: BoardFootprintSource

    public init(team: BoardObjectID, role: BoardMappingRole, objectID: BoardObjectID, source: BoardFootprintSource) {
        self.team = team
        self.role = role
        self.objectID = objectID
        self.source = source
    }
}
