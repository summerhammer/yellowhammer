#if DEBUG
import Domain
import SwiftUI

// The hero and rail section styles; see `PulseSectionStyle`.

// MARK: - Hero

struct PulseHeroSections: View {
    let context: PulseContext
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                banner
                VStack(alignment: .leading, spacing: 16) {
                    needsYouCallout
                    ForEach([PulseGroup.now, .feature, .night, .health]) { group in
                        GroupBox {
                            PulseGroupStack(group: group, context: context).padding(4)
                        } label: {
                            PulseGroupLabel(group: group)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var banner: some View {
        let mood = PulseMood(pulse: context.pulse, palette: palette)
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [mood.color.opacity(0.32), mood.color.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .backgroundExtensionEffect()
            Image(systemName: mood.symbol)
                .font(.system(size: 96))
                .foregroundStyle(mood.color.opacity(0.22))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(context.project.name).font(.largeTitle.bold()).lineLimit(2)
                Text(mood.line).font(.title3).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(height: 168)
    }

    @ViewBuilder
    private var needsYouCallout: some View {
        if context.pulse.needsYou.cards.isEmpty {
            GroupBox {
                PulseGroupStack(group: .needsYou, context: context).padding(4)
            } label: {
                PulseGroupLabel(group: .needsYou)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                PulseGroupLabel(group: .needsYou, font: .title3.weight(.semibold))
                PulseGroupStack(group: .needsYou, context: context)
            }
            .padding(14)
            .background(palette.needsYou.opacity(0.09), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.needsYou.opacity(0.3)))
        }
    }
}

/// The loudest thing true of the Project right now: Needs you over Working over the Now line. It picks
/// the colour, symbol and line of whatever colours the overall status.
struct PulseMood {
    let color: Color
    let symbol: String
    let line: String

    init(pulse: PulseSnapshot, palette: PulsePalette) {
        if !pulse.needsYou.cards.isEmpty {
            let count = pulse.needsYou.cards.count
            color = palette.needsYou
            symbol = "hand.raised.fill"
            line = count == 1 ? "1 Card needs you" : "\(count) Cards need you"
        } else if pulse.now.status == .working {
            color = palette.working
            symbol = "gearshape.2.fill"
            line = "Working — \(pulse.now.attempts.count) Attempts running"
        } else {
            color = palette.night
            symbol = "moon.stars.fill"
            line = PulseFormat.nowLine(pulse.now)
        }
    }
}

// MARK: - Rail

struct PulseRailSections: View {
    let context: PulseContext
    let showsHeader: Bool
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showsHeader { PulseHeader(project: context.project).padding(.bottom, 20) }
                ForEach(PulseGroup.allCases) { group in
                    HStack(alignment: .top, spacing: 14) {
                        rail(group)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(group.title).font(.headline)
                                Text(group.summary(of: context.project)).font(.caption).foregroundStyle(.secondary)
                            }
                            PulseGroupStack(group: group, context: context)
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
            .padding(20)
        }
    }

    private func rail(_ group: PulseGroup) -> some View {
        VStack(spacing: 4) {
            Image(systemName: group.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(palette.color(for: group), in: .circle)
            if group != .health {
                Rectangle().fill(.separator).frame(width: 2).frame(maxHeight: .infinity)
            }
        }
        .frame(width: 22)
    }
}
#endif
