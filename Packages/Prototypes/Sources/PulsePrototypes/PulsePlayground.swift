#if DEBUG
import Domain
import Pulse
import SwiftUI

// The Pulse prototyping harness. Debug builds only.
//
// - `PulseVariant.all` lists every prototype. To add one, either compose a `PulseDesign` from the
//   section, Sidebar, toolbar and Inspector styles, or write a view that takes a `LandingSnapshot` and a
//   `Binding<ProjectID?>` (the Sidebar selection), and append it there. Only the names in
//   `PulseVariant.shown` are offered by the Playground and Gallery; a `#Preview` can still open any
//   variant by name.
// - The "Colors" controls edit `PulsePalette`, the eight colours every composed variant reads.
// - The "Playground" preview hosts one variant beside live controls: pick the variant and the scenario,
//   then change counts and states and watch the variant react.
// - The "Gallery" preview shows one variant at a time for a scenario: pick it from the menu or step
//   with ← and →.
//
// A variant reads only the snapshot, and calls `openPulseDestination` for every way out. It never
// reads a Journal or runs `yh`, so every variant stays portable to the shipped screen.

/// One prototype of the landing screen.
struct PulseVariant: Identifiable {
    let name: String
    /// What the variant is trying, in a line, so the gallery says why it exists.
    let idea: String
    let make: (LandingSnapshot, Binding<ProjectID?>) -> AnyView

    var id: String { name }

    init<Content: View>(
        _ name: String,
        idea: String,
        @ViewBuilder make: @escaping (LandingSnapshot, Binding<ProjectID?>) -> Content
    ) {
        self.name = name
        self.idea = idea
        self.make = { AnyView(make($0, $1)) }
    }

    /// A variant assembled from interchangeable section, Sidebar, toolbar and Inspector styles.
    init(_ name: String, idea: String, design: PulseDesign) {
        // Not `self.init(_:idea:make:)`: the preview thunk wraps that call, and initializer delegation
        // cannot be nested in another expression.
        self.name = name
        self.idea = idea
        self.make = { AnyView(PulseComposedVariant(snapshot: $0, selection: $1, design: design)) }
    }
}

// MARK: - Playground

/// One variant beside controls that edit the selected Project's snapshot live.
struct PulsePlayground: View {
    @State private var variantName: String
    @State private var scenario: PulseScenario
    @State private var snapshot: LandingSnapshot
    @State private var selection: ProjectID?
    @State private var lastWayOut: String?
    @State private var darkAppearance = false
    @State private var palettePreset: PulsePalettePreset = .system
    @State private var palette = PulsePalette()

    init(variant: String? = nil, scenario: PulseScenario = .morningTriage) {
        _variantName = State(initialValue: variant ?? PulseVariant.inPlay.first?.name ?? "")
        _scenario = State(initialValue: scenario)
        _snapshot = State(initialValue: scenario.snapshot)
        _selection = State(initialValue: scenario.focus)
    }

    private var variant: PulseVariant? {
        PulseVariant.all.first { $0.name == variantName } ?? PulseVariant.inPlay.first
    }

    /// The shown variants, plus the current one when a `#Preview` opened a shelved variant by name.
    private var pickable: [PulseVariant] {
        let inPlay = PulseVariant.inPlay
        guard let variant, !inPlay.contains(where: { $0.id == variant.id }) else { return inPlay }
        return inPlay + [variant]
    }

    var body: some View {
        // The recorders capture only the binding they write, never the whole Playground.
        let wayOut = $lastWayOut
        HStack(spacing: 0) {
            Group {
                if let variant {
                    variant.make(snapshot, $selection)
                } else {
                    Text("No variant in PulseVariant.shown")
                }
            }
            .environment(\.openPulseDestination) { wayOut.wrappedValue = String(describing: $0) }
            .environment(\.pulsePrototypeAction) { wayOut.wrappedValue = "prototype action: \($0)" }
            .environment(\.pulsePalette, palette)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(darkAppearance ? .dark : .light)

            Divider()
            controls
                .frame(width: 300)
        }
        // At least 1 140 pt for the variant: a three-column split view much narrower than that loops
        // on AppKit constraint passes and crashes the preview.
        .frame(minWidth: 1_440, minHeight: 760)
    }

