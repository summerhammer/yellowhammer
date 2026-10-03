import ArgumentParser
import Foundation

/// The one place the format of a line `yh` itself writes while running an Act lives. `launchd` appends
/// an Act's stdout and stderr to `~/Library/Logs/Yellowhammer/<project>.<act>.log`, and a bare line there
/// cannot be dated afterwards, so each starts with an ISO-8601 UTC timestamp (seconds) and a space.
/// Only the Act commands (`author`, `build`, `land`) use it: other subcommands' output is parsed
/// line by line by the app.
enum ActLog {
    /// `2026-10-03T07:15:56Z text`.
    static func line(_ text: String, at date: Date) -> String {
        "\(date.formatted(Date.ISO8601FormatStyle())) \(text)"
    }

    /// Writes `line(text, at:)` and a newline to standard error.
    static func writeToStandardError(_ text: String, at date: Date = Date()) {
        FileHandle.standardError.write(Data((line(text, at: date) + "\n").utf8))
    }

    /// Runs `body`; on failure writes `<timestamp> Error: <message>` through `write`, then throws an
    /// `ExitCode` carrying the code ArgumentParser would have exited with, so it exits without printing
    /// the error a second time. The message is ArgumentParser's own `fullMessage(for:)`. A clean exit
    /// (`ExitCode.success`, `CleanExit`) passes through untouched.
    static func reportingFailure<Command: ParsableArguments>(
        of command: Command.Type,
        now: () -> Date = { Date() },
        write: (String, Date) -> Void = { writeToStandardError($0, at: $1) },
        body: () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch {
            let code = command.exitCode(for: error)
            guard code != .success else { throw error }
            let message = command.fullMessage(for: error)
            // `fullMessage(for:)` already starts with ArgumentParser's own `Error: ` token.
            if !message.isEmpty { write(message, now()) }
            throw code
        }
    }
}
