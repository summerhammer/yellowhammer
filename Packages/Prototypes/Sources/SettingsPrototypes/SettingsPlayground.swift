#if DEBUG
import SwiftUI

// The Settings window prototyping harness, for the Base Routing Table and Agent CLIs panes. Debug builds only.
//
// - `SettingsStage` draws the window as the app does; only the pane's content is a variant.
// - The "Playground" preview hosts the window beside live controls: Pane, Variant, Scenario, appearance,
//   and what the pane writes or prints — the table as `config.toml` would hold it, or the Probe's output.
// - Each variant also has a preview of its own.
//
// Nothing here reads `config.toml`, reads the Ledger or runs `yh`: the table is `RoutingScenario`'s
// fixtures, and the agent CLIs are `AgentCLIScenario`'s, probed by `AgentCLIBench`'s simulation.

struct SettingsPlayground: View {
    @State private var pane: StageSection
    @State private var darkAppearance = false

    @State private var variantName: String
    @State private var scenario: RoutingScenario
    @State private var rules: [RoutingRule]
    @State private var saved: [RoutingRule]

    @State private var cliVariantName: String
    @State private var cliScenario: AgentCLIScenario
    @State private var bench: AgentCLIBench

    init(
        pane: StageSection = .baseRoutingTable,
        variant: String = "H + I · Kind pop-up",
        scenario: RoutingScenario = .typical,
        cliVariant: String = AgentCLIVariant.all[0].name,
        cliScenario: AgentCLIScenario = .allPassed,
        probeSpeed: Double = 10
    ) {
        _pane = State(initialValue: pane)
        _variantName = State(initialValue: variant)
        _scenario = State(initialValue: scenario)
        let rules = scenario.rules
        _rules = State(initialValue: rules)
        _saved = State(initialValue: rules)
        _cliVariantName = State(initialValue: cliVariant)
        _cliScenario = State(initialValue: cliScenario)
        _bench = State(initialValue: AgentCLIBench(scenario: cliScenario, speed: probeSpeed))
    }

