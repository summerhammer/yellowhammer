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
    @Environment(\.openPulseDestination) private var openDestination

    init(project: ProjectID, card: DecisionCard, asOf: Date) {
        self.card = card
        self.asOf = asOf
        _model = State(initialValue: CardDetailModel(project: project, issueID: card.id))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardDetailHeader(card: card, waitingReason: detail?.waitingReason)
                account
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .safeAreaInset(edge: .bottom) { wayOut }
        .task(id: asOf) { await model.load() }
    }

    private var detail: CardDetail? {
        if case let .detail(detail) = model.read { detail } else { nil }
    }

    @ViewBuilder private var account: some View {
        switch model.read {
        case nil:
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("card-detail-loading")
        case let .detail(detail):
            CardDetailAccount(detail: detail)
        case .noSuchCard:
            Text("The Journal no longer records this Card.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("card-detail-no-such-card")
        case .journalMissing:
            Text("This Project has no Journal.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("card-detail-journal-missing")
        case let .journalFailure(failure):
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

    /// The one way out: the Card's Linear issue, which carries re-ready and answer.
    private var wayOut: some View {
        VStack(spacing: 6) {
            Button { openDestination(.linearIssue(card.id)) } label: {
                Label("Open \(card.id) in Linear", systemImage: "arrow.up.forward.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("card-detail-open-linear")
            Text("Re-ready and answer happen on the Linear issue, never here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.bar)
    }
}

/// The Card's title and issue id, then its state with the reason beside it: the Block Reason of a
/// Blocked Card, or the `waiting_reason` of a Waiting on You Card once the account is read.
private struct CardDetailHeader: View {
    let card: DecisionCard
    let waitingReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CARD")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(card.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("card-detail-title")
            if card.title != card.id {
                Text(card.id)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                PulseCountBadge(text: card.state.rawValue, tint: tint)
                if let reason = card.blockReason?.rawValue ?? waitingReason {
                    PulseCountBadge(text: reason, tint: tint)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("card-detail-state")
        }
        .textSelection(.enabled)
    }

    private var tint: Color { card.state == .blocked ? .red : .orange }
}
