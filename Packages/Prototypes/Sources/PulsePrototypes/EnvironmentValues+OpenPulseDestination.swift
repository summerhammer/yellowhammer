#if DEBUG
import Pulse
import SwiftUI

extension EnvironmentValues {
    /// Opens a Pulse element's destination. The same name and shape as the app's own entry, so a
    /// variant stays portable to the shipped screen; the Playground records each call instead.
    @Entry var openPulseDestination: @MainActor (PulseDestination) -> Void = { _ in }
}
#endif
