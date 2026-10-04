#if DEBUG
import SwiftUI

// Controls every Agent CLIs variant shares. Removing a CLI is a trash button, as removing a Repo is in a
// Project's settings and the Add Project sheet; a Probe's progress reads in words — the stage, the step,
// the time so far and what is left — beside whatever bar or list a variant adds.

// MARK: - Actions

/// "Probe", or "Stop" for the CLI being probed. Every other Probe waits while one runs, as in the app.
struct ProbeButton: View {
    let bench: AgentCLIBench
    let cli: DeclaredCLI

    var body: some View {
        if bench.run?.cli == cli.name {
            Button("Stop", systemImage: "stop.fill") { bench.stopProbe() }
                .help("Stop the Probe of \(cli.name); nothing is recorded")
        } else {
            Button(cli.latest == nil ? "Probe Now" : "Probe Again") { bench.probe(cli.name) }
                .disabled(bench.isProbing)
                .help(bench.isProbing ? "One Probe runs at a time" : "Run yh probe \(cli.name)")
        }
    }
}

/// The trash button the Repo cards use, confirming first. A routed CLI cannot be removed until the Base
/// Routing Table stops naming it, and nothing is removed while a Probe runs.
struct RemoveCLIButton: View {
    let bench: AgentCLIBench
    let cli: DeclaredCLI
    @State private var confirms = false

    var body: some View {
        Button("Remove \(cli.name)", systemImage: "trash", role: .destructive) { confirms = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(bench.isProbing || cli.isRouted)
            .help(cli.isRouted
                ? "A base route names \(cli.name); change it in the Base Routing Table first."
                : "Remove \(cli.name)")
            .confirmationDialog("Remove \(cli.name)?", isPresented: $confirms, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { bench.remove(cli.name) }
            } message: {
                Text(
                    "Yellowhammer stops dispatching to \(cli.name). Its declaration leaves config.toml; "
                        + "its Probe history stays."
                )
            }
    }
}

// MARK: - Findings

/// A finding's mark: a filled check, a cross, a dash for not run; a spinner while its stage runs and an
/// empty circle before.
struct FindingMark: View {
    let standing: TargetStanding

    var body: some View {
        switch standing {
        case .decided(.passed):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(SettingsTheme.success)
        case .decided(.failed):
            Image(systemName: "xmark.circle.fill").foregroundStyle(SettingsTheme.error)
        case .decided(.notRun):
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        }
    }
}

extension AgentCLIBench {
    /// Where `target` stands for `cli`: live while its Probe runs, else the latest Probe Result's finding.
    func standing(of target: ProbeTarget, for cli: DeclaredCLI) -> TargetStanding {
        if let run, run.cli == cli.name { return run.standing(of: target) }
        guard let latest = cli.latest else { return .pending }
        return .decided(latest.finding(target))
    }
}

/// The CLI's state as a small capsule: Passed, Failed, Never probed, or Probing.
struct CLIStatusBadge: View {
    let bench: AgentCLIBench
    let cli: DeclaredCLI

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: .capsule)
    }

    private var text: String {
        if bench.run?.cli == cli.name { return "Probing" }
        guard let latest = cli.latest else { return "Never probed" }
        return latest.passed ? "Passed" : "Failed"
    }

    private var tint: Color {
        if bench.run?.cli == cli.name { return SettingsTheme.accent }
        guard let latest = cli.latest else { return SettingsTheme.neutral }
        return latest.passed ? SettingsTheme.success : SettingsTheme.error
    }
}

/// Whether the CLI is offered as a route target, with the reason when it is not.
struct EligibilityLine: View {
    let cli: DeclaredCLI

    var body: some View {
        let isOffered = cli.eligibility == .offered
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isOffered ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(isOffered ? AnyShapeStyle(SettingsTheme.success) : AnyShapeStyle(.secondary))
            Text(text).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var text: String {
        switch cli.eligibility {
        case .offered: "Offered as a route target"
        case .excluded(let reason): "Not offered as a route target: \(reason)"
        }
    }
}

/// The targets that regressed since the Probe before, with both versions.
struct DriftLine: View {
    let cli: DeclaredCLI

    var body: some View {
        if let latest = cli.latest, let previous = cli.previous, !cli.drift.isEmpty {
            Label {
                Text(
                    "Drift since \(previous.cliVersion): \(cli.drift.map(\.title).formatted(.list(type: .and))) "
                        + "no longer passes under \(latest.cliVersion)."
                )
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SettingsTheme.attention)
            }
            .textSelection(.enabled)
        }
    }
}

extension ProbeResultFixture {
    /// "4 Oct 2026 at 10:06".
    var probedAtText: String { probedAt.formatted(date: .abbreviated, time: .shortened) }
}

// MARK: - A Probe under way

