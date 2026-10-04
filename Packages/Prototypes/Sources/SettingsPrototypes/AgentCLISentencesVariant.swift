#if DEBUG
import SwiftUI

// C · Sentences: each CLI reads as one sentence — the routing pane's liked pattern — with its four findings
// as a row of marks under it. A Probe under way rewrites the sentence to say what it is doing, beside a
// ring that fills, and shows `yh probe`'s newest line.

struct AgentCLISentencesVariant: View {
    let bench: AgentCLIBench

    var body: some View {
        SettingsColumn(spacing: 12) {
            if bench.clis.isEmpty { NoCLIsState() }
            ForEach(bench.clis) { cli in SentenceCLICard(bench: bench, cli: cli) }
            AgentCLIPaneFooter(bench: bench)
        }
    }
}

private struct SentenceCLICard: View {
    let bench: AgentCLIBench
    let cli: DeclaredCLI

    private var run: ProbeRun? { bench.run.flatMap { $0.cli == cli.name ? $0 : nil } }

    var body: some View {
        RoutingCard(highlighted: run != nil) {
            HStack(alignment: .center, spacing: 12) {
                if let run {
                    ProgressView(value: run.fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
                sentence
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProbeButton(bench: bench, cli: cli)
                RemoveCLIButton(bench: bench, cli: cli)
            }
            HStack(spacing: 16) {
                ForEach(ProbeTarget.allCases) { target in
                    HStack(spacing: 5) {
                        FindingMark(standing: bench.standing(of: target, for: cli))
                        Text(target.shortTitle).foregroundStyle(target.gatesVerdict ? .primary : .secondary)
                    }
                    .help(target.meaning + (target.gatesVerdict ? "" : "; recorded, never decides the verdict"))
                }
            }
            .font(.callout)
            if let run, let line = run.log.last {
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                DriftLine(cli: cli).font(.callout)
            }
        }
    }

    private var name: Text { Text(cli.name).font(.body.monospaced()).fontWeight(.semibold) }

    @ViewBuilder private var sentence: some View {
        if let run {
            let doing = "\(run.stage.activeTitle.lowercased()), \(run.stepText.lowercased())"
            let timing = "\(run.elapsedText) so far, \(run.remainingText)"
            Text("Probing \(name): \(doing) \u{2014} \(timing).")
        } else if let latest = cli.latest {
            let version = Text(latest.cliVersion).foregroundStyle(.secondary)
            if latest.passed {
                let rest = "and is offered as a route target."
                Text("\(name) \(version) passed its Probe on \(latest.probedAtText) \(rest)")
            } else {
                let failed = latest.failedTargets.filter(\.gatesVerdict).map { $0.title.lowercased() }
                    .formatted(.list(type: .and))
                let rest = "so it is not offered as a route target."
                Text("\(name) \(version) failed \(failed) on \(latest.probedAtText), \(rest)")
            }
        } else {
            let minutes = Int((ProbeStage.typicalTotal / 60).rounded())
            let rest = "so it is not offered as a route target yet. A Probe takes about \(minutes) min."
            Text("\(name) has never been probed, \(rest)")
        }
    }
}
#endif
