import Foundation

extension LedgerStore {
    /// Timestamps are stored as ISO 8601 text in UTC to the second, like every other timestamp in the
    /// Ledger, so they compare correctly as text too. Whole seconds are exact in a `Date`, so an
    /// instant survives the round trip through text unchanged; a 60-second heartbeat needs no more.
    static let timestampStyle = Date.ISO8601FormatStyle()

    /// Formats a date as an ISO 8601 timestamp for storage in the Ledger.
    static func timestamp(_ date: Date) -> String {
        date.formatted(timestampStyle)
    }

    /// The instant as the Ledger will record it, so that a recorded value equals the value read back.
    static func stored(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Parses an ISO 8601 timestamp from the Ledger. Calls `onError` to construct and throw the
    /// error if parsing fails, so callers can throw their own error type.
    static func date(_ text: String, onError: @escaping () -> Error) throws -> Date {
        do {
            return try Date(text, strategy: timestampStyle)
        } catch {
            throw onError()
        }
    }
}