    var body: some View {
        HStack(spacing: 0) {
            stage
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.08))
                .preferredColorScheme(darkAppearance ? .dark : .light)
            Divider()
            controls.frame(width: 320)
        }
        .frame(minWidth: 1_380, minHeight: 760)
    }

    @ViewBuilder private var stage: some View {
        switch pane {
        case .baseRoutingTable:
            SettingsStage(section: .baseRoutingTable, isDirty: rules != saved, onRevert: { rules = saved }, content: {
                (variant?.make($rules) ?? AnyView(EmptyView())).id("\(variantName)-\(scenario.rawValue)")
            })
        case .agentCLIs:
            SettingsStage(section: .agentCLIs) {
                (cliVariant?.make(bench) ?? AnyView(EmptyView())).id("\(cliVariantName)-\(cliScenario.rawValue)")
            }
        }
    }

    private var variant: RoutingVariant? { RoutingVariant.named(variantName) }
    private var cliVariant: AgentCLIVariant? { AgentCLIVariant.named(cliVariantName) }

    private func reset(to scenario: RoutingScenario) {
        rules = scenario.rules
        saved = rules
    }

    private func reset(to scenario: AgentCLIScenario) {
        bench.stopProbe()
        bench = AgentCLIBench(scenario: scenario, speed: bench.speed)
    }

    private var controls: some View {
        Form {
            Section("Prototype") {
                Picker("Pane", selection: $pane) {
                    ForEach(StageSection.allCases) { Text($0.rawValue).tag($0) }
                }
                switch pane {
                case .baseRoutingTable: routingControls
                case .agentCLIs: agentCLIControls
                }
                Toggle("Dark appearance", isOn: $darkAppearance)
            }
            switch pane {
            case .baseRoutingTable:
                Section("As config.toml writes it") { monospaced(toml) }
            case .agentCLIs:
                Section("As yh probe would print it") {
                    Text(
                        "Today yh probe prints only once the Probe is over. Every variant assumes it reports each "
                            + "stage as it starts, as below."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    monospaced((bench.run ?? bench.lastRun)?.log.joined(separator: "\n") ?? "# no Probe run yet")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var routingControls: some View {
        Picker("Variant", selection: $variantName) {
            ForEach(RoutingVariant.all) { Text($0.name).tag($0.name) }
        }
        if let idea = variant?.idea {
            Text(idea).font(.callout).foregroundStyle(.secondary)
        }
        Picker("Scenario", selection: $scenario) {
            ForEach(RoutingScenario.allCases) { Text($0.rawValue).tag($0) }
        }
        .onChange(of: scenario) { _, newValue in reset(to: newValue) }
        Button("Reset Scenario") { reset(to: scenario) }
    }

    @ViewBuilder private var agentCLIControls: some View {
        Picker("Variant", selection: $cliVariantName) {
            ForEach(AgentCLIVariant.all) { Text($0.name).tag($0.name) }
        }
        if let idea = cliVariant?.idea {
            Text(idea).font(.callout).foregroundStyle(.secondary)
        }
        Picker("Scenario", selection: $cliScenario) {
            ForEach(AgentCLIScenario.allCases) { Text($0.rawValue).tag($0) }
        }
        .onChange(of: cliScenario) { _, newValue in reset(to: newValue) }
        Button("Reset Scenario") { reset(to: cliScenario) }
        Picker("Probe speed", selection: $bench.speed) {
            Text("Paused").tag(0.0)
            Text("Real time").tag(1.0)
            Text("10\u{00D7}").tag(10.0)
            Text("30\u{00D7}").tag(30.0)
        }
        Text("A real Probe takes about \(ProbeRun.clock(ProbeStage.typicalTotal)); the estimate is a typical run's.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The `[[routing]]` tables, in the shorthand the app's renderer uses.
    private var toml: String {
        guard !rules.isEmpty else { return "# no [[routing]] entries" }
        return rules.map { rule in
            var lines = ["[[routing]]", "kind = \"\(rule.isAnyKind ? "*" : rule.kindTitle)\""]
            if !rule.isAnyRepoRole { lines.append("repo_role = \"\(rule.repoRole)\"") }
            lines.append("route = \"\(rule.route.shorthand)\"")
            if !rule.fallbacks.isEmpty {
                lines.append("fallbacks = [\(rule.fallbacks.map { "\"\($0.shorthand)\"" }.joined(separator: ", "))]")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}

#Preview("Playground") { SettingsPlayground() }

#Preview("H + I · Kind pop-up") { SettingsPlayground(variant: "H + I · Kind pop-up") }
#Preview("H + J · Kind path") { SettingsPlayground(variant: "H + J · Kind path") }
#Preview("First run") { SettingsPlayground(scenario: .empty) }

// The Agent CLIs variants open on a Probe under way, at real time, so a still shows one mid-run.
#Preview("Agent CLIs · Playground") { SettingsPlayground(pane: .agentCLIs) }
#Preview("A · Checklist") {
    SettingsPlayground(pane: .agentCLIs, cliVariant: "A · Checklist", cliScenario: .probing, probeSpeed: 1)
}
#Preview("B · Two columns") {
    SettingsPlayground(pane: .agentCLIs, cliVariant: "B · Two columns", cliScenario: .probing, probeSpeed: 1)
}
#Preview("C · Sentences") {
    SettingsPlayground(pane: .agentCLIs, cliVariant: "C · Sentences", cliScenario: .probing, probeSpeed: 1)
}
#Preview("E · Activity panel") {
    SettingsPlayground(pane: .agentCLIs, cliVariant: "E · Activity panel", cliScenario: .probing, probeSpeed: 1)
}
#Preview("Agent CLIs · Trouble") {
    SettingsPlayground(pane: .agentCLIs, cliVariant: "A · Checklist", cliScenario: .trouble)
}
#endif
