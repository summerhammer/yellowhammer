import Foundation
import Synchronization
import Testing

@testable import Journal

/// What a test observes from the beat and the body, guarded because they run in different tasks.
private final class TestState: Sendable {
    private let beats = Mutex(0)
    private let cancellationSeen = Mutex(false)

    var beatCount: Int { beats.withLock { $0 } }
    var bodySawCancellation: Bool { cancellationSeen.withLock { $0 } }

    /// Returns the count after this beat.
    @discardableResult
    func recordBeat() -> Int {
        beats.withLock { count in
            count += 1
            return count
        }
    }

    func markBodySawCancellation() {
        cancellationSeen.withLock { $0 = true }
    }

    /// Waits until at least `count` beats have happened. Bounded so a broken loop fails, not hangs.
    func waitForBeats(_ count: Int) async throws {
        for _ in 0..<500 where beatCount < count {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Test("withLeaseHeartbeat returns body's value when it completes successfully")
func heartbeatReturnsBodyValue() async throws {
    let expectedValue = 42
    let result = try await withLeaseHeartbeat(
        every: .milliseconds(20),
        beat: { },
        body: { expectedValue }
    )
    #expect(result == expectedValue)
}

@Test("withLeaseHeartbeat propagates body errors")
func heartbeatPropagatesBodyError() async throws {
    enum TestError: Error, Equatable {
        case bodyFailed
    }

    do {
        _ = try await withLeaseHeartbeat(
            every: .milliseconds(20),
            beat: { },
            body: {
                throw TestError.bodyFailed
            }
        )
        Issue.record("Body error was not thrown")
    } catch TestError.bodyFailed {
        // Expected
    }
}

@Test("The beat runs repeatedly while the body is in progress, and the body's value returns")
func heartbeatBeatsAtInterval() async throws {
    let state = TestState()
    // The body waits for the third beat rather than sleeping a fixed time, so a slow machine
    // cannot fail the test; it can only make it slower.
    let result = try await withLeaseHeartbeat(
        every: .milliseconds(20),
        beat: { state.recordBeat() },
        body: {
            try await state.waitForBeats(3)
            return "done"
        }
    )

    #expect(result == "done")
    #expect(state.beatCount >= 3)
}

@Test("Beat error on second call cancels body and propagates beat's error")
func heartbeatBeatErrorCancelsBody() async throws {
    enum TestError: Error, Equatable {
        case beatFailed
    }

    let state = TestState()

    do {
        _ = try await withLeaseHeartbeat(
            every: .milliseconds(10),
            beat: {
                if state.recordBeat() >= 2 {
                    throw TestError.beatFailed
                }
            },
            body: {
                try await withTaskCancellationHandler(
                    operation: {
                        while true {
                            try await Task.sleep(for: .milliseconds(10))
                            try Task.checkCancellation()
                        }
                    },
                    onCancel: {
                        state.markBodySawCancellation()
                    }
                )
                return "should not reach"
            }
        )
        Issue.record("Beat error was not thrown")
    } catch TestError.beatFailed {
        // Expected: the beat error, not CancellationError
    }

    #expect(state.beatCount >= 2)
    #expect(state.bodySawCancellation)
}

@Test("Once body finishes, no further beats happen")
func heartbeatStopsAfterBody() async throws {
    let state = TestState()

    _ = try await withLeaseHeartbeat(
        every: .milliseconds(10),
        beat: { state.recordBeat() },
        body: {
            try await state.waitForBeats(2)
            return "done"
        }
    )

    let countAfterBody = state.beatCount
    try await Task.sleep(for: .milliseconds(100))

    #expect(state.beatCount == countAfterBody)
}
