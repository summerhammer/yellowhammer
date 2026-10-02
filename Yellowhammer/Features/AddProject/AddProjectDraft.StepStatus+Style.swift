import Config
import SwiftUI

extension AddProjectDraft.StepStatus {
    /// Done is `success`, a problem is `error`, the current step is `accent`, and the rest are `neutral`:
    /// the roles the Pulse gives the same states. Colour is never the only signal, so every mark pairs it
    /// with `systemImage`.
    var style: some ShapeStyle {
        let style: ThemeShapeStyle<Color> = switch self {
        case .done: .success
        case .problem: .error
        case .current: .accent
        case .upcoming: .neutral
        }
        return style
    }

    var systemImage: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        case .current: "circle.inset.filled"
        case .upcoming: "circle"
        }
    }
}
