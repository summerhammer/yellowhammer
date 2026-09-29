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
                Text(title(of: selection))
                    .font(.headline)
                    .accessibilityIdentifier("inspector-selection")
                if let wayOut = wayOut(of: selection) {
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

    private func title(of selection: PulseSelection) -> String {
        switch selection {
        case let .card(id): "Card \(id)"
        case let .feature(id): "Feature \(id)"
        case let .attempt(id): "Attempt on \(attempt(id)?.cardID ?? id)"
        case let .repo(repo): "Repo \(repo)"
        }
    }

    private func wayOut(of selection: PulseSelection) -> (title: String, destination: PulseDestination)? {
        switch selection {
        case let .card(id), let .feature(id):
            return ("Open \(id) in Linear", .linearIssue(id))
        case let .attempt(id):
            return attempt(id).map { ("Open \($0.cardID) in Linear", .linearIssue($0.cardID)) }
        case let .repo(repo):
            let lane = project.pulse.feature?.lanes.first { $0.repo == repo }
            return lane?.pullRequest.map {
                ("Open #\($0.number) on GitHub", .pullRequest(repo: repo, number: $0.number))
            }
        }
    }

    private func attempt(_ id: String) -> RunningAttempt? {
        project.pulse.now.attempts.first { $0.id == id }
    }
}
