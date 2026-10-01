import AppKit
import Domain
import Ledger
import SwiftUI

/// The Agent CLIs pane of the Settings window's General section (P14.4, P18.15). Not Project-scoped: the
/// declared CLI Adapters and the Ledger are both machine-wide, so one Probe run serves every Project.
/// Lists each declared CLI with its latest Probe Result and lets the Operator run a Probe on demand.
struct AgentCLIsPane: View {
    @State private var model = AgentCLIModel()
    @Environment(\.addProject) private var addProject

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.reloadIfIdle()
            }
    }

    @ViewBuilder private var content: some View {
        if model.configMissing {
            unavailable(
                message: "No agent CLI is declared: `config.toml` does not exist yet.",
                offerSetup: true
            )
        } else if let failure = model.loadFailure {
            unavailable(message: failure, offerSetup: false)
                .accessibilityIdentifier("agent-cli-load-failure")
        } else if let rows = model.rows {
            AgentCLIListView(model: model, rows: rows)
        } else {
            unavailable(message: "Agent CLIs could not be loaded.", offerSetup: false)
        }
    }

    private func unavailable(message: String, offerSetup: Bool) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if offerSetup {
                Button("Add a Project\u{2026}") { addProject() }
                    .accessibilityIdentifier("open-setup")
            }
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}

/// The list of declared CLIs plus the Probe log, split out so it only ever runs with a non-nil row
/// array.
private struct AgentCLIListView: View {
    @Bindable var model: AgentCLIModel
    let rows: [AgentCLIModel.CLIRow]

    var body: some View {
        VStack(spacing: 0) {
            List(rows) { row in
                AgentCLIRowView(model: model, row: row)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("agent-cli-row-\(row.name)")
            }
            if !model.probeLog.isEmpty || model.probeExitStatus != nil {
                Divider()
                probeLogView
            }
        }
    }

    private var probeLogView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(model.probeLog.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("agent-cli-probe-log")
            }
            .frame(maxHeight: 160)
            if let status = model.probeExitStatus, status != 0 {
                Text("yh probe exited \(status).")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("agent-cli-probe-exit-status")
            }
        }
        .padding()
    }
}

/// One declared CLI's row: its Ledger-derived state, plus a Probe button.
private struct AgentCLIRowView: View {
    @Bindable var model: AgentCLIModel
    let row: AgentCLIModel.CLIRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.name)
                    .font(.headline)
                Spacer()
                Button("Probe") { Task { await model.probe(cli: row.name) } }
                    .disabled(model.isProbing)
                    .accessibilityIdentifier("agent-cli-probe-\(row.name)")
            }
            if let ledgerFailure = row.ledgerFailure {
                Text(ledgerFailure)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                LabeledContent("Probed") {
                    Text(probedAtText)
                        .accessibilityIdentifier("agent-cli-probed-at-\(row.name)")
                }
                if let latest = row.latest {
                    LabeledContent("CLI version", value: latest.cliVersion)
                    LabeledContent("Adapter version", value: latest.adapterVersion)
                    findings(for: latest)
                    LabeledContent("Verdict", value: latest.verdict.rawValue)
                    if let reason = latest.reason {
                        LabeledContent("Reason", value: reason)
                    }
                    if let drift = row.drift {
                        Text(driftText(drift))
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                Text(eligibilityText)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("agent-cli-eligibility-\(row.name)")
            }
        }
        .padding(.vertical, 4)
    }

    private var probedAtText: String {
        guard let latest = row.latest else { return "Never probed" }
        return latest.probedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var eligibilityText: String {
        switch row.eligibility {
        case .offered:
            "offered as a route target"
        case .excluded(let reason):
            "not offered as a route target: \(reason)"
        case nil:
            "route target eligibility unknown"
        }
    }

    @ViewBuilder
    private func findings(for latest: ProbeResult) -> some View {
        LabeledContent("Unattended dispatch", value: latest.findingUnattendedDispatch.rawValue)
        LabeledContent("Result file on clean exit", value: latest.findingResultFileOnCleanExit.rawValue)
        LabeledContent("Process containment", value: latest.findingProcessContainment.rawValue)
        LabeledContent("Session resumption", value: latest.findingSessionResumption.rawValue)
    }

    private func driftText(_ drift: ProbeDrift) -> String {
        let targets = drift.regressions.map(\.description).joined(separator: ", ")
        return "Drift since the previous probe "
            + "(\(drift.previousCLIVersion)/\(drift.previousAdapterVersion) \u{2192} "
            + "\(drift.currentCLIVersion)/\(drift.currentAdapterVersion)): \(targets)"
    }
}
