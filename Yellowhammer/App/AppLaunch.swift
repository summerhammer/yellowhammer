import Domain
import Foundation
import SwiftUI

/// Chooses, before any scene exists, between the window app and a headless launch.
///
/// `yh` launches the app with `ExceptionNotification.postFlag` to post one local notification, and
/// `yh setup` launches it with `NotificationPermissionRequest.flag` to register local notification
/// permission, both under the app's bundle identity; neither launch may open a window, so both are
/// chosen before the SwiftUI `App` runs at all.
@main
enum AppLaunch {
    static func main() {
        if CommandLine.arguments.contains(NotificationPermissionRequest.flag) {
            HeadlessPermissionRequest.run()
        }
        let notification: ExceptionNotification?
        do {
            notification = try ExceptionNotification(arguments: CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(Data("Yellowhammer: invalid notification post: \(error)\n".utf8))
            exit(EX_USAGE)
        }
        if let notification {
            HeadlessPost.run(notification)
        } else {
            YellowhammerApp.main()
        }
    }
}
