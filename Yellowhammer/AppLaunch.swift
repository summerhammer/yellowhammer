import Domain
import Foundation
import SwiftUI

/// Chooses, before any scene exists, between the window app and a headless notification post.
///
/// `yh` launches the app with `ExceptionNotification.postFlag` to post one local notification under
/// the app's bundle identity; that launch must never open a window, so it cannot go through the
/// SwiftUI `App` at all.
@main
enum AppLaunch {
    static func main() {
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
