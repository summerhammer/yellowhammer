import Domain
import Pulse
import SwiftUI

/// The Inspector: the detail of the current selection, beside the Pulse. A Card opens its Card detail,
/// read from this Project's own Journal. The Feature, an Attempt and a Repo each open a pane rendered
/// from the landing snapshot.
///
/// It shows a selection only while that selection names something in `project`, so the Inspector never
/// shows another Project's Card, Attempt or Repo beside this Project's Pulse (R20). Its ways out open
/// Linear or GitHub, where the gesture is made. The Inspector itself never makes a triage gesture.
struct InspectorView: View {
    let project: ProjectSnapshot
    let selection: PulseSelection?
    /// The landing snapshot's instant: a pane that reads beside the snapshot reads again when it changes.
    let asOf: Date
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        if let selection, project.contains(selection) {
            pane(for: selection)
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "sidebar.trailing",
                description: Text("Select a Card, the Feature, an Attempt or a Repo.")
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
        case .feature:
            if let feature = project.pulse.feature {
                FeatureDetailView(feature: feature, decisionCardIDs: decisionCardIDs)
            }
        case let .attempt(id):
            if let attempt = project.runningAttempt(id: id) {
                AttemptDetailView(attempt: attempt, asOf: asOf)
            }
        case let .repo(repo):
            RepoDetailView(
                repo: repo,
                lane: project.pulse.feature?.lanes.first { $0.repo == repo },
                attempt: project.runningAttempt(for: repo),
                decisionCardIDs: decisionCardIDs
            )
        }
    }
}

private struct CardDetailIdentity: Hashable {
    let project: ProjectID
    let card: String
}
