import Config
import Domain
import Pulse
import SwiftUI

/// What the main area states when it has no Pulse to show. It is never a blank, and never an arbitrary
/// fallback Project (scope-windows-to-a-project, AC 3 and AC 5).
struct OverviewUnavailable: View {
    enum Reason {
        /// The machine-wide configuration file could not be read, so no Project could be.
        case configurationUnreadable(String)
        /// No Project is configured on this Mac, including one where Setup has never run: the onboarding
        /// view.
        case noProject
        /// A deep link named an id that no Project file has.
        case unknownProject(ProjectID)
        /// A deep link named a Project whose file was refused at load.
        case refusedProject(ProjectID, InvalidProject)
    }

    let reason: Reason
    @Environment(\.addProject) private var addProject
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        VStack(spacing: 8) {
            switch reason {
            case let .configurationUnreadable(failure):
                Text("Yellowhammer can\u{2019}t read its configuration.")
                UnavailableDetail(text: failure)
                Button("Open Settings\u{2026}") { openDestination(.settings) }
                    .accessibilityIdentifier("open-settings")
            case .noProject:
                Text("No Project is configured.")
                    .accessibilityIdentifier("overview-onboarding")
                UnavailableDetail(text: "Add a Project to start.")
                Button("Add a Project\u{2026}") { addProject() }
                    .accessibilityIdentifier("open-setup")
            case let .unknownProject(id):
                Text("No configured Project has the id \u{201C}\(id.rawValue)\u{201D}.")
                    .accessibilityIdentifier("overview-unknown-id")
            case let .refusedProject(id, refusal):
                Text("The configuration of \u{201C}\(id.rawValue)\u{201D} was refused.")
                    .accessibilityIdentifier("overview-refused-id")
                UnavailableDetail(text: refusal.file)
                ForEach(Array(refusal.errors.enumerated()), id: \.offset) { _, error in
                    UnavailableDetail(text: error.description)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A line of detail under the statement: a failure, a file, or one of its errors.
private struct UnavailableDetail: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
