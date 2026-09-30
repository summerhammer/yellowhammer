import Pulse
import SwiftUI

/// The Inspector: the detail of the current selection, beside the Pulse. This is a placeholder until
/// P18.8 (Card detail) and P18.9 (Feature, Attempt and Repo detail) build each pane. It names the
/// selection and offers its way out.
///
/// It shows a selection only while that selection names something in `project`, so the Inspector never
/// shows another Project's Card, Attempt or Repo beside this Project's Pulse (R20). Its ways out open
/// Linear or GitHub, where the gesture is made. The Inspector itself never makes a triage gesture.
struct InspectorView: View {
    let project: ProjectSnapshot
    let selection: PulseSelection?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        if let selection, project.contains(selection) {
            VStack(alignment: .leading, spacing: 12) {
                Text(selection.title(in: project))
                    .font(.headline)
                    .accessibilityIdentifier("inspector-selection")
                if let wayOut = selection.wayOut(in: project) {
                    Button(wayOut.title) { openDestination(wayOut.destination) }
                        .buttonStyle(.link)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "sidebar.trailing",
                description: Text("Select a Card, the Feature, an Attempt or a Repo.")
            )
        }
    }
}

// MARK: For display

private extension PulseSelection {
    func title(in project: ProjectSnapshot) -> LocalizedStringResource {
        switch self {
        case let .card(id): "Card \(id)"
        case let .feature(id): "Feature \(id)"
        case let .attempt(id): "Attempt on \(project.runningAttempt(id: id)?.cardID ?? id)"
        case let .repo(repo): "Repo \(repo)"
        }
    }

    /// The way out the Inspector offers for this selection: its label and where it goes. Nil when the
    /// selection has none (a Repo without a pull request, or an Attempt no longer running).
    func wayOut(in project: ProjectSnapshot) -> (title: LocalizedStringResource, destination: PulseDestination)? {
        switch self {
        case let .card(id), let .feature(id):
            return ("Open \(id) in Linear", .linearIssue(id))
        case let .attempt(id):
            return project.runningAttempt(id: id).map { ("Open \($0.cardID) in Linear", .linearIssue($0.cardID)) }
        case let .repo(repo):
            let lane = project.pulse.feature?.lanes.first { $0.repo == repo }
            return lane?.pullRequest.map {
                ("Open #\($0.number) on GitHub", .pullRequest(repo: repo, number: $0.number))
            }
        }
    }
}
