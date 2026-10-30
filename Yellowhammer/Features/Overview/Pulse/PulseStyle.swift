import Domain
import Pulse
import SwiftUI

// The theme token each state the Pulse and the Inspector show is drawn with, in one place. The roles
// follow the spec's anchor colours (`docs/brand/colors.md`): Needs you is `attention`, Blocked is
// `error`, working is `active`, Landed is `success`, Night is `info`, and idle is `neutral`. Selection
// and links keep the system accent, never the brand `accent`. Colour is never the only signal: every
// coloured mark sits beside its label. A style is opaque, so the token type stays in this file.

extension ProjectStatus {
    var style: some ShapeStyle {
        let style: ThemeShapeStyle<Color> = switch self {
        case .working: .active
        case .idle: .neutral
        }
        return style
    }
}

extension CardState {
    var style: some ShapeStyle {
        let style: ThemeShapeStyle<Color> = switch self {
        case .inProgress: .active
        case .done: .success
        case .blocked: .error
        case .waitingOnYou: .attention
        case .todo, .shelved: .neutral
        }
        return style
    }
}

extension LaneState {
    var style: some ShapeStyle {
        let style: ThemeShapeStyle<Color> = switch self {
        case .running: .active
        case .blocked: .error
        case .waitingOnYou: .attention
        case .landed: .success
        case .idle: .neutral
        }
        return style
    }
}

extension RollUpState {
    var style: some ShapeStyle {
        let style: ThemeShapeStyle<Color> = switch self {
        case .authoring: .neutral
        case .running: .active
        case .waiting, .partial: .attention
        case .blocked: .error
        case .verified: .success
        }
        return style
    }
}

extension NightPulseState {
    var style: some ShapeStyle {
        let style: ThemeShapeStyle<Color> = switch self {
        case .running: .active
        case .done: .info
        case .starved: .attention
        }
        return style
    }
}

extension NightAccount.RunOutcome {
    var style: some ShapeStyle { token }

    /// Never `warning`: that fills a run with a problem, which the timeline does separately.
    fileprivate var token: ThemeShapeStyle<Color> {
        switch self {
        case .ended: .success
        case .idle, .stoodDown: .neutral
        case .incomplete: .error
        case .notEnded: .info
        }
    }
}

extension NightMoment.ActState {
    /// The style of the run the time is in or after; `neutral` before the Act's first run.
    var style: some ShapeStyle {
        let style: ThemeShapeStyle<Color> = run?.outcome.token ?? .neutral
        return style
    }
}

extension ObservedPullRequestState {
    /// Closed without merge is `attention`, not `error`: the Operator closed it, and the standing line names it as
    /// something to act on.
    var style: some ShapeStyle {
        let style: ThemeShapeStyle<Color> = switch self {
        case .open: .active
        case .merged: .success
        case .closedWithoutMerge: .attention
        }
        return style
    }
}
