import Pulse
import SwiftUI

/// The Pulse's Feature group. This is a placeholder until P18.5 builds the group. It shows the in-flight
/// Feature and its Repo Lanes. The Feature and each Repo open in the Inspector, and each pull request
/// chip opens its pull request.
struct FeatureGroup: View {
    let feature: FeatureInFlight?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if let feature {
                    Button(feature.displayTitle) { openDestination(.inspector(.feature(feature.id))) }
                        .buttonStyle(.link)
                    ForEach(feature.lanes) { lane in
                        HStack {
                            Button(lane.repo) { openDestination(.inspector(.repo(lane.repo))) }
                                .buttonStyle(.link)
                            Text(lane.state.rawValue)
                                .foregroundStyle(.secondary)
                            if let pullRequest = lane.pullRequest {
                                Button("#\(pullRequest.number)") {
                                    openDestination(.pullRequest(repo: lane.repo, number: pullRequest.number))
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                } else {
                    Text("No Feature in flight")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Feature", systemImage: "flag")
        }
    }
}

// MARK: For display

private extension FeatureInFlight {
    /// The Feature's title, or its id while the title is not known.
    var displayTitle: String {
        title ?? id
    }
}
