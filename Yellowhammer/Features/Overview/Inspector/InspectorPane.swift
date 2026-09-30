import Domain
import Pulse
import SwiftUI

/// The frame every Inspector pane shares: a scrolling body under a caption, and the one way out pinned
/// below. Read-only: the way out opens Linear or GitHub, where a triage gesture is made.
struct InspectorPane<Content: View>: View {
    let kind: LocalizedStringResource
    let wayOut: (title: LocalizedStringResource, destination: PulseDestination)?
    let note: LocalizedStringResource?
    let identifier: String
    @ViewBuilder let content: Content
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(kind)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            if let wayOut {
                VStack(spacing: 6) {
                    Button { openDestination(wayOut.destination) } label: {
                        Label(String(localized: wayOut.title), systemImage: "arrow.up.forward.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("\(identifier)-way-out")
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .background(.bar)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// A label over a value, for the facts an Inspector pane lists.
struct InspectorFact: View {
    let label: LocalizedStringResource
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A Repo Lane's member Cards. A Card the Pulse lists under Needs you opens its Card detail; any other
/// is listed as a row, because the Inspector has no detail to open for it.
struct LaneCardList: View {
    let cards: [LaneCard]
    let decisionCardIDs: Set<String>
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(cards) { card in
                HStack(spacing: 6) {
                    if decisionCardIDs.contains(card.id) {
                        Button("\(card.id)  \(card.title)") { openDestination(.inspector(.card(card.id))) }
                            .buttonStyle(.link)
                    } else {
                        Text("\(card.id)  \(card.title)")
                    }
                    Spacer(minLength: 4)
                    PulseCountBadge(text: card.state.rawValue, tint: card.state.tint)
                }
                .lineLimit(1)
                .accessibilityIdentifier("lane-card-\(card.id)")
            }
        }
    }
}

private extension CardState {
    var tint: Color {
        switch self {
        case .blocked: .red
        case .waitingOnYou: .orange
        case .done: .purple
        case .inProgress: .green
        default: .secondary
        }
    }
}

extension PullRequestChip {
    /// `#42 open`, or just `#42` while the pull request's own state is unknown (it lives in GitHub).
    var label: String {
        ["#\(number)", state?.rawValue].compactMap { $0 }.joined(separator: " ")
    }
}
