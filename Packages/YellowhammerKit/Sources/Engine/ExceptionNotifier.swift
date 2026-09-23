import Domain
import Foundation
import Subprocess
import System

/// Posts an ``ExceptionNotification`` locally, once, fire-and-forget
/// (morning-report/notify-the-operator-of-exceptions, Decision Gates Ruling G-10). The injectable
/// seam: every `EngineInvocation` and `ActCommand` carries one and calls `post`. Dispatch failure is
/// the caller's problem to catch and record — this type never retries and never blocks an Act.
public struct ExceptionNotifier: Sendable {
    private let posting: @Sendable (ExceptionNotification) async throws -> Void

    public init(post: @escaping @Sendable (ExceptionNotification) async throws -> Void) {
        self.posting = post
    }

    public func post(_ notification: ExceptionNotification) async throws {
        try await posting(notification)
    }

    /// Posts nothing: the default on every `EngineInvocation` and `ActCommand`, so a test that does
    /// not opt into notifications spawns no process.
    public static let silent = ExceptionNotifier { _ in }

    /// The real launcher: a one-shot, headless launch of `Yellowhammer.app` by bundle identifier
    /// (`open -b`), the command the spec's ruling names. `open -b` is used instead of running the
    /// app's binary directly because a local notification's identity comes from the bundle macOS
    /// resolves for it — the same identity `UNUserNotificationCenter` requires — and nothing about
    /// this is resident: the app launches headless (`--post-notification`), posts, and exits, and this
    /// call returns only once it has.
    ///
    /// `-n` is mandatory, not cosmetic: without it, `open -b` on an already-running window app
    /// re-activates that window instead of passing `--args` to a new headless launch, and `-W` then
    /// blocks until the Operator quits it — a notification would silently never post while the app
    /// happens to be open. `-g` keeps the launch in the background so it never steals focus. `-W`
    /// blocks `open` until the launched app exits, which is what lets this call observe an outcome at
    /// all — but `open`'s own exit status only reports whether the *launch* succeeded (e.g. an unknown
    /// bundle id); the app's own outcome is read back from `--stderr <file>`, the file `HeadlessPost`
    /// (the app side) writes a `Yellowhammer:`-prefixed line to on failure only.
    public static func headlessApp(
        bundleIdentifier: String = "dev.yellowhammer",
        openPath: String = "/usr/bin/open",
        timeout: Duration = .seconds(20)
    ) -> ExceptionNotifier {
        ExceptionNotifier { notification in
            try await HeadlessLaunch.post(
                notification, bundleIdentifier: bundleIdentifier, openPath: openPath, timeout: timeout
            )
        }
    }
}

/// Why a headless post did not go through. Every case's ``description`` is a single plain line, used
/// as-is for the Journal's `notificationDeliveryFailed` reason.
public enum HeadlessPostError: Error, Equatable, CustomStringConvertible {
    /// `open` itself did not succeed — most often an unresolvable bundle id.
    case launchFailed(status: String, output: String)
    /// `open` launched the app, but the app's own stderr named a failure (e.g. notifications denied).
    case postFailed(String)
    /// The launch did not finish within the notifier's timeout; the child is torn down.
    case timedOut(Duration)
    /// `open` could not be spawned at all.
    case notLaunched(String)

    public var description: String {
        switch self {
        case .launchFailed(let status, let output):
            output.isEmpty ? "open \(status)" : "open \(status): \(output)"
        case .postFailed(let reason):
            reason
        case .timedOut(let duration):
            "the headless launch did not finish within \(duration)"
        case .notLaunched(let reason):
            "open could not be launched: \(reason)"
        }
    }
}

/// The one-shot headless launch itself, split out so `ExceptionNotifier.headlessApp` stays a plain
/// factory.
private enum HeadlessLaunch {
    private enum Outcome {
        case posted
        case timedOut
    }

    static func post(
        _ notification: ExceptionNotification, bundleIdentifier: String, openPath: String, timeout: Duration
    ) async throws {
        let stderrFile = FileManager.default.temporaryDirectory
            .appending(component: "yh-notify-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stderrFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: stderrFile) }

        let arguments = ["-W", "-n", "-g", "-b", bundleIdentifier, "--stderr", stderrFile.path, "--args"]
            + notification.arguments

        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                try await runOpen(openPath: openPath, arguments: arguments, stderrFile: stderrFile)
                return .posted
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
    /// but the app's stderr file non-empty means the app ran and reported a failure to post.
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
