import SwiftUI

/// A count or state on a neutral capsule, so a tint never carries the text's contrast.
struct PulseCountBadge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.quaternary, in: .capsule)
    }
}
