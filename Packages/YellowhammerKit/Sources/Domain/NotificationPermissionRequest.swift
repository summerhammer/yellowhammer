/// The launch contract between `yh setup` and the app for registering local notification permission
/// (OQ9, OQ13): the app registers for `dev.yellowhammer` in a one-shot headless launch, because
/// permission belongs to the app's bundle identity, not to `yh`. This is how setup asks for it.
public enum NotificationPermissionRequest {
    /// The flag that switches the app into the headless permission-request mode.
    public static let flag = "--request-notification-permission"
}
