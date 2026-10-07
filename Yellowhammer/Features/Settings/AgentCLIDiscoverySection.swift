import Config
import SwiftUI

/// The Agent CLIs pane's "Found on This Mac" section (#375): the agent CLIs a search of this Mac turned up,
/// each with a way to declare it or point its declaration at the path found. Searching looks at files only
/// and writes nothing; only the Operator's buttons here write `config.toml`, through the model. A find is not
/// readiness: the Probe is.
struct AgentCLIDiscoverySection: View {
    @Bindable var model: AgentCLIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Found on This Mac").fontWeight(.medium)
                Spacer()
                if model.isDiscovering {
                    ProgressView().controlSize(.small)
                }
                Button("Rescan", systemImage: "arrow.clockwise") {
                    Task { await model.discover() }
                }
                .disabled(model.isDiscovering)
                .accessibilityIdentifier("agent-cli-rescan")
            }
            Text(
                "Searched your login shell\u{2019}s PATH, then this app\u{2019}s PATH, /etc/paths, and the usual "
                    + "install locations, in that order; the first found is preferred. Finding an agent CLI does "
                    + "not make it ready: declare it, then run its Probe."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let failure = model.loginShellFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent-cli-login-shell-failure")
            }
            if let discoveries = model.discoveries {
                ForEach(discoveries, id: \.descriptor.cli) { discovery in
                    if discovery.isSupported || !discovery.candidates.isEmpty {
                        AgentCLIDetectedRow(model: model, discovery: discovery)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("agent-cli-detected-\(discovery.descriptor.cli)")
                    }
                }
            } else {
                Text("Searching\u{2026}").foregroundStyle(.secondary)
            }
        }
        .task { await model.discover() }
    }
}

/// One descriptor's find: its heading, then exactly one state.
private struct AgentCLIDetectedRow: View {
    @Bindable var model: AgentCLIModel
    let discovery: CLIDiscovery

    @State private var chosenPath: String?

    private var cli: String { discovery.descriptor.cli }

    var body: some View {
        SettingsCard {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(discovery.descriptor.vendorName).fontWeight(.medium)
                Text(cli).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            state
            ForEach(discovery.selectable.filter { $0.caveat != nil }, id: \.path) { candidate in
                if let caveat = candidate.caveat {
                    Label(caveat, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(discovery.candidates.filter { $0.refusal != nil }, id: \.path) { candidate in
                if let refusal = candidate.refusal {
                    Text("\(candidate.path): \(refusal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: discovery.selectable.map(\.path)) { _, paths in
            if let chosenPath, !paths.contains(chosenPath) { self.chosenPath = nil }
        }
    }

    /// The selected path: the Operator's pick while it is still offered, else the preferred one.
    private var selected: CLICandidate? {
        discovery.selectable.first { $0.path == chosenPath } ?? discovery.preferred
    }

    @ViewBuilder private var state: some View {
        if !discovery.isSupported {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Found, but there is no CLI Adapter for \(cli) yet, so it cannot be declared or routed. "
                        + "It needs a CLI Adapter and a passing Probe first."
                )
                .fixedSize(horizontal: false, vertical: true)
                ForEach(discovery.candidates, id: \.path) { candidate in
                    Text(candidate.path).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .accessibilityIdentifier("agent-cli-detected-unsupported-\(cli)")
        } else if let declaration = model.declaration(named: cli) {
            declaredState(declaration)
        } else if discovery.selectable.isEmpty {
            Text("Not found on this Mac. If it is installed elsewhere, declare it with its path below.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agent-cli-detected-not-found-\(cli)")
        } else {
            HStack(alignment: .top, spacing: 8) {
                chooser
                Spacer(minLength: 8)
                if let selected {
                    Button("Declare", systemImage: "plus") {
                        model.declare(name: cli, executable: selected.path)
                    }
                    .accessibilityIdentifier("agent-cli-detected-declare-\(cli)")
                }
            }
        }
    }

    @ViewBuilder
    private func declaredState(_ declaration: CLIAdapterDeclaration) -> some View {
        let matches = discovery.selectable.contains { $0.path == declaration.executable }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Declared").fontWeight(.medium)
                Text(declaration.executable ?? "looked up on PATH")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .truncationMode(.middle)
                    .lineLimit(1)
            }
            if matches {
                Text("Declared at the path found here.").font(.caption).foregroundStyle(.secondary)
            } else if discovery.selectable.isEmpty {
                Text("Not found on this Mac; the declaration is kept as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agent-cli-detected-not-found-\(cli)")
            } else {
                HStack(alignment: .top, spacing: 8) {
                    chooser
                    Spacer(minLength: 8)
                    if let selected {
                        Button("Use This Path") { model.use(executable: selected.path, for: cli) }
                            .accessibilityIdentifier("agent-cli-detected-use-\(cli)")
                    }
                }
                Text("Scheduled runs get a minimal PATH; an absolute path is how yh finds \(cli) unattended.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = model.useFailures[cli] {
                SettingsFailureText(text: failure, identifier: "agent-cli-detected-use-failure-\(cli)")
            }
        }
    }

    /// A single path as selectable text, or a radio group when several were found.
    @ViewBuilder private var chooser: some View {
        if discovery.selectable.count == 1, let only = discovery.selectable.first {
            Text(only.path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .truncationMode(.middle)
                .lineLimit(1)
                .help(Self.help(only))
                .accessibilityIdentifier("agent-cli-detected-path-\(cli)")
        } else {
            Picker("Path", selection: Binding(
                get: { selected?.path ?? "" },
                set: { chosenPath = $0 }
            )) {
                ForEach(discovery.selectable, id: \.path) { candidate in
                    Text("\(candidate.path)  (\(Self.tag(candidate.source)))")
                        .font(.callout.monospaced())
                        .help(Self.help(candidate))
                        .tag(candidate.path)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityIdentifier("agent-cli-detected-path-\(cli)")
        }
    }

    /// The path as found, and the file it resolves to when that is somewhere else (a symlink into a versioned
    /// install directory): the path as found is what is saved, since the resolved one goes when the CLI updates.
    private static func help(_ candidate: CLICandidate) -> String {
        guard candidate.resolvedPath != candidate.path else { return candidate.path }
        return "\(candidate.path)\nResolves to \(candidate.resolvedPath)"
    }

    private static func tag(_ source: ExecutableSearchPath.Source) -> String {
        switch source {
        case .loginShell: "login shell PATH"
        case .appProcess: "app PATH"
        case .systemPaths: "/etc/paths"
        case .knownLocation: "install location"
        }
    }
}
