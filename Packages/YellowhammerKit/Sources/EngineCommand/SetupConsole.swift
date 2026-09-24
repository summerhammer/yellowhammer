import Darwin
import Foundation

/// Interactive `yh setup`'s prompts. Never called in `--init` or `--config` mode.
protocol SetupConsole: Sendable {
    /// Prints `prompt` with no trailing newline, then reads one line. `nil` means end of file.
    func ask(_ prompt: String) -> String?
    /// Like ``ask(_:)``, but does not echo the answer when standard input is a terminal.
    func askSecret(_ prompt: String) -> String?
}

/// Reads from the real terminal: `readLine()` for ordinary prompts, `readpassphrase(3)` with
/// `RPP_ECHO_OFF` for secrets — falling back to `readLine()` when standard input is not a TTY, since
/// `readpassphrase` requires one.
struct RealSetupConsole: SetupConsole {
    func ask(_ prompt: String) -> String? {
        print(prompt, terminator: "")
        return readLine()
    }

    func askSecret(_ prompt: String) -> String? {
        guard isatty(fileno(stdin)) != 0 else {
            return ask(prompt)
        }
        var buffer = [CChar](repeating: 0, count: 1024)
        defer { for index in buffer.indices { buffer[index] = 0 } }
        guard readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF) != nil else { return nil }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<length].map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }
}