/// "Resuming the session · Step 4 of 7 · 1:12 so far, about 1 min left", with a bar when `bar` is set.
struct ProbeProgressSummary: View {
    let run: ProbeRun
    var bar = true
    /// Whether to say what the stage under way does; off where a stage list already says it.
    var showsDetail = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(headline).fontWeight(.medium)
                Spacer(minLength: 8)
                Text(timing).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if bar {
                ProgressView(value: run.fraction).progressViewStyle(.linear)
            }
            if showsDetail, !run.isOver {
                Text(run.stage.detail(cli: run.cli)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        if run.wasStopped { return "Stopped at \(run.stage.title.lowercased())" }
        if run.isOver { return run.outcome.passed ? "Probe passed" : "Probe failed" }
        return "\(run.stage.activeTitle) \u{00B7} \(run.stepText)"
    }

    private var timing: String {
        run.isOver ? "took \(run.elapsedText)" : "\(run.elapsedText) so far, \(run.remainingText)"
    }
}

/// A Probe's stages as a checklist: each ended one with its time, the running one with a spinner and its
/// time so far, the rest still to come.
struct ProbeStageList: View {
    let run: ProbeRun
    var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ProbeStage.allCases) { stage in
                let standing = run.standing(of: stage)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    mark(standing).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(standing == .running ? stage.activeTitle : stage.title)
                            .fontWeight(standing == .running ? .medium : .regular)
                            .foregroundStyle(standing == .pending || standing == .skipped ? .tertiary : .primary)
                        if showsDetail, standing == .running {
                            Text(stage.detail(cli: run.cli)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(time(stage, standing)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func mark(_ standing: StageStanding) -> some View {
        switch standing {
        case .done: Image(systemName: "checkmark").foregroundStyle(SettingsTheme.success)
        case .running: ProgressView().controlSize(.mini)
        case .pending: Image(systemName: "circle").font(.caption2).foregroundStyle(.tertiary)
        case .skipped: Image(systemName: "minus").foregroundStyle(.tertiary)
        }
    }

    private func time(_ stage: ProbeStage, _ standing: StageStanding) -> String {
        switch standing {
        case .done: run.stageTimes[stage].map(ProbeRun.clock) ?? ""
        case .running: ProbeRun.clock(run.stageElapsed)
        case .pending: "~" + ProbeRun.clock(stage.typicalSeconds)
        case .skipped: "not run"
        }
    }
}

/// `yh probe`'s output, scrolled to its newest line.
struct ProbeLogView: View {
    let lines: [String]
    var maxHeight: CGFloat = 160

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line).id(index)
                    }
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxHeight: maxHeight)
            .background(SettingsTheme.surface, in: .rect(cornerRadius: 8))
            .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
        }
    }
}

// MARK: - The rest of the pane

/// The warning the app shows while no base route names a declared CLI.
struct NoRouteNotice: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SettingsTheme.attention)
            Text("No base route names a declared agent CLI yet.")
            Spacer()
            Button("Open Base Routing Table") {}
        }
        .padding(12)
        .background(SettingsTheme.attention.opacity(0.08), in: .rect(cornerRadius: 10))
    }
}

/// Declaring a registered CLI not yet declared, as a dashed card like the Repo list's placeholder, so it
/// reads as the next item rather than a form.
struct DeclareCLICard: View {
    let bench: AgentCLIBench
    @State private var name = ""
    @State private var executable = ""

    var body: some View {
        if !bench.declarableNames.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Declare").fontWeight(.medium)
                    Picker("Agent CLI", selection: $name) {
                        ForEach(bench.declarableNames, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("Executable", text: $executable, prompt: Text("Looked up on PATH"))
                        .font(.body.monospaced())
                        .frame(maxWidth: 260)
                    Spacer(minLength: 8)
                    Button("Declare", systemImage: "plus") {
                        bench.declare(name, executable: executable)
                        executable = ""
                    }
                    .disabled(name.isEmpty)
                }
                Text(
                    "Scheduled runs get a minimal PATH, so an absolute path is how yh finds the CLI unattended. "
                        + (bench.configMissing ? "Declaring creates config.toml." : "Declaring does not probe.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(SettingsTheme.neutral.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5]))
            )
            .onAppear(perform: resetName)
            .onChange(of: bench.declarableNames) { _, _ in resetName() }
        }
    }

    private func resetName() {
        if !bench.declarableNames.contains(name) { name = bench.declarableNames.first ?? "" }
    }
}

/// What the pane shows with nothing declared: what that means, and the way forward below it.
struct NoCLIsState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
            Text("No Agent CLIs").font(.headline)
            Text("No Card can be dispatched until an agent CLI is declared and passes its Probe.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// The bottom of every variant's column: the no-route warning, then the declare card.
struct AgentCLIPaneFooter: View {
    let bench: AgentCLIBench

    var body: some View {
        if !bench.clis.isEmpty && !bench.hasRoute { NoRouteNotice() }
        DeclareCLICard(bench: bench)
    }
}
#endif
