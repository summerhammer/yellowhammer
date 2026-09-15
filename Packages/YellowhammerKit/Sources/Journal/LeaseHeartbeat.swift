import Foundation

/// Runs `body` while calling `beat` every `interval`. When `body` finishes, the heartbeat stops and
/// `body`'s result is returned. When `beat` throws (the lease was lost: sleep past the TTL, or a
/// takeover), `body` is cancelled and the beat's error is thrown, so a stale run stops as soon as it
/// learns it is stale.
public func withLeaseHeartbeat<T: Sendable>(
    every interval: Duration,
    beat: @escaping @Sendable () throws -> Void,
    body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            // Never returns a value: it runs until cancelled (Task.sleep throws CancellationError) or a beat throws.
            while true {
                try await Task.sleep(for: interval)
                try beat()
            }
        }
        defer { group.cancelAll() }
        // The first child to finish decides: the body's value, the body's error, or a lost lease from a beat.
        // Under outer cancellation the sleep's CancellationError arrives here and cancels the body too.
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
