#if DEBUG
import Pulse
import SwiftUI

// The Night Editor Timeline prototyping harness. Debug builds only.
//
// - `NightTimelineVariant.all` lists every Timeline design. A variant draws only the strip under the
//   transport; `NightEditorFrame` puts the shipped viewer and transport over it, and `NightAccountStage`
//   the main window around that.
// - The "Playground" preview hosts one variant beside its controls; "Close ups" stacks every strip at the
//   editor's width so they can be compared at a glance.
//
// Nothing here reads a Journal or runs `yh`: every Night is a `NightAccountScenario` fixture.

/// One Timeline design.
struct NightTimelineVariant: Identifiable {
    let name: String
    /// What the variant is trying, in a line.
    let idea: String
    let strip: (NightTimeline, Binding<Date>) -> AnyView

    var id: String { name }

    init<Strip: View>(
        _ name: String, idea: String, @ViewBuilder strip: @escaping (NightTimeline, Binding<Date>) -> Strip
    ) {
        self.name = name
        self.idea = idea
        self.strip = { AnyView(strip($0, $1)) }
    }

    static let all: [NightTimelineVariant] = [
        NightTimelineVariant(
            "A \u{00B7} Tracks",
            idea: "A pro-app track area: a header column sums up each Act, the ruler carries the labels, the "
                + "playhead wears a time flag, problems are flagged on the ruler, hover shows a hairline, "
                + "and a click anywhere in the tracks moves the playhead"
        ) { TracksTimeline(timeline: $0, playhead: $1) }
,
        NightTimelineVariant(
            "B · Compact",
            idea: "Single-line Act headers and slim bars keep the full Night in a shallow strip."
        ) { TracksStudyTimeline(study: .compact, timeline: $0, playhead: $1) },
        NightTimelineVariant(
            "C · Expanded",
            idea: "Taller tracks put each substantial run’s outcome and time range inside its bar."
        ) { TracksStudyTimeline(study: .expanded, timeline: $0, playhead: $1) },
        NightTimelineVariant(
            "D · Time grid",
            idea: "Quarter-hour guides extend through every Act for comparing timing across tracks."
        ) { TracksStudyTimeline(study: .grid, timeline: $0, playhead: $1) },
        NightTimelineVariant(
            "E · Outlined",
            idea: "Outlined runs sit on fine track baselines; outcomes remain readable without solid fills."
        ) { TracksStudyTimeline(study: .outline, timeline: $0, playhead: $1) },
        NightTimelineVariant(
            "F · Entry markers",
            idea: "A second line of entry dots beneath each run exposes its recorded activity; hover for headlines."
        ) { TracksStudyTimeline(study: .entries, timeline: $0, playhead: $1) },
        NightTimelineVariant(
            "G · Problem emphasis",
            idea: "Problem runs retain full weight while other runs recede, preserving the whole Night for context."
        ) { TracksStudyTimeline(study: .problems, timeline: $0, playhead: $1) },
        NightTimelineVariant(
            "H · Act focus",
            idea: "Click an Act header to bring its track forward while keeping sibling tracks visible."
        ) { TracksStudyTimeline(study: .focus, timeline: $0, playhead: $1) },
        NightTimelineVariant(
            "I · Bottom ruler",
            idea: "The shared ruler and exact-time flag move below the tracks, closest to the window edge."
        ) { TracksStudyTimeline(study: .bottomRuler, timeline: $0, playhead: $1) },
        NightTimelineVariant(
            "J · Inline problems",
            idea: "Flush tracks with larger run indicators, solid warning and failure fills, and a border only "
                + "on the selected run. Click a run to select it."
        ) { TracksStudyTimeline(study: .inlineProblems, timeline: $0, playhead: $1) }
    ]

    static func named(_ name: String) -> NightTimelineVariant {
        all.first { $0.name == name } ?? all[0]
    }
}

/// The main window with the editor in its centre column and `variant`'s strip docked at the bottom.
struct NightEditorVariantView: View {
    let account: NightAccount
    let variant: NightTimelineVariant
    private let timeline: NightTimeline
    @State private var playhead: Date

