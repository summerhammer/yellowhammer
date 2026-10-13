import Domain
import Pulse
import SwiftUI

/// The Inspector's Night: the Night from the Pulse, and the facts its own Project's Journal recorded for it
/// (OQ158 ruling item 14). The Night's Journal events are the main area's, laid along a playhead
/// (`NightAccountView`); this pane carries the Night's header, its facts and its way out. Journal events
/// only, never agent output (item 16).
///
/// Read-only. Nothing here triages: its one way out opens the Night Card in Linear, where the decision is
/// made.
///
/// The header comes from the Pulse snapshot the Night was opened from, so it shows at once. The account is
/// read by `model`, which the main area reads through too and re-reads each time the snapshot is; this pane
/// only shows what the model has read.
struct NightDetailView: View {
    let night: NightPulse
    let model: NightDetailModel

    var body: some View {
        InspectorPane(
            kind: "Night",
            systemImage: "moon.stars.fill",
            style: night.state.style,
            title: title,
            titleIdentifier: "night-detail-title",
            wayOut: night.nightCard.map { ("Open \($0.identifier) in Linear", .nightCard($0.url)) },
            note: "The Night\u{2019}s account, as this Project\u{2019}s Journal recorded it. Triage happens in Linear.",
            identifier: "night-detail",
            wayOutIdentifier: "night-detail-open-linear"
        ) {
            Group {
                PulseCountBadge(text: night.state.rawValue, style: night.state.style)
                if account?.mode == .rehearsal {
                    PulseCountBadge(text: "rehearsal", style: .secondary)
                }
            }
            .accessibilityIdentifier("night-detail-state")
        } content: {
            content
        }
    }

    private var account: NightAccount? {
        if case let .account(account) = model.read { account } else { nil }
    }

    /// The Night's `NightStart` once the account is read; until then the date it opened.
    private var title: String {
        "Night of \(account?.nightStart ?? night.startedAt.formatted(date: .numeric, time: .omitted))"
    }

    @ViewBuilder private var content: some View {
        switch model.read {
        case nil:
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("night-detail-loading")
            }
        case let .account(account):
            NightDetailFacts(account: account)
        case .noSuchNight:
            Section {
                Text("The Journal no longer records this Night.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("night-detail-no-such-night")
            }
        case .journalMissing:
            Section {
                Text("This Project has no Journal.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("night-detail-journal-missing")
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
                .accessibilityIdentifier("night-detail-failure")
            }
        }
    }
}
