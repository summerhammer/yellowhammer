import OrcaADEAdapter
import Synchronization

/// Records every argument list `run` was called with, and returns scripted outputs in order. The
/// last scripted output repeats once its queue is exhausted, so a test needs to script only what it
/// checks.
final class StubOrcaCommandRunner: OrcaCommandRunner, Sendable {
    private struct State {
        var calls: [[String]] = []
        var outputs: [OrcaCommandOutput]
    }

    private let state: Mutex<State>

    init(outputs: [OrcaCommandOutput] = []) {
        state = Mutex(State(outputs: outputs))
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    func run(_ arguments: [String]) async throws -> OrcaCommandOutput {
        state.withLock { state in
            state.calls.append(arguments)
            guard !state.outputs.isEmpty else {
                return OrcaCommandOutput(exitCode: 0, stdout: "", stderr: "")
            }
            let next = state.outputs[0]
            if state.outputs.count > 1 {
                state.outputs.removeFirst()
            }
            return next
        }
    }
}