    init(account: NightAccount, variant: NightTimelineVariant) {
        self.account = account
        self.variant = variant
        let timeline = NightTimeline(account: account)
        self.timeline = timeline
        _playhead = State(initialValue: timeline.opening)
    }

    var body: some View {
        NightAccountStage {
            NightEditorFrame(timeline: timeline, playhead: $playhead) {
                variant.strip(timeline, $playhead)
            }
        } inspector: {
            NightFactsInspector(account: account)
        }
    }
}

/// One strip on its own, with a playhead of its own, at the editor's width.
struct NightStripHost: View {
    let variant: NightTimelineVariant
    private let timeline: NightTimeline
    @State private var playhead: Date

    init(account: NightAccount, variant: NightTimelineVariant) {
        self.variant = variant
        let timeline = NightTimeline(account: account)
        self.timeline = timeline
        _playhead = State(initialValue: timeline.opening)
    }

    var body: some View {
        variant.strip(timeline, $playhead)
    }
}

/// One variant's strip for every scenario, close up.
struct NightStripCloseUp: View {
    let variant: NightTimelineVariant

    init(variant name: String) {
        variant = .named(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(variant.name).font(.title3.weight(.semibold))
            Text(variant.idea).font(.callout).foregroundStyle(.secondary)
            ForEach(NightAccountScenario.allCases) { scenario in
                VStack(alignment: .leading, spacing: 6) {
                    Text(scenario.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    NightStripHost(account: scenario.account, variant: variant)
                        .clipShape(.rect(cornerRadius: variant.name == "J · Inline problems" ? 0 : 8))
                        .overlay {
                            if variant.name != "J · Inline problems" {
                                RoundedRectangle(cornerRadius: 8).strokeBorder(.separator)
                            }
                        }
                }
            }
        }
        .padding(24)
        .frame(width: nightStageSize.width - 240 - 320 + 48)
        .background(.windowBackground)
    }
}

struct NightTimelinePlayground: View {
    @State private var variantName: String
    @State private var scenario: NightAccountScenario
    @State private var darkAppearance = false

    init(variant: String = NightTimelineVariant.all[0].name, scenario: NightAccountScenario = .hostCrash) {
        _variantName = State(initialValue: variant)
        _scenario = State(initialValue: scenario)
    }

    private var variant: NightTimelineVariant { .named(variantName) }

    var body: some View {
        HStack(spacing: 0) {
            NightEditorVariantView(account: scenario.account, variant: variant)
                .id("\(variant.id)/\(scenario.id)")
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.08))
                .preferredColorScheme(darkAppearance ? .dark : .light)
            Divider()
            controls.frame(width: 300)
        }
        .frame(minWidth: nightStageSize.width + 350, minHeight: nightStageSize.height + 48)
    }

    private var controls: some View {
        Form {
            Section("Variant") {
                Picker("Variant", selection: $variantName) {
                    ForEach(NightTimelineVariant.all) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                Text(variant.idea).font(.callout)
            }
            Section("Night") {
                Picker("Night", selection: $scenario) {
                    ForEach(NightAccountScenario.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                Toggle("Dark appearance", isOn: $darkAppearance)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("Playground") {
    NightTimelinePlayground()
}

#Preview("Close ups") {
    VStack(alignment: .leading, spacing: 28) {
        ForEach(NightTimelineVariant.all) { variant in
            VStack(alignment: .leading, spacing: 6) {
                Text(variant.name).font(.headline)
                NightStripHost(account: NightAccountScenario.hostCrash.account, variant: variant)
                    .clipShape(.rect(cornerRadius: variant.name == "J · Inline problems" ? 0 : 8))
                    .overlay {
                            if variant.name != "J · Inline problems" {
                                RoundedRectangle(cornerRadius: 8).strokeBorder(.separator)
                            }
                        }
            }
        }
    }
    .padding(24)
    .frame(width: nightStageSize.width - 240 - 320 + 48)
    .background(.windowBackground)
}
#endif
