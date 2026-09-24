import AppKit
import Foundation

/// A one-shot headless launch that registers local notification permission and exits, run once at
/// setup (`yh setup`) and never again (OQ9, OQ13).
///
/// No window, no Dock icon, nothing resident — same shape as ``HeadlessPost``. The activation policy is
/// `.accessory` rather than `.prohibited`: the system permission prompt must be able to appear while no
/// window opens, and `.prohibited` can prevent that prompt from showing at all.
final class HeadlessPermissionRequest: NSObject, NSApplicationDelegate {
    /// How long the process waits for a human to answer the prompt before it exits regardless.
    private static let deadline: Duration = .seconds(120)

    static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = HeadlessPermissionRequest()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
        exit(EX_SOFTWARE)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            try? await Task.sleep(for: Self.deadline)
            FileHandle.standardError.write(
                Data("Yellowhammer: the notification permission prompt was not answered\n".utf8)
            )
            exit(EX_TEMPFAIL)
        }
        Task {
            exit(await request())
        }
    }

    private func request() async -> Int32 {
        guard await NotificationPermission.requestAtSetup() else {
            FileHandle.standardError.write(Data("Yellowhammer: notifications are not authorized\n".utf8))
            return EX_NOPERM
        }
        return EXIT_SUCCESS
    }
}
