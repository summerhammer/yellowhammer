#if DEBUG
import Pulse
import SwiftUI

// The Night account prototyping harness. Debug builds only.
//
// - `NightAccountVariant.all` lists every way of reading a Night's account. A variant takes a `NightAccount`
//   and draws the whole main window through `NightAccountStage`, filling the centre column, the Inspector,
//   or both.
// - The "Playground" preview hosts one variant beside its controls: Variant, Night, appearance, and the
//   last way out a variant took. Each variant also has a preview of its own.
//
// Nothing here reads a Journal or runs `yh`: every Night is a `NightAccountScenario` fixture.

/// One way of reading a Night's account.
struct NightAccountVariant: Identifiable {
    let name: String
    /// What the variant is trying, in a line.
    let idea: String
    /// Where the account lives, and whether OQ158 item 14 allows it as ruled.
    let placement: String
    let make: (NightAccount) -> AnyView

    var id: String { name }

    init<Content: View>(
        _ name: String, idea: String, placement: String, @ViewBuilder make: @escaping (NightAccount) -> Content
    ) {
        self.name = name
        self.idea = idea
        self.placement = placement
        self.make = { AnyView(make($0)) }
    }

    static let all: [NightAccountVariant] = [
        NightAccountVariant(
            "Editor",
            idea: "Laid out like a video editor: a viewer with a large clock, Act tiles and a log; a transport "
                + "bar; the lanes docked at the bottom under a ruler",
            placement: "Centre column, in place of the Pulse. Needs OQ158 item 14 amended."
        ) { NightEditorVariant(account: $0).id($0.id) }
    ]
}

struct NightAccountPlayground: View {
    @State private var variantName: String
    @State private var scenario: NightAccountScenario
    @State private var darkAppearance = false
    @State private var lastWayOut: String?

    init(variant: String = NightAccountVariant.all[0].name, scenario: NightAccountScenario = .hostCrash) {
        _variantName = State(initialValue: variant)
        _scenario = State(initialValue: scenario)
    }

    private var variant: NightAccountVariant {
        NightAccountVariant.all.first { $0.name == variantName } ?? NightAccountVariant.all[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            variant.make(scenario.account)
                .environment(\.openNightDestination) { lastWayOut = $0.absoluteString }
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
                    ForEach(NightAccountVariant.all) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                Text(variant.idea).font(.callout)
                Text(variant.placement).font(.callout).foregroundStyle(.secondary)
            }
            Section("Night") {
                Picker("Night", selection: $scenario) {
                    ForEach(NightAccountScenario.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                Toggle("Dark appearance", isOn: $darkAppearance)
            }
            Section("Last way out") {
                Text(lastWayOut ?? "none yet").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("Playground") {
    NightAccountPlayground()
}
#endif
