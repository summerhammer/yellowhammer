#if DEBUG
import SwiftUI

// Two Agent CLIs variants that keep the app's card per CLI and spend its width better.
//
// - A · Checklist: the facts fold into one line under the name, the four findings sit in a 2 × 2 grid, and
//   a Probe under way swaps the findings for its stage checklist.
// - B · Two columns: the facts on the left, the four probe targets with what each means on the right; a
//   Probe under way fills the targets in live as their stages end, over a bar in words.

// MARK: - A · Checklist

struct AgentCLIChecklistVariant: View {
    let bench: AgentCLIBench

    var body: some View {
        SettingsColumn(spacing: 12) {
            if bench.clis.isEmpty { NoCLIsState() }
            ForEach(bench.clis) { cli in ChecklistCard(bench: bench, cli: cli) }
            AgentCLIPaneFooter(bench: bench)
        }
    }
}

private struct ChecklistCard: View {
    let bench: AgentCLIBench
    let cli: DeclaredCLI

    var body: some View {
        RoutingCard(highlighted: bench.run?.cli == cli.name) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cli.name).font(.headline.monospaced())
                CLIStatusBadge(bench: bench, cli: cli)
                Spacer()
                ProbeButton(bench: bench, cli: cli)
                RemoveCLIButton(bench: bench, cli: cli)
            }
            Text(facts).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if let run = bench.run, run.cli == cli.name {
                Divider()
                ProbeStageList(run: run, showsDetail: true)
                ProbeProgressSummary(run: run, showsDetail: false).padding(.top, 4)
            } else {
                findings
                if let reason = cli.latest?.reason {
                    Text(reason).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                DriftLine(cli: cli).font(.callout)
                EligibilityLine(cli: cli).font(.callout)
                if let last = bench.lastRun, last.cli == cli.name, last.wasStopped {
                    Text("The last Probe was stopped after \(last.elapsedText); nothing was recorded.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var facts: String {
        guard let latest = cli.latest else { return "Never probed \u{00B7} \(cli.executableText)" }
        return [latest.cliVersion, "adapter \(latest.adapterVersion)", "probed \(latest.probedAtText)"]
            .joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private var findings: some View {
        if cli.latest != nil {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    finding(.unattendedDispatch)
                    finding(.resultFileOnCleanExit)
                }
                GridRow {
                    finding(.processContainment)
                    finding(.sessionResumption)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func finding(_ target: ProbeTarget) -> some View {
        HStack(spacing: 6) {
            FindingMark(standing: bench.standing(of: target, for: cli))
            Text(target.title)
            if !target.gatesVerdict {
                Text("not gating").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(target.meaning)
    }
}

// MARK: - B · Two columns

struct AgentCLIColumnsVariant: View {
    let bench: AgentCLIBench

    var body: some View {
        SettingsColumn(spacing: 12) {
            if bench.clis.isEmpty { NoCLIsState() }
            ForEach(bench.clis) { cli in ColumnsCard(bench: bench, cli: cli) }
            AgentCLIPaneFooter(bench: bench)
        }
    }
}

private struct ColumnsCard: View {
    let bench: AgentCLIBench
    let cli: DeclaredCLI

    private var run: ProbeRun? { bench.run.flatMap { $0.cli == cli.name ? $0 : nil } }

    var body: some View {
        RoutingCard(highlighted: run != nil) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cli.name).font(.headline.monospaced())
                Spacer()
                ProbeButton(bench: bench, cli: cli)
                RemoveCLIButton(bench: bench, cli: cli)
            }
            HStack(alignment: .top, spacing: 20) {
                facts.frame(width: 250, alignment: .leading)
                Divider()
                targets.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let run {
                ProbeProgressSummary(run: run)
            } else {
                DriftLine(cli: cli).font(.callout)
                if let reason = cli.latest?.reason {
                    Text(reason).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            fact("Probed", run != nil ? "Probing now" : cli.latest?.probedAtText ?? "Never")
            fact("CLI version", cli.latest?.cliVersion ?? "\u{2014}")
            fact("Adapter", cli.latest?.adapterVersion ?? "\u{2014}")
            fact("Executable", cli.executableText, monospaced: true)
            GridRow {
                Text("Routes").foregroundStyle(.secondary)
                Text(eligibility).foregroundStyle(cli.eligibility == .offered ? .primary : .secondary)
            }
        }
        .font(.callout)
    }

    private var eligibility: String {
        switch cli.eligibility {
        case .offered: "Offered"
        case .excluded(let reason): "Not offered: \(reason)"
        }
    }

    private func fact(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var targets: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ProbeTarget.allCases) { target in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    FindingMark(standing: bench.standing(of: target, for: cli)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.title + (target.gatesVerdict ? "" : " \u{00B7} recorded only"))
                        Text(target.meaning).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
#endif
