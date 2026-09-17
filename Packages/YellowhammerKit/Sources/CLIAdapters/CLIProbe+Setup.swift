import Foundation

/// The Worktree, hold script and nonce every probe run needs before any dispatch, plus the
/// separate `--version` probe (not a dispatch: no adapter, no schema, no session).
extension CLIProbe {
    /// Creates the Worktree, `git init`s it, and writes the hold script. Returns a fully-failed
    /// ``ProbeReport`` when any step fails (setup failures are reported honestly, not thrown).
    static func setUp(worktree: URL, adapter: some CLIAdapter, workDirectory: URL) -> ProbeReport? {
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
        guard runGitInit(in: worktree) else {
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

    static func runGitInit(in worktree: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init", "-q"]
        process.currentDirectoryURL = worktree
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Runs `<executable> --version`, capped at 10 s. The first non-empty stdout line, trimmed, or
    /// `"unknown"` if the process could not be spawned, timed out, or printed nothing parseable.
    static func probeVersion(executable: String, environment: [String: String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return "unknown"
        }

        let outputTask = Task { stdout.fileHandleForReading.readDataToEndOfFile() }
        let timedOut = await waitWithTimeout(process, timeout: .seconds(10))
        if timedOut, process.isRunning {
            process.terminate()
        }

        let data = await outputTask.value
        guard let text = String(data: data, encoding: .utf8) else { return "unknown" }
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return firstLine.isEmpty ? "unknown" : firstLine
    }

    private static func waitWithTimeout(_ process: Process, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { _ in continuation.resume(returning: false) }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return true
            }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }
    }
}
