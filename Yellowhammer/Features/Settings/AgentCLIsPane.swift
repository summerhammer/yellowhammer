import AppKit
import Domain
import Ledger
import SwiftUI

/// The Agent CLIs pane of the Settings window's General section (P14.4, P18.15). Not Project-scoped: the
/// declared CLI Adapters and the Ledger are both machine-wide, so one Probe run serves every Project.
/// Lists each declared CLI with its latest Probe Result and lets the Operator run a Probe on demand, and
/// declares a registered CLI Adapter not yet declared (#281). The route it needs is given in the base
/// Routing Table pane, which this pane points to while no route names a declared CLI. On a fresh Mac, with no
/// `config.toml` yet, declaring the first CLI creates it: nothing here waits on the Add Project sheet.
struct AgentCLIsPane: View {
    @State private var model = AgentCLIModel()

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.reloadIfIdle()
            }
    }

    @ViewBuilder private var content: some View {
        if let failure = model.loadFailure {
            unavailable(message: failure)
                .accessibilityIdentifier("agent-cli-load-failure")
        } else if let rows = model.rows {
            AgentCLIListView(model: model, rows: rows)
        } else {
            unavailable(message: "Agent CLIs could not be loaded.")
        }
    }

    private func unavailable(message: String) -> some View {
        SettingsUnavailable(message: message)
    }
}

/// The list of declared CLIs plus the Probe log, split out so it only ever runs with a non-nil row
/// array.
private struct AgentCLIListView: View {
    @Bindable var model: AgentCLIModel
    let rows: [AgentCLIModel.CLIRow]

    @Environment(\.showSettingsSection) private var showSettingsSection
    @State private var selectedName: String
    @State private var executable = ""

    init(model: AgentCLIModel, rows: [AgentCLIModel.CLIRow]) {
        self.model = model
        self.rows = rows
        // Starts on an offered name, so the Picker never holds a selection none of its tags match.
        _selectedName = State(initialValue: model.declarableNames.first ?? "")
    }

    var body: some View {
        SettingsPane(
            title: "Agent CLIs",
            explanation: "The agent CLIs this Mac can dispatch to. A Probe checks that one works as its CLI "
                + "Adapter expects; one Probe run serves every Project."
        ) {
            WizardBlock(title: "Declared agent CLIs", boxed: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if rows.isEmpty {
                        Text("No agent CLI is declared yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        AgentCLIRowView(model: model, row: row)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("agent-cli-row-\(row.name)")
                    }
                }
            }
            if !rows.isEmpty && !model.hasRoute {
                noRouteNotice
            }
            if !model.probeLog.isEmpty || model.probeExitStatus != nil {
                probeLogBlock
            }
            if !model.declarableNames.isEmpty {
                declareBlock
            }
        }
    }

