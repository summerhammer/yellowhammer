import Domain
import Ledger
import SwiftUI

// One declared agent CLI as a card in two columns: the facts on the left, the four probe targets with what
// each means on the right. `yh probe` reports its findings only once it is over, so a Probe under way shows
// every target as still to come, over a bar, and fills them in when it ends.

/// One declared CLI's card: its Ledger-derived state, plus Probe and Remove buttons.
struct AgentCLICard: View {
    @Bindable var model: AgentCLIModel
    let row: AgentCLIModel.CLIRow
    @State private var confirmsRemoval = false

    private var isProbing: Bool { model.runningCLI == row.name }

    var body: some View {
        SettingsCard(isHighlighted: isProbing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.name)
                    .font(.headline.monospaced())
                Spacer()
                probeButton
                removeButton
            }
            if let failure = model.removeFailures[row.name] {
                SettingsFailureText(text: failure, identifier: "agent-cli-remove-failure-\(row.name)")
            }
            if let ledgerFailure = row.ledgerFailure {
                SettingsFailureText(text: ledgerFailure)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    facts.frame(width: 250, alignment: .leading)
                    Divider()
                    targets.frame(maxWidth: .infinity, alignment: .leading)
                }
                if isProbing {
                    progress
                } else {
                    if let drift = row.drift {
                        driftLine(drift)
                    }
                    if let reason = row.latest?.reason {
                        Text(reason)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove \(row.name)?", isPresented: $confirmsRemoval, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { model.remove(name: row.name) }
                .accessibilityIdentifier("agent-cli-remove-confirm-\(row.name)")
        } message: {
            Text(
                "Yellowhammer stops dispatching to \(row.name). Its declaration leaves config.toml; "
                    + "its Probe history stays. A Project whose routes name it refuses the removal."
            )
        }
    }

    // MARK: - Actions

    /// One Probe runs at a time, so every Probe button waits while any runs.
    private var probeButton: some View {
        Button(row.latest == nil ? "Probe Now" : "Probe Again") { Task { await model.probe(cli: row.name) } }
            .disabled(model.isProbing)
            .help(model.isProbing ? "One Probe runs at a time" : "Run yh probe \(row.name)")
            .accessibilityIdentifier("agent-cli-probe-\(row.name)")
    }

    /// The trash button the Repo cards use, confirming first. A routed CLI cannot be removed until the Base
    /// Routing Table stops naming it, and nothing is removed while a Probe runs.
    private var removeButton: some View {
        Button("Remove \(row.name)", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.isProbing || model.isRouted(row.name))
            .help(
                model.isRouted(row.name)
                    ? "A base route names \(row.name); change it in the Base Routing Table first."
                    : "Remove \(row.name) from config.toml"
            )
            .accessibilityIdentifier("agent-cli-remove-\(row.name)")
    }

    // MARK: - Facts

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                factLabel("Probed")
                Text(probedAtText)
                    .accessibilityIdentifier("agent-cli-probed-at-\(row.name)")
            }
            fact("CLI version", row.latest?.cliVersion ?? "\u{2014}")
            fact("Adapter", row.latest?.adapterVersion ?? "\u{2014}")
            if let executable = row.executable {
                fact("Executable", executable, monospaced: true)
            } else {
                GridRow {
                    factLabel("Executable")
                    Text("Looked up on PATH").foregroundStyle(.secondary)
                }
            }
            GridRow {
                factLabel("Routes")
                Text(eligibilityText)
                    .foregroundStyle(isOffered ? .primary : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent-cli-eligibility-\(row.name)")
            }
        }
        .font(.callout)
    }

    private func factLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func fact(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            factLabel(label)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }

    private var probedAtText: String {
        if isProbing { return "Probing now" }
        guard let latest = row.latest else { return "Never probed" }
        return latest.probedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var isOffered: Bool {
        if case .offered = row.eligibility { true } else { false }
    }

    private var eligibilityText: String {
        switch row.eligibility {
        case .offered: "Offered"
        case .excluded(let reason): "Not offered: \(reason)"
        case nil: "Unknown"
        }
    }

    // MARK: - Probe targets

    private var targets: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ProbeTarget.allCases, id: \.self) { target in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    FindingMark(finding: isProbing ? nil : row.latest?.finding(for: target))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.title + (target.gatesVerdict ? "" : " \u{00B7} recorded only"))
                        Text(target.meaning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Below the columns

    /// `yh probe` says nothing of its stages, so the bar cannot fill; its output streams into the Probe log.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Probing \(row.name)\u{2026}").fontWeight(.medium)
            ProgressView().progressViewStyle(.linear)
            Text("The findings fill in when the Probe ends; yh probe\u{2019}s output streams into the Probe log.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func driftLine(_ drift: ProbeDrift) -> some View {
        let targets = drift.regressions.map(\.title).formatted(.list(type: .and))
        let verb = drift.regressions.count == 1 ? "passes" : "pass"
        return Label {
            Text(
                "Drift since \(drift.previousCLIVersion) (adapter \(drift.previousAdapterVersion)): \(targets) "
                    + "no longer \(verb) under \(drift.currentCLIVersion) (adapter \(drift.currentAdapterVersion))."
            )
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.warning)
        }
        .font(.callout)
    }
}

/// A finding's mark: a filled check, a cross, a dash for not run, and an empty dashed circle while there is
/// no finding yet — never probed, or a Probe under way.
private struct FindingMark: View {
    let finding: ProbeFinding?

    var body: some View {
        Group {
            switch finding {
            case .passed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.success)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.error)
            case .notRun:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case nil:
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch finding {
        case .passed: "Passed"
        case .failed: "Failed"
        case .notRun: "Not run"
        case nil: "No finding yet"
        }
    }
}

private extension ProbeTarget {
    var title: String {
        switch self {
        case .unattendedDispatch: "Unattended dispatch"
        case .resultFileOnCleanExit: "Result file on clean exit"
        case .processContainment: "Process containment"
        case .sessionResumption: "Session resumption"
        }
    }

    /// What passing means, in a line.
    var meaning: String {
        switch self {
        case .unattendedDispatch: "Runs to the end with no sign-in or permission prompt"
        case .resultFileOnCleanExit: "Writes its schema-forced result file when it exits cleanly"
        case .processContainment: "Leaves nothing it spawned running after SIGTERM or SIGKILL"
        case .sessionResumption: "Resumes the same session for a new Round"
        }
    }

    /// Session resumption is recorded but never decides the verdict.
    var gatesVerdict: Bool { self != .sessionResumption }
}
