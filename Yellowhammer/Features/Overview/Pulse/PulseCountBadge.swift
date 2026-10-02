import SwiftUI

/// A count or state on a neutral capsule, so a style never carries the text's contrast.
struct PulseCountBadge<Style: ShapeStyle>: View {
    let text: String
    let style: Style

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(style).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.quaternary, in: .capsule)
    }
}
