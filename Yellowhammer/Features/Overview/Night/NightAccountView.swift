import Domain
import Pulse
import SwiftUI

/// The main area while a Night's account is open, in place of the Pulse: the Journal events its own
/// Project's Journal recorded for the Night, laid along a playhead the Operator moves (OQ158 ruling item
/// 14). Journal events only, never agent output (item 16).
///
/// Read-only. Nothing here triages: the Inspector beside it carries the Night's facts and its one way out,
/// to the Night Card in Linear, where the decision is made. Moving the playhead reads nothing: the account is
/// read once when the Night is opened and again each time the landing snapshot is (`asOf` changes), by the
/// model, which the Inspector reads too. Nothing here runs by itself, so the playhead moves only when the
/// Operator moves it.
///
/// The way back is a toolbar button that clears the Inspector's selection, which brings the Pulse back.
struct NightAccountView: View {
    let model: NightDetailModel
    /// The landing snapshot's instant. A new one means the snapshot was re-read, so the account is too.
    let asOf: Date
    /// Returns to the Pulse.
    let close: () -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: close) {
                        Label("Pulse", systemImage: "chevron.backward")
                    }
                    .help("Back to the Pulse")
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("night-account-close")
                }
            }
            .task(id: asOf) { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.read {
        case nil:
            ProgressView()
                .accessibilityIdentifier("night-account-loading")
        case let .account(account):
            NightEditor(account: account)
        case .noSuchNight:
            Text("The Journal no longer records this Night.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("night-account-no-such-night")
        case .journalMissing:
            Text("This Project has no Journal.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("night-account-journal-missing")
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
            .padding(20)
            .accessibilityIdentifier("night-account-failure")
        }
    }
}
