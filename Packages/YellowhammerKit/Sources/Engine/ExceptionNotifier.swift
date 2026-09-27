import Domain
import Foundation

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
    /// (`open -b`), the command the spec's ruling names — or, when `yh` runs inside an app bundle, of
    /// that enclosing app by path (`open -a`; see ``HeadlessAppLaunch/enclosingAppPath(executable:)``). `open -b` is used instead of running the
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
        appPath: String? = HeadlessAppLaunch.enclosingAppPath(),
        openPath: String = "/usr/bin/open",
        timeout: Duration = .seconds(20)
    ) -> ExceptionNotifier {
        ExceptionNotifier { notification in
            try await HeadlessAppLaunch.run(
                arguments: notification.arguments, bundleIdentifier: bundleIdentifier, appPath: appPath,
                openPath: openPath, timeout: timeout
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
