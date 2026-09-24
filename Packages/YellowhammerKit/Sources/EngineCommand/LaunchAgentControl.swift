import Darwin
import Foundation
import Subprocess
import System

/// `launchd`'s per-user control surface, the three calls `--install-jobs` needs. Tests inject a
/// recording fake; `SetupCommand.run` builds ``LaunchctlLaunchAgentControl``.
protocol LaunchAgentControl: Sendable {
    /// Unloads `label` from the user's `gui` domain. A failure (typically: not currently loaded) is
    /// never an error worth reporting — the caller ignores it.
    func bootout(label: String) async throws
    /// Marks `label` enabled in the user's `gui` domain, so `bootstrap` does not refuse it.
    func enable(label: String) async throws
    /// Loads the LaunchAgent at `plistURL` into the user's `gui` domain.
    func bootstrap(plistURL: URL) async throws
}

/// A `launchctl` failure: the command's own combined stdout/stderr, so the Operator sees what
/// `launchctl` actually said.
struct LaunchctlError: Error, CustomStringConvertible {
    let description: String
}

/// Runs `/bin/launchctl` against the user's `gui/<uid>` domain via `Subprocess`.
struct LaunchctlLaunchAgentControl: LaunchAgentControl {
    let launchctlPath: String
    let uid: UInt32

    init(launchctlPath: String = "/bin/launchctl", uid: UInt32 = UInt32(getuid())) {
        self.launchctlPath = launchctlPath
        self.uid = uid
    }

    func bootout(label: String) async throws {
        try await run(["bootout", "gui/\(uid)/\(label)"])
    }

    func enable(label: String) async throws {
        try await run(["enable", "gui/\(uid)/\(label)"])
    }

    func bootstrap(plistURL: URL) async throws {
        try await run(["bootstrap", "gui/\(uid)", plistURL.path(percentEncoded: false)])
    }

    private func run(_ arguments: [String]) async throws {
        let result: ExecutionResult<Void, StringOutput<UTF8>, CombinedErrorOutput>
        do {
            result = try await Subprocess.run(
                .path(FilePath(launchctlPath)), arguments: Arguments(arguments),
                output: .string(limit: 4096), error: .combinedWithOutput
            )
        } catch {
            throw LaunchctlError(description: "launchctl \(arguments.joined(separator: " ")): \(error)")
        }
        guard case .exited(0) = result.terminationStatus else {
            let combined = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchctlError(
                description: "launchctl \(arguments.joined(separator: " ")) \(result.terminationStatus): \(combined)"
            )
        }
    }
}
