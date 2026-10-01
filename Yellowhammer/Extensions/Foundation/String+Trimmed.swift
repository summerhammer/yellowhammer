import Foundation

extension StringProtocol {
    /// The string without leading or trailing spaces and tabs; newlines are kept (it trims `.whitespaces`).
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