    private var noRouteNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.warning)
                .accessibilityHidden(true)
            Text("No base route names a declared agent CLI yet.")
                .accessibilityIdentifier("agent-cli-no-route")
            Spacer()
            Button("Open Base Routing Table") { showSettingsSection(.baseRoutingTable) }
                .accessibilityIdentifier("agent-cli-open-routing-table")
        }
        .padding(12)
        .background(.warning.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private var declareBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            WizardBlock(
                title: "Declare an agent CLI",
                footer: "Scheduled runs get a minimal PATH, so an absolute path is how yh finds the CLI "
                    + "unattended; blank means yh looks it up on PATH."
            ) {
                WizardBlockRow(label: "Agent CLI") {
                    Picker("Agent CLI", selection: $selectedName) {
                        ForEach(model.declarableNames, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("agent-cli-declare-name")
                }
                Divider().padding(.leading, 12)
                WizardBlockRow(label: "Executable", detail: "Optional") {
                    TextField("Executable (optional)", text: $executable, prompt: Text("Looked up on PATH"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 300)
                        .accessibilityIdentifier("agent-cli-declare-executable")
                }
            }
            if let failure = model.declareFailure {
                SettingsFailureText(text: failure, identifier: "agent-cli-declare-failure")
            }
            HStack(spacing: 12) {
                Text(savingNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Declare") { model.declare(name: selectedName, executable: executable) }
                    .disabled(selectedName.isEmpty)
                    .accessibilityIdentifier("agent-cli-declare")
            }
        }
        .onAppear { resetSelection() }
        .onChange(of: model.declarableNames) { _, _ in
            executable = ""
            resetSelection()
        }
    }

    private var savingNote: String {
        let path = model.file.path(percentEncoded: false)
        if model.configMissing {
            return "Declaring creates \(path), the configuration this Mac's Projects share. "
                + "Editing the file directly stays supported."
        }
        return "Saving rewrites \(path); comments and layout in it are not kept. "
            + "Editing the file directly stays supported."
    }

    /// Keeps the selection on an offered name: the first remaining one when the current is gone.
    private func resetSelection() {
        if !model.declarableNames.contains(selectedName) {
            selectedName = model.declarableNames.first ?? ""
        }
    }

    /// The last Probe's output as `yh probe` printed it, like the Add Project sheet's run log.
    private var probeLogBlock: some View {
        WizardBlock(title: "Probe log", boxed: false) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(model.probeLog.joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .accessibilityIdentifier("agent-cli-probe-log")
                }
                .frame(maxHeight: 200)
                .background(.surface, in: .rect(cornerRadius: 8))
                if let status = model.probeExitStatus, status != 0 {
                    SettingsFailureText(text: "yh probe exited \(status).", identifier: "agent-cli-probe-exit-status")
                }
            }
        }
    }
}

/// One declared CLI's card: its Ledger-derived state, plus a Probe button.
private struct AgentCLIRowView: View {
    @Bindable var model: AgentCLIModel
    let row: AgentCLIModel.CLIRow

    var body: some View {
        SettingsCard {
            HStack(spacing: 8) {
                Text(row.name)
                    .font(.headline.monospaced())
                Spacer()
                if model.runningCLI == row.name {
                    ProgressView().controlSize(.small)
                }
                Button("Probe") { Task { await model.probe(cli: row.name) } }
                    .disabled(model.isProbing)
                    .accessibilityIdentifier("agent-cli-probe-\(row.name)")
            }
            if let ledgerFailure = row.ledgerFailure {
                SettingsFailureText(text: ledgerFailure)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        fieldLabel("Probed")
                        Text(probedAtText)
                            .accessibilityIdentifier("agent-cli-probed-at-\(row.name)")
                    }
                    if let latest = row.latest {
                        value("CLI version", latest.cliVersion)
                        value("Adapter version", latest.adapterVersion)
                        findings(for: latest)
                        value("Verdict", latest.verdict.rawValue)
                        if let reason = latest.reason {
                            value("Reason", reason)
                        }
                    }
                }
                if let drift = row.drift {
                    Label(driftText(drift), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.warning)
                        .textSelection(.enabled)
                }
                eligibility
            }
        }
    }

    @ViewBuilder private var eligibility: some View {
        let isOffered = if case .offered = row.eligibility { true } else { false }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isOffered ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(isOffered ? AnyShapeStyle(.success) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text(eligibilityText)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("agent-cli-eligibility-\(row.name)")
        }
        .font(.callout)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func value(_ label: String, _ value: String) -> some View {
        GridRow {
            fieldLabel(label)
            Text(value).textSelection(.enabled)
        }
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
        value("Unattended dispatch", latest.findingUnattendedDispatch.rawValue)
        value("Result file on clean exit", latest.findingResultFileOnCleanExit.rawValue)
        value("Process containment", latest.findingProcessContainment.rawValue)
        value("Session resumption", latest.findingSessionResumption.rawValue)
    }

    private func driftText(_ drift: ProbeDrift) -> String {
        let targets = drift.regressions.map(\.description).joined(separator: ", ")
        return "Drift since the previous probe "
            + "(\(drift.previousCLIVersion)/\(drift.previousAdapterVersion) \u{2192} "
            + "\(drift.currentCLIVersion)/\(drift.currentAdapterVersion)): \(targets)"
    }
}
