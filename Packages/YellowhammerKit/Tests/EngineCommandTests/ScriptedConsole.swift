@testable import EngineCommand
import Synchronization

/// A console that answers from queued scripted responses (`nil` means EOF) and records every prompt
/// asked, in order. Shared by `SetupTests`, `SetupInteractiveTests` and `SetupConfigTests`.
final class ScriptedConsole: SetupConsole, @unchecked Sendable {
    private struct State {
        var answers: [String?]
        var secretAnswers: [String?]
        var prompts: [String] = []
    }

    private let storage: Mutex<State>

    init(answers: [String?] = [], secretAnswers: [String?] = []) {
        storage = Mutex(State(answers: answers, secretAnswers: secretAnswers))
    }

    func ask(_ prompt: String) -> String? {
        storage.withLock { state in
            state.prompts.append(prompt)
            return state.answers.isEmpty ? nil : state.answers.removeFirst()
        }
    }

    func askSecret(_ prompt: String) -> String? {
        storage.withLock { state in
            state.prompts.append(prompt)
            return state.secretAnswers.isEmpty ? nil : state.secretAnswers.removeFirst()
        }
    }

    var prompts: [String] { storage.withLock { $0.prompts } }
}
