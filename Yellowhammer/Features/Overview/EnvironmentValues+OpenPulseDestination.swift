import Pulse
import SwiftUI

extension EnvironmentValues {
    /// Opens a Pulse element's destination. A landing-screen view calls this instead of opening
    /// anything itself, so the prototype harness can record each way out and the shipped screen can
    /// route it.
    @Entry var openPulseDestination: @MainActor (PulseDestination) -> Void = { _ in }
}
