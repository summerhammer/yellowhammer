import Config
import SwiftUI

/// The run's screen: that setup is running, or how it ended, then the log of `yh setup --init`.
struct WizardRunView: View {
    let model: SetupWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            outcome
            if let line = model.notificationStatusLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup-notification-status")
            }
            ScrollView {
                Text(model.runLines.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityIdentifier("setup-run-log")
            }
            .background(.surface, in: .rect(cornerRadius: 8))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var outcome: some View {
        switch model.runExitStatus {
        case nil:
            ProgressView("Adding \(model.draft.displayName)…")
                .accessibilityIdentifier("setup-running")
        case 0?:
            Label("\(model.draft.displayName) is added", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.success)
                .accessibilityIdentifier("setup-success")
            if let failure = model.boundsFailure {
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure).foregroundStyle(.error)
                    Text("The Project is added with the default Bounds. Change them in Settings \u{2192} Recalibrate.")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("setup-bounds-failure")
            }
        case .some:
            Label("Setup failed", systemImage: "xmark.octagon.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.error)
                .accessibilityIdentifier("setup-failure")
            Text("The log below explains it. The Project file may already be written; Settings lists it.")
                .foregroundStyle(.secondary)
        }
    }
}
