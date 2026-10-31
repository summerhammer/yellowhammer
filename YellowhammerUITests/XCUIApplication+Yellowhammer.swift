import Foundation
import XCTest

extension XCUIApplication {
    /// The app under test, launched against `configurationDirectory` with no restored windows.
    ///
    /// The command line tool link points at a path that does not exist inside that directory. A missing
    /// link reads as "not installed", so a local `/usr/local/bin/yh` that points at another build cannot
    /// raise the modal "Yellowhammer moved" alert over the window and swallow every click.
    static func yellowhammer(configurationDirectory: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-YellowhammerConfigurationDirectory", configurationDirectory.path(percentEncoded: false),
            "-ApplePersistenceIgnoreState", "YES",
            "-YellowhammerCommandLineToolLink",
            configurationDirectory.appending(component: "no-yh", directoryHint: .notDirectory)
                .path(percentEncoded: false)
        ]
        return app
    }
}
