import Domain
import Pulse
import SwiftUI

/// The Pulse's Needs you group: the Waiting on You count, the top Block Reasons as counts, a Feature
/// returned with unmet clauses, and every decision Card, Blocked or Waiting on You. A Card opens in the Inspector in one hop, never through
/// the Night Card; the decision itself stays in Linear.
struct NeedsYouGroup: View {
    let needsYou: NeedsYou
    /// What the Inspector shows, so the Card it names is marked.
    let inspected: PulseSelection?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        PulseCard(group: .needsYou, summary: PulseGroup.summary(of: needsYou)) {
            if needsYou.isEmpty {
                Label("Nothing needs you", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("needs-you-absence")
            } else {
                NeedsYouCounts(
                    waitingOnYouCount: needsYou.waitingOnYouCount,
                    blockReasonCounts: needsYou.blockReasonCounts
                )
                if let returned = needsYou.returnedFeature {
                    Button { openDestination(.inspector(.feature(returned.id))) } label: {
                        ReturnedFeatureRow(returned: returned)
                            .pulseRowHighlight(inspected == .feature(returned.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("needs-you-feature")
                    ReturnedFeatureGuidance()
                        .accessibilityIdentifier("needs-you-feature-guidance")
                }
                ForEach(needsYou.authoringDecisions) { decision in
                    AuthoringDecisionRow(decision: decision)
                }
                ForEach(needsYou.cards) { card in
                    Button { openDestination(.inspector(.card(card.id))) } label: {
                        DecisionCardRow(card: card)
                            .pulseRowHighlight(inspected == .card(card.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("needs-you-card-\(card.id)")
                }
            }
        }
        .accessibilityIdentifier("pulse-needs-you")
    }
}

/// The Waiting on You count and the top Block Reasons, as counts.
private struct NeedsYouCounts: View {
    let waitingOnYouCount: Int
    let blockReasonCounts: [(reason: BlockReason, count: Int)]

    /// How many Block Reasons the summary names before the Cards below it say the rest.
    private static let topReasons = 3

    var body: some View {
        HStack(spacing: 6) {
            if waitingOnYouCount > 0 {
                PulseCountBadge(text: "\(waitingOnYouCount) Waiting on You", style: .attention)
            }
            ForEach(blockReasonCounts.prefix(Self.topReasons), id: \.reason) { entry in
                PulseCountBadge(text: "\(entry.count) \(entry.reason.rawValue)", style: .error)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("needs-you-counts")
    }
}

/// The Feature the land Act returned to the Operator: it is in the same disposition as a Card waiting on them.
private struct ReturnedFeatureRow: View {
    let returned: ReturnedFeature

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.attention)
                .accessibilityHidden(true)
            Text(line).lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            PulseCountBadge(text: "returned", style: .attention)
        }
    }

    /// `Feature YLH-347 returned — 4 of 22 clauses unmet`; the tally is left out when none is recorded.
    private var line: String {
        let name = returned.issueIDForDisplay ?? returned.id
        guard let verification = returned.verification else { return "Feature \(name) returned" }
        return "Feature \(name) returned — \(verification.summary)"
    }
}

/// One decision Card, Blocked or Waiting on You.
private struct DecisionCardRow: View {
    let card: DecisionCard

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: card.state == .blocked ? "exclamationmark.octagon.fill" : "questionmark.bubble.fill")
                .foregroundStyle(card.state.style)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).lineLimit(1)
                Text("\(card.issueIDForDisplay ?? card.id) \u{00B7} \(card.repo)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PulseCountBadge(text: card.blockReason?.rawValue ?? card.state.rawValue, style: card.state.style)
        }
    }
}
