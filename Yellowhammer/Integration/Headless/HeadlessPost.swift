import AppKit
import Domain
import UserNotifications

/// A one-shot headless launch that posts one Exception Notification and exits
/// (morning-report/notify-the-operator-of-exceptions).
///
/// No window, no Dock icon, nothing resident: the process lives only as long as the post, and a
/// watchdog ends it if Notification Center never answers. Fire-and-forget — it never requests
/// permission (that happens once, at setup), never retries, and records nothing; the exit status is
/// the only thing it reports.
final class HeadlessPost: NSObject, NSApplicationDelegate {
    /// How long the process may live before it exits regardless.
    private static let deadline: Duration = .seconds(10)

    private let notification: ExceptionNotification

    private init(notification: ExceptionNotification) {
        self.notification = notification
    }

    static func run(_ notification: ExceptionNotification) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = HeadlessPost(notification: notification)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
        exit(EX_SOFTWARE)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            try? await Task.sleep(for: Self.deadline)
            FileHandle.standardError.write(Data("Yellowhammer: notification post timed out\n".utf8))
            exit(EX_TEMPFAIL)
        }
        Task {
            exit(await post())
        }
    }

    private func post() async -> Int32 {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            FileHandle.standardError.write(Data("Yellowhammer: notifications are not authorized\n".utf8))
            return EX_NOPERM
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        // Time Sensitive where the Operator allows it; without the entitlement or with the setting
        // revoked, macOS delivers it as an ordinary notification — volume degrades, never correctness.
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
            return EXIT_SUCCESS
        } catch {
            FileHandle.standardError.write(Data("Yellowhammer: notification post failed: \(error)\n".utf8))
            return EX_UNAVAILABLE
        }
    }
}
