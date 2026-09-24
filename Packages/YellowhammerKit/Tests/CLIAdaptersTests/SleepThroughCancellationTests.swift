@testable import CLIAdapters
import Foundation
import Testing

/// The abort path runs inside the cancelled dispatch task, so its grace and kill polls must not use a
/// sleep that a cancelled task skips.
@Suite("Sleeping through cancellation")
struct SleepThroughCancellationTests {
    @Test("Task.sleep returns at once inside a cancelled task, which is why the abort path cannot use it")
    func plainSleepIsSkippedWhenCancelled() async {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            let clock = ContinuousClock()
            let start = clock.now
            try? await Task.sleep(for: .seconds(5))
            return clock.now - start
        }
        task.cancel()
        #expect(await task.value < .seconds(1))
    }

    @Test("sleepThroughCancellation waits out its whole duration inside a cancelled task")
    func sleepsFullDurationWhenCancelled() async {
        let duration = Duration.milliseconds(200)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            let clock = ContinuousClock()
            let start = clock.now
            await AgentCLIProcess.sleepThroughCancellation(for: duration)
            return (elapsed: clock.now - start, stillCancelled: Task.isCancelled)
        }
        task.cancel()
        let result = await task.value
        #expect(result.elapsed >= duration)
        #expect(result.stillCancelled)
    }
}
