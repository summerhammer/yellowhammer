import Pulse
import SwiftUI

/// The Inspector's Night facts: when the Night opened and closed, why, how many Act runs it had and how
/// many entries were a problem. The Night's Journal events are not here: they are the main area's, laid
/// along a playhead (`NightAccountView`).
struct NightDetailFacts: View {
    let account: NightAccount

    var body: some View {
        Section("Details") {
            NightFact(label: "Opened", value: account.openedAt.formatted(date: .abbreviated, time: .standard))
            NightFact(
                label: "Closed",
                value: account.completedAt?.formatted(date: .abbreviated, time: .standard) ?? "not closed"
            )
            if let reason = account.closeReason {
                NightFact(label: "Close reason", value: reason)
            }
            NightFact(label: "Act runs", value: "\(account.runs.count)")
            NightFact(label: "Problems", value: "\(account.problemCount)", identifier: "night-detail-problem-count")
        }
    }
}

/// A labelled value, one form row. The identifier goes on the value, so a test reads the value alone.
private struct NightFact: View {
    let label: LocalizedStringKey
    let value: String
    var identifier: String?

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier ?? "")
        }
    }
}
