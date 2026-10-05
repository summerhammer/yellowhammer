import Domain
import Pulse
import SwiftUI

/// The Inspector's Card detail: a decision Card from the Pulse, and the account its own Project's
/// Journal recorded behind it — Attempts, Rounds, routes and Check output (P14.5, carried by P18.8).
///
/// Read-only. Nothing here re-readies, answers or triages a Card: its one way out opens the Card's Linear
/// issue, where those gestures are made (Pulse → Inspector → Linear).
///
/// The header comes from the Pulse snapshot the Card was opened from, so it shows at once; the account
/// is read beside it, and read again each time the snapshot is (`asOf` changes).
struct CardDetailView: View {
    let card: DecisionCard
    /// The landing snapshot's instant. A new one means the snapshot was re-read, so the account is too.
    let asOf: Date
    @State private var model: CardDetailModel

    init(project: ProjectID, card: DecisionCard, asOf: Date) {
        self.card = card
        self.asOf = asOf
        _model = State(initialValue: CardDetailModel(project: project, issueID: card.id))
    }

    var body: some View {
        InspectorPane(
            kind: "Card",
            systemImage: card.state == .blocked ? "exclamationmark.octagon.fill" : "questionmark.bubble.fill",
            style: card.state.style,
            title: card.title,
            subtitle: card.issueIDForDisplay ?? (card.link?.identifier ?? card.id),
            titleIdentifier: "card-detail-title",
            wayOut: card.link.map { ("Open \($0.identifier) in Linear", .linearIssue($0.url)) },
            note: "Re-ready and answer happen on the Linear issue, never here.",
            identifier: "card-detail",
            wayOutIdentifier: "card-detail-open-linear"
        ) {
            // The reason beside the state: the Block Reason of a Blocked Card, or the `waiting_reason` of
            // a Waiting on You Card once the account is read.
            Group {
                PulseCountBadge(text: card.state.rawValue, style: card.state.style)
                if let reason = card.blockReason?.rawValue ?? detail?.waitingReason {
                    PulseCountBadge(text: reason, style: card.state.style)
                }
            }
            .accessibilityIdentifier("card-detail-state")
        } content: {
            account
        }
        .task(id: asOf) { await model.load() }
    }

    private var detail: CardDetail? {
        if case let .detail(detail) = model.read { detail } else { nil }
    }

    @ViewBuilder private var account: some View {
        switch model.read {
        case nil:
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("card-detail-loading")
            }
        case let .detail(detail):
            CardDetailAccount(detail: detail)
        case .noSuchCard:
            Section {
                Text("The Journal no longer records this Card.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("card-detail-no-such-card")
            }
        case .journalMissing:
            Section {
                Text("This Project has no Journal.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("card-detail-journal-missing")
            }
        case let .journalFailure(failure):
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "Yellowhammer can\u{2019}t read this Project\u{2019}s Journal.",
                        systemImage: "exclamationmark.triangle"
                    )
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("card-detail-failure")
            }
        }
    }
}
