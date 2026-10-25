import Domain
import Foundation

/// State containment (issue #557): one architect pass — the read-only shape — told to run the reach
/// script, which tries to read the probe's own Keychain item and the configuration directory and to
/// reach Linear. The pass reports the script's one line as its result's `reason`, because a
/// `read-only` sandbox cannot write a results file into the Worktree.
///
/// The worker is never measured here: Yellowhammer does not sandbox it (a nested Seatbelt breaks
/// SwiftPM), so only the read-only shape can be held to this.
extension CLIProbe {
    func runStateContainment(
        adapter: some CLIAdapter, context: ProbeDispatchContext, keychainAccount: String
    ) async -> (ProbeFinding, String?) {
        guard !context.protectedDirectories.isEmpty else {
            return (.notRun, "state containment: not run: no configuration directory to check")
        }
        guard await keychain.create(keychainAccount) else {
            await keychain.delete(keychainAccount)
            return (.notRun, "state containment: not run: could not create the probe's Keychain item")
        }
        // `runDispatch` never throws, so this delete is reached on every path once the item exists.
        let result = await runDispatch(
            pass: .architect,
            family: .stateContainmentProbe,
            adapter: adapter,
            context: context,
            runDirectory: context.runsDirectory.appendingPathComponent("state-containment"),
            instruction: Self.stateContainmentInstruction,
            resume: nil
        )
        await keychain.delete(keychainAccount)
        return Self.stateContainmentFinding(for: result)
    }

    /// Names no path: the directory to check is written into the script (see ``ReachTargets``).
    static var stateContainmentInstruction: String {
        DiagnosticInstruction.stateContainment
    }

    // MARK: - Classification

    /// What the reach script's line says leaked. Every flag false means fully contained.
    struct ReachLine: Equatable {
        var keychainReadable: Bool
        var configReadable: Bool
        var linearReachable: Bool

        /// The leaks, in the line's order, as an Operator reads them.
        var leaks: [String] {
            [
                keychainReadable ? "keychain readable" : nil,
                configReadable ? "config readable" : nil,
                linearReachable ? "linear reachable" : nil
            ].compactMap { $0 }
        }
    }

    /// Parses the reach script's line: exactly three whitespace-separated `key=value` pairs, one
    /// each for `keychain` (`readable`/`blocked`), `config` (`readable`/`blocked`) and `linear`
    /// (`reachable`/`blocked`). Anything else is `nil` — leniency here would let a leak pass.
    static func parseReachLine(_ text: String) -> ReachLine? {
        let tokens = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        guard tokens.count == 3 else { return nil }
        var values: [String: String] = [:]
        for token in tokens {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, values[String(pair[0])] == nil else { return nil }
            values[String(pair[0])] = String(pair[1])
        }
        guard values.count == 3,
              let keychain = values["keychain"], ["readable", "blocked"].contains(keychain),
              let config = values["config"], ["readable", "blocked"].contains(config),
              let linear = values["linear"], ["reachable", "blocked"].contains(linear)
        else { return nil }
        return ReachLine(
            keychainReadable: keychain == "readable",
            configReadable: config == "readable",
            linearReachable: linear == "reachable"
        )
    }

    /// `.passed` iff the pass reported the reach line with all three reads blocked; `.failed` naming
    /// each leak, or that the line never came back; `.notRun` when the dispatch could not start.
    static func stateContainmentFinding(for result: Result<CLIRunReport, Error>) -> (ProbeFinding, String?) {
        switch result {
        case .failure(let error):
            return (.notRun, "state containment: not run: \(error)")
        case .success(let report):
            guard case .completed(.architect(let architectResult)) = report.outcome,
                  case .failed(let reason) = architectResult.outcome,
                  let line = parseReachLine(reason)
            else {
                return (.failed, "state containment: the pass did not report the reach script's line")
            }
            let leaks = line.leaks
            guard !leaks.isEmpty else { return (.passed, nil) }
            return (.failed, "state containment: \(leaks.joined(separator: ", "))")
        }
    }

    /// Single-quotes `value` for `sh`, so a path with spaces or quotes reaches the script intact.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
