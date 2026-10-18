import Pulse
import SwiftUI

struct AuthoringDecisionRow: View {
    let decision: AuthoringDecision
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let link = decision.link {
                Button { openDestination(.linearIssue(link.url)) } label: {
                    Label(decision.title, systemImage: "exclamationmark.bubble.fill")
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                Text(link.identifier).font(.caption).foregroundStyle(.secondary)
            } else {
                Label(decision.title, systemImage: "exclamationmark.bubble.fill")
                Text("Linear link unavailable").font(.caption).foregroundStyle(.secondary)
            }
            Text(decision.kind.rawValue + " — Waiting on You")
                .font(.caption).foregroundStyle(.attention)
            Text(decision.reason).font(.callout).textSelection(.enabled)
            Text("Requires an Operator turn in Linear.").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("needs-you-authoring-\(decision.id)")
    }
}
