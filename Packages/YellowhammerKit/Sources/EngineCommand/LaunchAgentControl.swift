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
    /// Whether `label` is currently loaded in the user's `gui` domain (`yh doctor`'s launchd check).
    func isLoaded(label: String) async -> Bool
}

/// A `launchctl` failure: the command's own combined stdout/stderr, so the Operator sees what
/// `launchctl` actually said.
struct LaunchctlError: Error, CustomStringConvertible {
    let description: String
}

/// One LaunchAgent's state as `launchctl print` reports it: the top-level (single-tab-indented)
/// `runs` and `last exit code` fields. `lastExitCode` is nil for `(never exited)` or when the field is
/// absent.
struct LaunchctlJobInfo: Equatable, Sendable {
    let runs: Int?
    let lastExitCode: Int?
}

/// The read-only `launchctl` seam `yh status` needs: a label's current state and whether it is
/// disabled. Kept separate from ``LaunchAgentControl`` — whose fakes only implement install/uninstall
/// calls — so this addition never breaks an existing test fake.
protocol LaunchAgentInspecting: Sendable {
    /// This label's current state under `launchctl print gui/<uid>/<label>`, or nil when it fails
    /// (typically: not currently loaded).
    func jobInfo(label: String) async -> LaunchctlJobInfo?
    /// Every label `launchctl print-disabled gui/<uid>` reports as disabled.
    func disabledLabels() async -> Set<String>
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

    func isLoaded(label: String) async -> Bool {
        (try? await run(["print", "gui/\(uid)/\(label)"])) != nil
    }

    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
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
        return result.standardOutput
    }
}

extension LaunchctlLaunchAgentControl: LaunchAgentInspecting {
    func jobInfo(label: String) async -> LaunchctlJobInfo? {
        guard let output = try? await run(["print", "gui/\(uid)/\(label)"]) else { return nil }
        return Self.parseJobInfo(output)
    }

    func disabledLabels() async -> Set<String> {
        guard let output = try? await run(["print-disabled", "gui/\(uid)"]) else { return [] }
        return Self.parseDisabledLabels(output)
    }

    /// Reads the first, top-level (single-tab-indented) `runs =` and `last exit code =` lines of a
    /// `launchctl print` dump. Anything more deeply indented (a nested dictionary or array) is not a
    /// top-level field and is ignored.
    static func parseJobInfo(_ text: String) -> LaunchctlJobInfo {
        var runs: Int?
        var lastExitCode: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let field = line.dropFirst()
            guard let separator = field.range(of: " = ") else { continue }
            let key = field[field.startIndex..<separator.lowerBound]
            let value = field[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            if key == "runs", runs == nil {
                runs = Int(value)
            } else if key == "last exit code", lastExitCode == nil, value != "(never exited)" {
                lastExitCode = Int(value)
            }
        }
        return LaunchctlJobInfo(runs: runs, lastExitCode: lastExitCode)
    }

    /// Reads every `\t\t"<label>" => disabled` (or `=> true`, older macOS) line of a
    /// `launchctl print-disabled` dump. `=> enabled`/`=> false` is not disabled.
    static func parseDisabledLabels(_ text: String) -> Set<String> {
        var labels = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("\t\t\"") else { continue }
            let afterQuote = line.dropFirst(3)
            guard let closingQuote = afterQuote.firstIndex(of: "\"") else { continue }
            let label = afterQuote[afterQuote.startIndex..<closingQuote]
            let rest = afterQuote[afterQuote.index(after: closingQuote)...]
            guard rest.contains("=> disabled") || rest.contains("=> true") else { continue }
            labels.insert(String(label))
        }
        return labels
    }
}
