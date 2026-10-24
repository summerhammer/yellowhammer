import Domain
import Pulse
import SwiftUI

/// The Inspector: the detail of the current selection, beside the Pulse. A Card opens its Card detail,
/// read from this Project's own Journal. The Night opens its facts and its way out to the Night Card (OQ158
/// ruling item 14), from the same read as the Night's account in the main area, which takes the Pulse's
/// place. The Feature, an Attempt and a Repo each open a pane rendered from the landing snapshot.
///
/// It shows a selection only while that selection names something in `project`, so the Inspector never
/// shows another Project's Card, Attempt or Repo beside this Project's Pulse (R20). Its ways out open
/// Linear or GitHub, where the gesture is made. The Inspector itself never makes a triage gesture.
struct InspectorView: View {
    let project: ProjectSnapshot
    let selection: PulseSelection?
    /// The landing snapshot's instant: a pane that reads beside the snapshot reads again when it changes.
    let asOf: Date
    /// The window's read of the Night the main area shows, when it shows one. The Night's pane renders only
    /// a model made for that Night of this Project.
    let nightAccount: NightDetailModel?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        if let selection, project.contains(selection) {
            pane(for: selection)
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "sidebar.trailing",
                description: Text("Select a Card, the Feature, an Attempt, a Repo or the Night.")
            )
        }
    }

    @ViewBuilder private func pane(for selection: PulseSelection) -> some View {
        let decisionCardIDs = Set(project.pulse.needsYou.cards.map(\.id))
        switch selection {
        case let .card(id):
            if let card = project.pulse.needsYou.cards.first(where: { $0.id == id }) {
                // One view, and one read, per Card of one Project: another Card, or the same issue id in
                // another Project, never reuses this one's account.
                CardDetailView(project: project.id, card: card, asOf: asOf)
                    .id(CardDetailIdentity(project: project.id, card: id))
            }
        case let .feature(id):
            // The in-flight Feature, else the member of the Unmerged Feature Stack the id names (proposed
            // amendment, yellowhammer-spec#132).
            if let feature = project.pulse.feature, feature.id == id {
                FeatureDetailView(feature: feature, decisionCardIDs: decisionCardIDs)
            } else if let awaiting = project.pulse.unmergedFeatures.features.first(where: { $0.id == id }) {
                AwaitingMergeFeatureDetailView(feature: awaiting)
            }
        case let .attempt(id):
            if let attempt = project.runningAttempt(id: id) {
                AttemptDetailView(project: project.id, attempt: attempt, asOf: asOf)
            }
        case let .repo(repo):
            RepoDetailView(
                repo: repo,
                lane: project.pulse.feature?.lanes.first { $0.repo == repo },
                attempt: project.runningAttempt(for: repo),
                decisionCardIDs: decisionCardIDs
            )
        case .night, .scheduledNight:
            nightPane(for: selection)
        }
    }

    @ViewBuilder private func nightPane(for selection: PulseSelection) -> some View {
        switch selection {
        case let .night(id):
            if let night = project.pulse.night, night.id == id,
               let nightAccount, nightAccount.project == project.id, nightAccount.nightID == id {
                NightDetailView(night: night, model: nightAccount)
            }
        case .scheduledNight:
            if let scheduled = project.pulse.scheduledNight {
                PendingNightDetailView(scheduled: scheduled)
            }
        default:
            EmptyView()
        }
    }
}

private struct CardDetailIdentity: Hashable {
    let project: ProjectID
    let card: String
}
