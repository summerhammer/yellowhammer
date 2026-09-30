import UserNotifications

/// The local notification permission, asked for at setup and never again
/// (system-overview → Notification behaviour).
///
/// macOS shows the permission prompt only while the status is undetermined, so asking on every setup
/// cannot nag. A refusal is stated once, plainly, and is never treated as a fault: the Night Card in
/// Linear still carries every event.
enum NotificationPermission {
    /// Requests permission if the Operator has not decided yet, and reports whether local
    /// notifications will post.
    static func requestAtSetup() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }
}
