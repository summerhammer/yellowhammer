import Foundation
import Subprocess
import System

/// The Worktree, hold and reach scripts and nonce every probe run needs before any dispatch, plus
/// the separate `--version` probe (not a dispatch: no adapter, no schema, no session).
extension CLIProbe {
    /// Creates the Worktree, `git init`s it, and writes the hold and reach scripts. Returns a
    /// fully-failed ``ProbeReport`` when any step fails (setup failures are reported honestly, not
    /// thrown). No Keychain item exists yet at this point: it is created only around the reach dispatch.
    static func setUp(
        worktree: URL, adapter: some CLIAdapter, workDirectory: URL, reachTargets: ReachTargets
    ) async -> ProbeReport? {
        let fileManager = FileManager.default

        func failEverything(_ reason: String) -> ProbeReport {
            ProbeReport(
                cli: adapter.cli,
                adapterVersion: adapter.adapterVersion,
                cliVersion: "unknown",
                unattendedDispatch: .failed,
                resultFileOnCleanExit: .failed,
                processContainment: .failed,
                sessionResumption: .notRun,
                stateContainment: .notRun,
                reason: reason,
                workDirectory: workDirectory
            )
        }

        do {
            try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        } catch {
            return failEverything("setup failed: could not create the Worktree: \(error)")
        }
        guard await runGitInit(in: worktree) else {
            return failEverything("setup failed: `git init -q` did not succeed in \(worktree.path)")
        }

        let holdScript = worktree.appendingPathComponent("yh-probe-hold.sh")
        do {
            try holdScriptContents.write(to: holdScript, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: holdScript.path)
        } catch {
            return failEverything("setup failed: could not write the hold script: \(error)")
        }

        let reachScript = worktree.appendingPathComponent(reachScriptName)
        do {
            try reachScriptContents(reachTargets).write(to: reachScript, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reachScript.path)
        } catch {
            return failEverything("setup failed: could not write the reach script: \(error)")
        }

        return nil
    }

    static func makeNonce() -> String {
        let hexDigits = Array("0123456789abcdef")
        return "yh-probe-" + (0..<12).map { _ in String(hexDigits.randomElement()!) }.joined()
    }

    static let holdScriptContents = """
        #!/bin/sh
        variant="$1"
        mkdir -p .yh-probe
        echo $$ >> .yh-probe/holds-"$variant"
        sleep 900 &
        echo $! >> .yh-probe/holds-"$variant"
        wait
        """

    static let reachScriptName = "yh-probe-reach.sh"

    /// What the reach script tries to read: the probe's own Keychain item and the configuration
    /// directory. Both are written into the script, not passed on its command line: a codex pass that
    /// sees a path its permissions profile denies in the command refuses to run it at all (measured
    /// with codex-cli 0.163.0), which would hide whether the sandbox holds.
    struct ReachTargets {
        let keychainAccount: String
        /// Empty when the probe has no protected directories; the script then reports it blocked.
        let configurationDirectory: String
    }

    /// Tries the three reads a read-only pass must not manage — the probe's own Keychain item, the
    /// configuration directory and Linear's API — and prints exactly one line, e.g.
    /// `keychain=blocked config=blocked linear=blocked`. Any HTTP status from Linear, even an error,
    /// means it was reachable; only a curl failure counts as blocked. Absolute tool paths, because a
    /// launchd `PATH` is minimal.
    static func reachScriptContents(_ targets: ReachTargets) -> String {
        """
        #!/bin/sh
        config_dir=\(shellQuoted(targets.configurationDirectory))
        service="\(ProbeKeychain.service)"
        account="\(targets.keychainAccount)"
        secret=$(/usr/bin/security find-generic-password -s "$service" -a "$account" -w 2>/dev/null)
        if [ "$secret" = "$account" ]; then keychain=readable; else keychain=blocked; fi
        if [ -n "$config_dir" ] && ls "$config_dir" >/dev/null 2>&1; then
            config=readable
        else
            config=blocked
        fi
        if /usr/bin/curl -sS -m 10 -o /dev/null https://api.linear.app/graphql >/dev/null 2>&1; then
            linear=reachable
        else
            linear=blocked
        fi
        printf 'keychain=%s config=%s linear=%s\\n' "$keychain" "$config" "$linear"

        """
    }

    static func runGitInit(in worktree: URL) async -> Bool {
        do {
            let result = try await Subprocess.run(
                .path(FilePath("/usr/bin/env")),
                arguments: ["git", "init", "-q"],
                workingDirectory: FilePath(worktree.path),
                output: .discarded,
                error: .discarded
            )
            return result.terminationStatus == .exited(0)
        } catch {
            return false
        }
    }

    /// Runs `<executable> --version`, capped at 10 s. The first non-empty stdout line, trimmed, or
    /// `"unknown"` if the process could not be spawned, timed out, or printed nothing parseable.
    static func probeVersion(executable: String, environment: [String: String]) async -> String {
        let fullEnvironment = Environment.custom(
            Dictionary(uniqueKeysWithValues: environment.map { (Environment.Key(stringLiteral: $0.key), $0.value) })
        )
        let output: [UInt8]? = await withTaskGroup(of: [UInt8]?.self) { group in
            group.addTask {
                let result = try? await Subprocess.run(
                    .path(FilePath(executable)),
                    arguments: ["--version"],
                    environment: fullEnvironment,
                    output: .bytes(limit: 64 * 1024),
                    error: .discarded
                )
                return result?.standardOutput
            }
            group.addTask {
                // Losing the race cancels the run above, which tears the child down.
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first.flatMap { $0 }
        }
        guard let output, let text = String(validating: output, as: UTF8.self) else { return "unknown" }
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return firstLine.isEmpty ? "unknown" : firstLine
    }
}
