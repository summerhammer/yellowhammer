import Foundation

/// Interactive `yh setup`'s prompts. Never called in `--init` or `--config` mode.
protocol SetupConsole: Sendable {
    /// Prints `prompt` with no trailing newline, then reads one line. `nil` means end of file.
    func ask(_ prompt: String) -> String?
}

/// Reads from the real terminal with `readLine()`.
struct RealSetupConsole: SetupConsole {
    func ask(_ prompt: String) -> String? {
        print(prompt, terminator: "")
        return readLine()
    }
}
