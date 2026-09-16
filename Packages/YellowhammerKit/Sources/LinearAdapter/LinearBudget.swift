import Domain
import Foundation

/// Reads Linear's rate-limit headers into a ``BoardBudget``.
///
/// Every field is best effort: an absent, renamed or unparseable header leaves its field nil and never
/// fails the request.
enum LinearBudget {
    static func parse(_ response: HTTPURLResponse) -> BoardBudget? {
        let budget = BoardBudget(
            requestsLimit: integer("x-ratelimit-requests-limit", in: response),
            requestsRemaining: integer("x-ratelimit-requests-remaining", in: response),
            requestsResetAt: date("x-ratelimit-requests-reset", in: response),
            complexityLimit: integer("x-ratelimit-complexity-limit", in: response),
            complexityRemaining: integer("x-ratelimit-complexity-remaining", in: response),
            complexityResetAt: date("x-ratelimit-complexity-reset", in: response),
            lastRequestComplexity: integer("x-complexity", in: response)
        )
        return budget == BoardBudget() ? nil : budget
    }

    /// `value(forHTTPHeaderField:)` matches case-insensitively.
    private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces)
    }

    private static func integer(_ name: String, in response: HTTPURLResponse) -> Int? {
        header(name, in: response).flatMap { Int($0) }
    }

    /// The spec does not pin the unit: epoch seconds or epoch milliseconds, told apart by magnitude.
    /// Anything else yields nil rather than a wrong date.
    private static func date(_ name: String, in response: HTTPURLResponse) -> Date? {
        guard let value = header(name, in: response), let number = Double(value), number.isFinite, number > 0 else {
            return nil
        }
        // Epoch seconds pass 1e11 only in the year 5138; epoch milliseconds passed it in 1973.
        let seconds = number >= 1e11 ? number / 1000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    /// `retry-after` as delta seconds. An HTTP-date form is not parsed and yields nil.
    static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let value = header("retry-after", in: response), let seconds = Double(value),
              seconds.isFinite, seconds >= 0 else {
            return nil
        }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }
}
