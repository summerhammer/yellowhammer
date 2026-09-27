import Foundation
import Subprocess
import System

/// A one-shot, headless launch of `Yellowhammer.app` by bundle identifier (`open -b`), for any launch
/// contract the app and `yh` share (Exception Notifications, the notification-permission request at
/// setup). `open -b` is used instead of running the app's binary directly because the launch needs the
/// same identity macOS resolves for the app's bundle, and nothing about this is resident: the app
/// launches headless, does its one-shot work, and exits, and this call returns only once it has.
///
/// `-n` is mandatory, not cosmetic: without it, `open -b` on an already-running window app re-activates
/// that window instead of passing `--args` to a new headless launch, and `-W` then blocks until the
/// Operator quits it — the launch would silently never run while the app happens to be open. `-g` keeps
/// the launch in the background so it never steals focus. `-W` blocks `open` until the launched app
/// exits, which is what lets this call observe an outcome at all — but `open`'s own exit status only
/// reports whether the *launch* succeeded (e.g. an unknown bundle id); the app's own outcome is read
/// back from `--stderr <file>`, the file the app side writes a `Yellowhammer:`-prefixed line to on
/// failure only.
public enum HeadlessAppLaunch {
    /// The `.app` bundle this executable is embedded in (`<bundle>.app/Contents/MacOS/<exe>`), or
    /// `nil` outside one. An installed `yh` launches its own enclosing app by path (`open -a`) instead
    /// of by bundle identifier: `open -b` takes whichever registered copy LaunchServices picks, and any
    /// stale build left on the machine (a scratch or DerivedData `Yellowhammer.app`) is a candidate.
    public static func enclosingAppPath(executable: URL? = Bundle.main.executableURL) -> String? {
        guard let executable else { return nil }
        let macOS = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app" else { return nil }
        return bundle.path
    }

    private enum Outcome {
        case finished
        case timedOut
    }

    public static func run(
        arguments: [String],
        bundleIdentifier: String = "dev.yellowhammer",
        appPath: String? = enclosingAppPath(),
        openPath: String = "/usr/bin/open",
        timeout: Duration
    ) async throws {
        let stderrFile = FileManager.default.temporaryDirectory
            .appending(component: "yh-headless-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stderrFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: stderrFile) }

        let target = appPath.map { ["-a", $0] } ?? ["-b", bundleIdentifier]
        let openArguments = ["-W", "-n", "-g"] + target + ["--stderr", stderrFile.path, "--args"] + arguments

        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                try await runOpen(openPath: openPath, arguments: openArguments, stderrFile: stderrFile)
                return .finished
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return }
            if case .timedOut = first {
                throw HeadlessPostError.timedOut(timeout)
            }
        }
    }

    /// Runs `open`, then interprets its own exit status and the app's redirected stderr per the
    /// contract measured on this machine: `open` non-zero means the launch itself failed; `open` zero
    /// but the app's stderr file non-empty means the app ran and reported a failure.
    private static func runOpen(openPath: String, arguments: [String], stderrFile: URL) async throws {
        var platformOptions = PlatformOptions()
        // Mirrors `WorktreeCheck`: cancellation (the timeout race above losing) sends SIGTERM, then
        // SIGKILL after 3 s if `open` ignores it.
        platformOptions.teardownSequence = [.send(signal: .terminate, allowedDurationToNextStep: .seconds(3))]
        let result: ExecutionResult<Void, StringOutput<UTF8>, CombinedErrorOutput>
        do {
            result = try await Subprocess.run(
                .path(FilePath(openPath)),
                arguments: Arguments(arguments),
                platformOptions: platformOptions,
                output: .string(limit: 4096),
                error: .combinedWithOutput
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw HeadlessPostError.notLaunched("\(error)")
        }
        if Task.isCancelled { throw CancellationError() }
        switch result.terminationStatus {
        case .exited(let code) where code == 0:
            break
        case .exited(let code):
            throw HeadlessPostError.launchFailed(
                status: "exited with status \(code)", output: trimmed(result.standardOutput)
            )
        case .signaled(let signal):
            throw HeadlessPostError.launchFailed(
                status: "terminated by signal \(signal)", output: trimmed(result.standardOutput)
            )
        }
        let appOutput = trimmed((try? String(contentsOf: stderrFile, encoding: .utf8)) ?? "")
        guard appOutput.isEmpty else {
            throw HeadlessPostError.postFailed(appOutput)
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
