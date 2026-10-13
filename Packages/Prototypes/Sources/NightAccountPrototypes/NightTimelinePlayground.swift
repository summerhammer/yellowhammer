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
            "B \u{00B7} Navigator",
            idea: "Two scales: a strip of the whole Night with a framed window, and the lanes at the "
                + "window's scale with every entry ticked on its bar. Night / 2 h / 30 min; drag the frame "
                + "to pan; the window follows the playhead"
        ) { NavigatorTimeline(timeline: $0, playhead: $1) }
        ,
        NightTimelineVariant(
            "C \u{00B7} Scrubber",
            idea: "A consumer scrubber: a glass thumb carrying the time on a track filled to the playhead, "
                + "problems as marks on the track, the Acts as thin ribbons under it, start and end at the "
                + "corners. Drag anywhere; nothing is ringed"
        ) { ScrubberTimeline(timeline: $0, playhead: $1) }
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
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
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
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }
        }
    }
    .padding(24)
    .frame(width: nightStageSize.width - 240 - 320 + 48)
    .background(.windowBackground)
}
#endif