    private var controls: some View {
        Form {
            Section("Prototype") {
                Picker("Variant", selection: $variantName) {
                    ForEach(pickable) { Text($0.name).tag($0.name) }
                }
                Picker("Scenario", selection: $scenario) {
                    ForEach(PulseScenario.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: scenario) { _, newValue in
                    snapshot = newValue.snapshot
                    selection = newValue.focus
                }
                Toggle("Dark appearance", isOn: $darkAppearance)
            }
            PulsePaletteControls(palette: $palette, preset: $palettePreset)
            if let index = snapshot.projects.firstIndex(where: { $0.id == selection }) {
                PulseProjectControls(project: $snapshot.projects[index])
            } else {
                Text("Select a Project in the Sidebar to edit its Pulse.")
                    .foregroundStyle(.secondary)
            }
            Section("Last way out") {
                Text(lastWayOut ?? "None yet — click a Pulse element")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

/// The controls for one Project. Every edit goes through the fixture knobs, so the Pulse stays a state
/// the engine could produce.
private struct PulseProjectControls: View {
    @Binding var project: ProjectSnapshot

    var body: some View {
        Section("Project") {
            TextField("Name", text: $project.name)
            Stepper("Repos: \(repoCount.wrappedValue)", value: repoCount, in: 1...PulseFixtures.manyRepos.count)
        }
        Section("Now") {
            Picker("Status", selection: status) {
                ForEach(ProjectStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Stepper("Running Attempts: \(attempts.wrappedValue)", value: attempts, in: 0...6)
        }
        Section("Needs you") {
            Stepper("Waiting on You: \(waiting.wrappedValue)", value: waiting, in: 0...12)
            Stepper("Blocked: \(blockedCount)", value: blocked, in: 0...12)
        }
        Section("Feature") {
            Picker("Roll-up", selection: rollup) {
                Text("No Feature in flight").tag(RollUpState?.none)
                ForEach(RollUpState.allCases, id: \.self) { Text($0.rawValue).tag(RollUpState?.some($0)) }
            }
        }
        Section("Tonight / last Night") {
            Picker("Night", selection: night) {
                Text("No Night yet").tag(NightPulseState?.none)
                ForEach(NightPulseState.allCases, id: \.self) { Text($0.rawValue).tag(NightPulseState?.some($0)) }
            }
            if project.pulse.night != nil {
                TextField("Verdict line", text: verdictLine, axis: .vertical)
            }
        }
        Section("Health") {
            ForEach(HealthFlagKind.allCases, id: \.self) { kind in
                Toggle(kind.rawValue, isOn: healthFlag(kind))
            }
        }
    }

    private var blockedCount: Int {
        project.pulse.needsYou.cards.count { $0.state == .blocked }
    }

    private var repoCount: Binding<Int> {
        Binding {
            project.repos.count
        } set: { count in
            project.repos = Array(PulseFixtures.manyRepos.prefix(count))
            if let rollup = project.pulse.feature?.rollupState {
                project.pulse.feature = Self.feature(rollup, repos: project.repos)
            }
            project.pulse.setAttempts(project.pulse.now.attempts.count, across: project.repos)
        }
    }

    private var status: Binding<ProjectStatus> {
        Binding { project.pulse.now.status } set: { project.pulse.setStatus($0) }
    }

    private var attempts: Binding<Int> {
        Binding { project.pulse.now.attempts.count } set: { project.pulse.setAttempts($0, across: project.repos) }
    }

    private var waiting: Binding<Int> {
        Binding { project.pulse.needsYou.waitingOnYouCount } set: { project.pulse.setWaitingOnYou($0) }
    }

    private var blocked: Binding<Int> {
        Binding { blockedCount } set: { project.pulse.setBlocked($0) }
    }

    private var rollup: Binding<RollUpState?> {
        Binding {
            project.pulse.feature?.rollupState
        } set: { rollup in
            project.pulse.feature = rollup.map { Self.feature($0, repos: project.repos) }
        }
    }

    private var night: Binding<NightPulseState?> {
        Binding {
            project.pulse.night?.state
        } set: { state in
            project.pulse.night = state.map { PulseFixtures.night($0) }
        }
    }

    private var verdictLine: Binding<String> {
        Binding {
            project.pulse.night?.verdictLine ?? ""
        } set: { line in
            project.pulse.night?.verdictLine = line
        }
    }

    private func healthFlag(_ kind: HealthFlagKind) -> Binding<Bool> {
        Binding {
            (project.pulse.health ?? []).contains { $0.kind == kind }
        } set: { raised in
            project.pulse.setHealthFlag(kind, raised)
        }
    }

    private static func feature(_ rollup: RollUpState, repos: [String]) -> FeatureInFlight {
        rollup == .partialLanding && repos == PulseFixtures.defaultRepos
            ? PulseFixtures.partialLandingFeature
            : PulseFixtures.feature(rollup: rollup, repos: repos)
    }
}

// MARK: - Gallery

/// Every variant for one scenario, one at a time: pick it from the menu or step through with ← and →.
///
/// Only one variant is alive at a time. Each is a full split view with a toolbar and an Inspector, and
/// several of them in one scrolling window — or any one narrower than about 1 140 pt — loop on AppKit
/// constraint passes and crash the preview.
struct PulseGallery: View {
    @State private var scenario: PulseScenario = .morningTriage
    @State private var index = 0

    private var variants: [PulseVariant] { PulseVariant.inPlay }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if variants.indices.contains(index) {
                PulseGalleryTile(variant: variants[index], scenario: scenario)
                    // A fresh tile per variant and scenario, so the Sidebar selection starts from the focus.
                    .id("\(variants[index].id)/\(scenario.id)")
            } else {
                Text("No variant in PulseVariant.shown")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1_440, minHeight: 800)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Variant", selection: $index) {
                ForEach(variants.indices, id: \.self) { Text(variants[$0].name).tag($0) }
            }
            .fixedSize()
            ControlGroup {
                Button("Previous", systemImage: "chevron.left") { index -= 1 }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index <= 0)
                Button("Next", systemImage: "chevron.right") { index += 1 }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index >= variants.count - 1)
            }
            .fixedSize()
            Text("\(index + 1) of \(variants.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if variants.indices.contains(index) {
                Text(variants[index].idea)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Picker("Scenario", selection: $scenario) {
                ForEach(PulseScenario.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
        }
    }
}

/// One variant with its own selection, so it can be clicked through independently.
private struct PulseGalleryTile: View {
    let variant: PulseVariant
    let scenario: PulseScenario
    @State private var selection: ProjectID?

    init(variant: PulseVariant, scenario: PulseScenario) {
        self.variant = variant
        self.scenario = scenario
        _selection = State(initialValue: scenario.focus)
    }

    var body: some View {
        variant.make(scenario.snapshot, $selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Playground") {
    PulsePlayground()
}

#Preview("Gallery") {
    PulseGallery()
}
#endif
