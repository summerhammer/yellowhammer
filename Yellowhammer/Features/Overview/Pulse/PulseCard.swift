import Pulse
import SwiftUI

/// One Pulse group as a softly tinted card: an icon tile in the group's colour, the title, the group's
/// one-line summary, and the group's rows below.
struct PulseCard<Content: View>: View {
    let group: PulseGroup
    let summary: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: group.systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(group.onStyle)
                    .frame(width: 24, height: 24)
                    .background(group.style, in: .rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text(group.title).font(.headline)
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(group.style.opacity(0.07), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(group.style.opacity(0.22)))
        // A container, as the GroupBox it replaced was: without one, the group's identifier would
        // replace every row's own.
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Marks the row the Inspector shows, in the system accent that owns selection. The padding is
    /// applied whether or not the row is selected, so selecting it never moves it.
    func pulseRowHighlight(_ isSelected: Bool) -> some View {
        padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background {
                if isSelected { RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.16)) }
            }
            .contentShape(.rect)
    }
}
