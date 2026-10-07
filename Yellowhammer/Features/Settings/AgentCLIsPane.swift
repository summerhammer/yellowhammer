import AppKit
import SwiftUI

/// The Agent CLIs pane of the Settings window (P14.4, P18.15). Not Project-scoped: the
/// declared CLI Adapters and the Ledger are both machine-wide, so one Probe run serves every Project.
/// Lists each declared CLI with its latest Probe Result and lets the Operator run a Probe on demand, and
/// declares a registered CLI Adapter not yet declared (#281) or removes a declared one. The route it needs is given in the base
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
            if rows.isEmpty {
                noCLIsState
            }
            ForEach(rows) { row in
                AgentCLICard(model: model, row: row)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("agent-cli-row-\(row.name)")
            }
            if !rows.isEmpty && !model.hasRoute {
                noRouteNotice
            }
            if !model.probeLog.isEmpty || model.probeExitStatus != nil {
                probeLogBlock
            }
            AgentCLIDiscoverySection(model: model)
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

    /// What the pane shows with nothing declared: what that means, and the way forward below it.
    private var noCLIsState: some View {
        ContentUnavailableView {
            Label("No Agent CLIs", systemImage: "terminal")
        } description: {
            Text("No Card can be dispatched until an agent CLI is declared and passes its Probe.")
        }
        .frame(maxWidth: .infinity)
    }

    /// Declaring a registered CLI not yet declared, as a dashed card like the Repo list's placeholder, so it
    /// reads as the next item rather than a form.
    private var declareBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Declare").fontWeight(.medium)
                Picker("Agent CLI", selection: $selectedName) {
                    ForEach(model.declarableNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("agent-cli-declare-name")
                TextField("Executable (optional)", text: $executable, prompt: Text("Looked up on PATH"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("agent-cli-declare-executable")
                Spacer(minLength: 8)
                Button("Declare", systemImage: "plus") {
                    model.declare(name: selectedName, executable: executable)
                }
                .disabled(selectedName.isEmpty)
                .accessibilityIdentifier("agent-cli-declare")
            }
            Text(
                "Scheduled runs get a minimal PATH, so an absolute path is how yh finds the CLI unattended. "
                    + "Declaring does not probe. " + savingNote
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let failure = model.declareFailure {
                SettingsFailureText(text: failure, identifier: "agent-cli-declare-failure")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.neutral.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5]))
        )
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
