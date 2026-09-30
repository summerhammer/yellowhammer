import Config
import Domain
import SwiftUI

/// What the main area states when it has no Pulse to show. It is never a blank, and never an arbitrary
/// fallback Project (scope-windows-to-a-project, AC 3 and AC 5).
struct OverviewUnavailable: View {
    enum Reason {
        /// The machine-wide configuration file could not be read, so no Project could be.
        case configurationUnreadable(String)
        /// No Project is configured on this Mac.
        case noProject
        /// A deep link named an id that no Project file has.
        case unknownProject(ProjectID)
        /// A deep link named a Project whose file was refused at load.
        case refusedProject(ProjectID, InvalidProject)
    }

    let reason: Reason

    var body: some View {
        VStack(spacing: 8) {
            switch reason {
            case let .configurationUnreadable(failure):
                Text("Yellowhammer can\u{2019}t read its configuration.")
                UnavailableDetail(text: failure)
                SetupButton()
            case .noProject:
                Text("No Project is configured.")
                SetupButton()
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

/// Opens the Setup wizard's window until P18.17 replaces it with the Add Project sheet.
private struct SetupButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Set Up Yellowhammer\u{2026}") { openWindow(id: "setup") }
            .accessibilityIdentifier("open-setup")
    }
}
