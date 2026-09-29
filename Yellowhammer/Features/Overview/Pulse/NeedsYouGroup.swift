import Pulse
import SwiftUI

/// The Pulse's Needs you group. This is a placeholder until P18.3 builds the group. It lists the
/// decision Cards, and each one opens in the Inspector.
struct NeedsYouGroup: View {
    let needsYou: NeedsYou
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if needsYou.cards.isEmpty {
                    Text("Nothing needs you")
                } else {
                    ForEach(needsYou.cards) { card in
                        Button("\(card.id) \(card.title)") { openDestination(.inspector(.card(card.id))) }
                            .buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Needs you", systemImage: "hand.raised")
        }
    }
}
