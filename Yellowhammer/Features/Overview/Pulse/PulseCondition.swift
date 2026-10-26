import Domain
import Pulse
import SwiftUI

/// The one thing to know about the Project right now, loudest first: an unreadable Journal, Waiting on You,
/// then Blocked Cards, then a failed Act, Health flags and a starved Night, then working, then a running or
/// done Night, then idle. It is derived from the Project's own Pulse alone, never from a sibling's.
///
/// It decides nothing: it only says which group's card explains the status, and the Pulse's head jumps there.
struct PulseCondition {
    let title: String
    let line: String
    let symbol: String
    /// The status's colour role.
    let token: ThemeShapeStyle<Color>
    /// Two neighbouring colour roles, for the mist.
    let companions: (ThemeShapeStyle<Color>, ThemeShapeStyle<Color>)
    /// The group whose card explains the status; nil when there are no cards to jump to.
    let group: PulseGroup?
    /// Whether Yellowhammer is at work on the Project: an Act or an Attempt running, or a Night open.
    let isWorking: Bool

    // One branch per status, in loudness order; splitting it would hide the order.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    init(project: ProjectSnapshot) {
        let pulse = project.pulse
        let waiting = pulse.needsYou.waitingOnYouCount
        let blocked = pulse.needsYou.cards.count { $0.state == .blocked }
        let flags = pulse.health ?? []
        let isWorking = pulse.now.status == .working || pulse.night?.state == .running
        if project.journalFailure != nil {
            self.init(
                "Journal unreadable", "Yellowhammer can\u{2019}t read this Project\u{2019}s Journal",
                "exclamationmark.triangle.fill", .error, (.warning, .neutral), nil, isWorking: false
            )
        } else if waiting > 0 {
            let blockedPart = blocked > 0 ? " · \(blocked) Blocked" : ""
            self.init(
                "Needs you", "\(waiting) Waiting on You\(blockedPart)", "hand.raised.fill",
                .attention, (.error, .warning), .needsYou, isWorking: isWorking
            )
        } else if blocked > 0 {
            self.init(
                "Blocked", blocked == 1 ? "1 Card Blocked" : "\(blocked) Cards Blocked", "exclamationmark.octagon.fill",
                .error, (.attention, .info), .needsYou, isWorking: isWorking
            )
        } else if let failure = pulse.night?.firstFailureHeadline {
            self.init(
                "Act failed", failure, "xmark.octagon.fill", .error, (.warning, .info), .night, isWorking: isWorking
            )
        } else if !flags.isEmpty {
            self.init(
                "Health flagged", flags.count == 1 ? "1 flag from yh doctor" : "\(flags.count) flags from yh doctor",
                "stethoscope", .warning, (.attention, .accent), .health, isWorking: isWorking
            )
        } else if let night = pulse.night, night.state == .starved {
            self.init(
                "Night starved", night.verdictLine ?? "No Card was ready to work on", "moon.zzz.fill",
                .attention, (.info, .warning), .night, isWorking: isWorking
            )
        } else if pulse.now.status == .working {
            let attempts = pulse.now.attempts.count
            let line = switch attempts {
            case 0: pulse.now.runningAct.map { "\($0.act.rawValue) Act running" } ?? pulse.now.statusLine
            case 1: "1 Attempt running"
            default: "\(attempts) Attempts running"
            }
            self.init("Working", line, "gearshape.2.fill", .active, (.accent, .success), .now, isWorking: true)
        } else if let night = pulse.night, night.state == .running {
            self.init(
                "Night running", pulse.now.statusLine, "moon.stars.fill", .info, (.active, .accent), .now,
                isWorking: true
            )
        } else if let night = pulse.night, night.state == .done {
            let started = night.startedAt.formatted(date: .omitted, time: .shortened)
            self.init(
                "Night done", night.verdictLine ?? "Started \(started)", "checkmark.seal.fill",
                .info, (.success, .accent), .night, isWorking: false
            )
        } else {
            self.init("Idle", pulse.now.statusLine, "moon.fill", .neutral, (.info, .neutral), .now, isWorking: false)
        }
    }

    // A memberwise init in the order the branches above read.
    private init(
        _ title: String, _ line: String, _ symbol: String, _ token: ThemeShapeStyle<Color>,
        _ companions: (ThemeShapeStyle<Color>, ThemeShapeStyle<Color>), _ group: PulseGroup?, isWorking: Bool
    ) {
        self.title = title
        self.line = line
        self.symbol = symbol
        self.token = token
        self.companions = companions
        self.group = group
        self.isWorking = isWorking
    }
}
