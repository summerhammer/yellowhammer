/// The size every description Yellowhammer composes for one Board Connection's board must fit
/// (`description_budget` in the machine file). Measured in the unit the board counts, which its adapter
/// supplies along with the board's own limit.
public struct DescriptionBudget: Equatable, Sendable {
    /// What a Board Connection gets when it configures no `description_budget`.
    public static let defaultValue = 10_000

    /// A configured value that is not a valid description budget.
    public enum Refusal: Error, Equatable, Sendable {
        /// Below 1.
        case belowOne(Int)
        /// Above ``BoardDescriptionLimit/budgetCeiling``, which it carries.
        case aboveCeiling(Int, ceiling: Int)
    }

    /// The budget, in the limit's unit.
    public let value: Int
    public let limit: BoardDescriptionLimit

    /// `configured` when set, else ``defaultValue`` (capped at the ceiling, for a board whose ceiling
    /// is below it). A configured value below 1 or above the ceiling is refused.
    public init(configured: Int?, limit: BoardDescriptionLimit) throws(Refusal) {
        let ceiling = limit.budgetCeiling
        guard let configured else {
            self.value = min(Self.defaultValue, ceiling)
            self.limit = limit
            return
        }
        guard configured >= 1 else { throw .belowOne(configured) }
        guard configured <= ceiling else { throw .aboveCeiling(configured, ceiling: ceiling) }
        self.value = configured
        self.limit = limit
    }

    /// `description`'s length in the limit's unit.
    public func measure(_ description: String) -> Int {
        limit.unit.length(of: description)
    }

    /// Whether `description` is within the budget.
    public func fits(_ description: String) -> Bool {
        measure(description) <= value
    }
}
