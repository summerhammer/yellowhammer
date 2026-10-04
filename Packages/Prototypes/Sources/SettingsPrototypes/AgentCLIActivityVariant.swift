#if DEBUG
import SwiftUI

// E · Activity panel: each CLI is one compact card — name, version, four marks, its routing standing — so
// several fit with room to spare, and the Probe gets a panel of its own below them: a bar split into its
// stages, what the current stage is checking, and `yh probe`'s output. The panel stays after the Probe ends,
// replacing the app's Probe log block, until it is closed or another Probe starts.

struct AgentCLIActivityVariant: View {
    let bench: AgentCLIBench

    var body: some View {
        SettingsColumn(spacing: 12) {
            if bench.clis.isEmpty { NoCLIsState() }
            VStack(spacing: 8) {
                ForEach(bench.clis) { cli in CompactCLICard(bench: bench, cli: cli) }
            }
            if let run = bench.run ?? bench.lastRun {
                ProbeActivityPanel(bench: bench, run: run)
            }
            AgentCLIPaneFooter(bench: bench)
        }
    }
}

private struct CompactCLICard: View {
    let bench: AgentCLIBench
    let cli: DeclaredCLI

    var body: some View {
        RoutingCard(highlighted: bench.run?.cli == cli.name) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cli.name).font(.headline.monospaced())
                    Text(cli.latest.map { "\($0.cliVersion) \u{00B7} \($0.probedAtText)" } ?? "Never probed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 230, alignment: .leading)
                HStack(spacing: 10) {
                    ForEach(ProbeTarget.allCases) { target in
                        FindingMark(standing: bench.standing(of: target, for: cli))
                            .help("\(target.title): \(target.meaning)")
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                CLIStatusBadge(bench: bench, cli: cli)
                ProbeButton(bench: bench, cli: cli)
                RemoveCLIButton(bench: bench, cli: cli)
            }
            if cli.latest.map({ !$0.passed }) ?? false || !cli.drift.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    EligibilityLine(cli: cli)
                    DriftLine(cli: cli)
                }
                .font(.callout)
            }
        }
    }
}

private struct ProbeActivityPanel: View {
    let bench: AgentCLIBench
    let run: ProbeRun

    var body: some View {
        SettingsBlock(title: run.isOver ? "Last Probe \u{00B7} \(run.cli)" : "Probing \(run.cli)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    ProbeProgressSummary(run: run, bar: false)
                    if run.isOver {
                        Button("Close", systemImage: "xmark") { bench.dismissLastRun() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Close the last Probe")
                    }
                }
                StageStrip(run: run)
                ProbeLogView(lines: run.log, maxHeight: 110)
            }
            .padding(12)
        }
    }
}

/// The Probe as one bar split into its stages, each segment as wide as the stage typically runs; the
/// running one fills as it goes, and the stage's name sits under the bar.
private struct StageStrip: View {
    let run: ProbeRun

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 3) {
                ForEach(ProbeStage.allCases) { stage in
                    VStack(alignment: .leading, spacing: 5) {
                        segment(stage).frame(height: 6)
                        // Only the long stages have room for a name.
                        if stage.typicalSeconds >= 10 {
                            Text(stage.title)
                                .font(.caption2)
                                .foregroundStyle(run.standing(of: stage) == .running ? .primary : .tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: width(of: stage, in: geometry.size.width), alignment: .leading)
                    .help(stage.title)
                }
            }
        }
        .frame(height: 24)
    }

    private func width(of stage: ProbeStage, in total: CGFloat) -> CGFloat {
        let gaps = CGFloat(ProbeStage.allCases.count - 1) * 3
        return max((total - gaps) * stage.typicalSeconds / ProbeStage.typicalTotal, 4)
    }

    private func segment(_ stage: ProbeStage) -> some View {
        let standing = run.standing(of: stage)
        let filled: Double = switch standing {
        case .done: 1
        case .running: min(run.stageElapsed / stage.typicalSeconds, 0.95)
        case .pending, .skipped: 0
        }
        return Capsule()
            .fill(Color.primary.opacity(0.1))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(standing == .done ? SettingsTheme.success : SettingsTheme.accent)
                        .frame(width: geometry.size.width * filled)
                }
            }
    }
}
#endif
