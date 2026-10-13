#if DEBUG
import SwiftUI

// The main window around a variant, drawn the way the app's landing screen draws it: the Sidebar with the
// Project selected, the centre column, and the Inspector. A variant fills the centre, the Inspector, or both;
// the stage draws the rest.

/// The main window's size in the 2026-10-12 screenshot.
let nightStageSize = CGSize(width: 1_420, height: 860)

struct NightAccountStage<Center: View, Inspector: View>: View {
    var inspectorWidth: CGFloat = 320
    @ViewBuilder let center: Center
    @ViewBuilder let inspector: Inspector

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 240)
            Divider()
            center.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            inspector
                .frame(width: inspectorWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(.background.secondary)
        }
        .frame(width: nightStageSize.width, height: nightStageSize.height)
        .background(.windowBackground)
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
            }
            .padding(.bottom, 18)
            Text("Projects").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Label("Yellowhammer", systemImage: "folder.fill")
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 6))
            Label("yellowhammer", systemImage: "shippingbox")
                .padding(.leading, 24)
            Spacer()
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary)
    }
}
#endif
