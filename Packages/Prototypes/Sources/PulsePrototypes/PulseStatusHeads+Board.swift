#if DEBUG
import Domain
import Pulse
import SwiftUI

// A board comparing the status heads, and a preview per head; see `PulseStatusHead`.

/// Every head stacked for one scenario, without the split view, so they can be compared side by side.
struct PulseStatusHeadBoard: View {
    @State private var scenario: PulseScenario = .morningTriage
    @State private var darkAppearance = false
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        let snapshot = scenario.snapshot
        let actions = PulseActions(inspected: nil, inspect: { _ in }, open: { _ in })
        VStack(spacing: 0) {
            HStack {
                Picker("Scenario", selection: $scenario) {
                    ForEach(PulseScenario.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Toggle("Dark appearance", isOn: $darkAppearance)
                Spacer()
            }
            .padding(12)
            Divider()
            if let project = snapshot.project(scenario.focus) {
                let context = PulseContext(project: project, asOf: snapshot.asOf, actions: actions)
                let condition = PulseCondition(project: project, palette: palette)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(PulseStatusHead.allCases) { head in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(head.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding([.horizontal, .top], 8)
                                PulseStatusHeadView(head: head, context: context, condition: condition) { _ in }
                            }
                            .background(.background)
                            .clipShape(.rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 900)
        .preferredColorScheme(darkAppearance ? .dark : .light)
    }
}

#Preview("Status Heads — compare") {
    PulseStatusHeadBoard()
}

#Preview("Pixel Fade") {
    PulsePlayground(variant: "Pixel Fade", scenario: .nightRunning)
}

#Preview("Mesh Aurora") {
    PulsePlayground(variant: "Mesh Aurora", scenario: .morningTriage)
}

#Preview("Mesh Mist") {
    PulsePlayground(variant: "Mesh Mist", scenario: .morningTriage)
}

#Preview("Spectrum") {
    PulsePlayground(variant: "Spectrum", scenario: .stress)
}

#endif
