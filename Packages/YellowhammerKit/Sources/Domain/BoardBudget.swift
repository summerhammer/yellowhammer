import Foundation

/// The request budget as the board last reported it.
///
/// The budget is workspace-wide and shared across Projects: every Project reading the same board draws
/// on it, so it is never attributable to one Project's own reads. Every field is optional, because a
/// missing or renamed signal must never fail a request.
public struct BoardBudget: Equatable, Sendable {
    public var requestsLimit: Int?
    public var requestsRemaining: Int?
    public var requestsResetAt: Date?
    public var complexityLimit: Int?
    public var complexityRemaining: Int?
    public var complexityResetAt: Date?
    /// What the request that reported this budget cost.
    public var lastRequestComplexity: Int?

    public init(
        requestsLimit: Int? = nil,
        requestsRemaining: Int? = nil,
        requestsResetAt: Date? = nil,
        complexityLimit: Int? = nil,
        complexityRemaining: Int? = nil,
        complexityResetAt: Date? = nil,
        lastRequestComplexity: Int? = nil
    ) {
        self.requestsLimit = requestsLimit
        self.requestsRemaining = requestsRemaining
        self.requestsResetAt = requestsResetAt
        self.complexityLimit = complexityLimit
        self.complexityRemaining = complexityRemaining
        self.complexityResetAt = complexityResetAt
        self.lastRequestComplexity = lastRequestComplexity
    }
}
