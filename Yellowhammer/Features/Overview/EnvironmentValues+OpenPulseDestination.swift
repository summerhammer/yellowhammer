import Domain
import Pulse
import SwiftUI

/// Opens a Pulse element's destination, as the window routes it. A view calls it like a function:
/// `openDestination(.settings)`.
///
/// It is `Equatable` so that the environment can tell when it has really changed. A bare closure never
/// compares equal, so every update of the window would invalidate every view that reads it. Two actions
/// are equal when they were built for the same `scope`, whatever their closures. That is safe only
/// while the closure captures nothing by value except `scope`: bindings and reference-typed actions
/// read the current state when they are called, but a captured value is frozen when the closure is
/// built, and a view that skipped re-evaluation would keep routing with the stale one. Any other value
/// the closure captures must be added to `==`.
struct OpenPulseDestinationAction: Equatable {
    /// The Project the window was scoped to when `open` was built. It is the one value `open` captures.
    private let scope: ProjectID?
    private let open: @MainActor (PulseDestination) -> Void

    init(scope: ProjectID?, _ open: @escaping @MainActor (PulseDestination) -> Void) {
        self.scope = scope
        self.open = open
    }

    @MainActor func callAsFunction(_ destination: PulseDestination) {
        open(destination)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope
    }
}

extension EnvironmentValues {
    /// Opens a Pulse element's destination. A landing-screen view calls this instead of opening
    /// anything itself, so the shipped screen can route it. A no-op where no window installs it.
    @Entry var openPulseDestination = OpenPulseDestinationAction(scope: nil) { _ in }
}
