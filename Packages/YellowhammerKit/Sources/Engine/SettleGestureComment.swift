import Domain
import Foundation

/// The comment the author Act posts on a Feature Issue it reads as *unsettled* (roadmap P10.9; spec:
/// morning-report/triage-the-morning), stating the settle gesture's consequence **before** the
/// Operator chooses — never after. Pure: no Journal or board access.
///
/// Posted once while the Feature is running and once more when it becomes a Partial Landing, because
/// the offered set can change between the two (only *abandoned* is offered once every Card is
/// Cancelled) — the author Act keys the Outbox write on the Cycle id and the offered set so each shape
/// posts exactly once.
public struct SettleGestureComment: Equatable, Sendable {
    /// What the settle gesture offers this pass, ascending by ``SettleValue/rawValue``.
    public let offered: [SettleValue]

    public init(offered: [SettleValue]) {
        self.offered = offered.sorted { $0.rawValue < $1.rawValue }
    }

    /// The comment body: what each offered value does, and what leaving the Feature unsettled does.
    /// Never implies abandoned work landed.
    public func body() -> String {
        var lines = [
            """
            **This Feature is in flight and unsettled.** Its next Night authors nothing until the \
            Operator settles it. What each choice below does — read before choosing:
            """,
            ""
        ]

        if offered.contains(.keptInFlight) {
            lines.append(
                "- **\(SettleValue.keptInFlight.rawValue)**: the Feature stays in flight, unchanged."
            )
        }
        if offered.contains(.abandoned) {
            lines.append(
                """
                - **\(SettleValue.abandoned.rawValue)**: frees this Project's in-flight slot and removes \
                this Feature from the predecessor-ancestry walk, so the next Night authors against \
                mainline as it stands, without this Feature's work. It lands nothing: it satisfies the \
                predecessor-ancestry gate for no repository, and is never counted in the merged fraction.
                """
            )
        }
        lines.append("")
        lines.append(
            "Left **unsettled**, neither of these happens: this Project's next Night authors nothing."
        )

        return lines.joined(separator: "\n")
    }
}
