import Foundation
import Subprocess
import System

/// The Worktree, hold script and nonce every probe run needs before any dispatch, plus the
/// separate `--version` probe (not a dispatch: no adapter, no schema, no session).
extension CLIProbe {
    /// Creates the Worktree, `git init`s it, and writes the hold script. Returns a fully-failed
    /// ``ProbeReport`` when any step fails (setup failures are reported honestly, not thrown).
    static func setUp(worktree: URL, adapter: some CLIAdapter, workDirectory: URL) async -> ProbeReport? {
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
