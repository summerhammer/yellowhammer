import Foundation
import Synchronization
import Testing

@testable import Journal

private final class TestState: @unchecked Sendable {
    private(set) var beatCount = 0
    private let sawCancellationLock = Mutex(false)

    var bodySawCancellation: Bool {
        sawCancellationLock.withLock { $0 }
    }

    func incrementBeatCount() {
        beatCount += 1
    }

    func markBodySawCancellation() {
        sawCancellationLock.withLock { $0 = true }
    }
}

@Test("withLeaseHeartbeat returns body's value when it completes successfully")
func heartbeatReturnsBodyValue() async throws {
    let expectedValue = 42
    let result = try await withLeaseHeartbeat(
        every: Duration(secondsComponent: 0, attosecondsComponent: 20_000_000_000_000),
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
            every: Duration(secondsComponent: 0, attosecondsComponent: 20_000_000_000_000),
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

@Test("With 20 ms interval and body sleeping 150 ms, beat count is ≥ 3 and body's value returns")
func heartbeatBeatsAtInterval() async throws {
    let state = TestState()
    let interval = Duration.milliseconds(20)
    let result = try await withLeaseHeartbeat(
        every: interval,
        beat: {
            state.incrementBeatCount()
        },
        body: {
            try await Task.sleep(for: Duration.milliseconds(150))
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
            every: Duration.milliseconds(10),
            beat: {
                state.incrementBeatCount()
                if state.beatCount >= 2 {
                    throw TestError.beatFailed
                }
            },
            body: {
                try await withTaskCancellationHandler(
                    operation: {
                        while true {
                            try await Task.sleep(for: Duration.milliseconds(10))
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
    let interval = Duration.milliseconds(30)

    _ = try await withLeaseHeartbeat(
        every: interval,
        beat: {
            state.incrementBeatCount()
        },
        body: {
            try await Task.sleep(for: Duration.milliseconds(50))
            return "done"
        }
    )

    let countAfterBody = state.beatCount
    try await Task.sleep(for: Duration.milliseconds(100))

    #expect(state.beatCount == countAfterBody)
}
