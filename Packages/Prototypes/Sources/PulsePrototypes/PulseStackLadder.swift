#if DEBUG
import Domain
import Pulse
import SwiftUI

// "Stack Ladder": the Awaiting merge list drawn as a ladder. The top of the stack (Fm) is the top rung; each
// rung is joined to the one below by a short connector labelled with the repositories it is stacked on there;
// the bottom rung is marked "merges first". The ladder only reads U and inspects `.feature(id)`.

struct PulseStackLadder: View {
    let stack: UnmergedFeatureStack
    let context: PulseContext
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        // Bottom first in U, so the ladder reads it reversed: the top rung is the last Feature.
        let rungs = Array(stack.features.reversed())
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rungs.enumerated()), id: \.element.id) { index, feature in
                rung(feature, isBottom: index == rungs.count - 1)
                if index < rungs.count - 1 {
                    connector(from: feature, to: rungs[index + 1])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rung(_ feature: AwaitingMergeFeature, isBottom: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if isBottom {
                Label("merges first", systemImage: "arrow.down.to.line")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.landed)
            }
            PulseAwaitingRow(feature: feature, context: context, showsStackedOn: false)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.landed.opacity(isBottom ? 0.6 : 0.25)))
    }

    /// The connector between a rung and the one below it, labelled with the repositories the upper rung is
    /// stacked on the lower one in.
    private func connector(from upper: AwaitingMergeFeature, to lower: AwaitingMergeFeature) -> some View {
        let name = PulseStackText.name(lower)
        let repos = upper.repositories.filter { $0.stackedOn == name }.map(\.repo)
        return HStack(spacing: 8) {
            Rectangle().fill(palette.landed.opacity(0.5)).frame(width: 2, height: 22)
            Text(repos.isEmpty ? "no shared repository" : "on \(name) in \(repos.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 24)
    }
}

#Preview("Stack Ladder") {
    PulsePlayground(variant: "Stack Ladder", scenario: .landedMidNight)
}
#endif
