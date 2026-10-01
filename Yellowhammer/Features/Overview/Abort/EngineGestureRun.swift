import Foundation

/// The run-and-tail shared by the app's Operator gestures that run `yh`: Stop the engine and Abort Attempt.
@MainActor
enum EngineGestureRun {
    /// Runs `yh` with `arguments`. Returns yh's own last lines when it could not be run or exited
    /// non-zero, nil when it succeeded. The app never invents a result.
    static func failure(engine: SetupEngine, command: String, arguments: [String]) async -> String? {
        var lines: [String] = []
        do {
            let status = try await engine.run(arguments: arguments) { lines.append($0) }
            return status == 0 ? nil : tail(lines, fallback: "yh \(command) exited with status \(status).")
        } catch {
            return tail(lines, fallback: "\(error)")
        }
    }

    private static func tail(_ lines: [String], fallback: String) -> String {
        lines.isEmpty ? fallback : lines.suffix(5).joined(separator: "\n")
    }
}
