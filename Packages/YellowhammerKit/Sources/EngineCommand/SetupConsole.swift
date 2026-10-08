import Foundation

/// Interactive `yh setup`'s prompts. Never called in `--init` or `--config` mode.
protocol SetupConsole: Sendable {
    /// Prints `prompt` with no trailing newline, then reads one line. `nil` means end of file.
    func ask(_ prompt: String) -> String?
    /// Like ``ask(_:)`` for a secret: the typed answer is not echoed. `nil` means end of file or cancel.
    func askSecret(_ prompt: String) -> String?
}

extension SetupConsole {
    /// A console with no way to hide input (a test script, a pipe) reads the secret as an ordinary line.
    func askSecret(_ prompt: String) -> String? {
        ask(prompt)
    }
}

/// Reads from the real terminal with `readLine()`.
struct RealSetupConsole: SetupConsole {
    func ask(_ prompt: String) -> String? {
        print(prompt, terminator: "")
        return readLine()
    }

    /// `readpassphrase` with echo off: the terminal never shows the token and it never reaches the output.
    func askSecret(_ prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        defer { buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        guard readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF) != nil else { return nil }
        return String(cString: buffer)
    }
}
