import SwiftUI

extension EnvironmentValues {
    /// Abort Attempt, as the window offers it. A Sidebar or Inspector view calls this instead of running
    /// anything itself. It is not a Pulse way out, so it is not a `PulseDestination`.
    @Entry var attemptAbort = AttemptAbortControl()
}
