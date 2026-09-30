#if DEBUG
import Domain
import SwiftUI

// Tinted cards under four different heads: the summary strip, a slim status band, the strip on the
// band, and a status pill beside the name. See `PulseSectionStyle`. Every head is fixed-size — nothing
// collapses — and each strip figure jumps to its group's card.

/// Tinted cards in the ruled order under a head, the head given a jump to any group's card.
private struct PulseTintedCardsScroll<Head: View>: View {
    let context: PulseContext
    /// Whether the head runs edge to edge (a band) or sits inside the cards' padding.
    var headBleeds = false
    @ViewBuilder let head: (_ jump: @escaping (PulseGroup) -> Void) -> Head

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let jump = { (group: PulseGroup) in withAnimation { proxy.scrollTo(group, anchor: .top) } }
                VStack(alignment: .leading, spacing: 0) {
                    if headBleeds { head(jump) }
                    VStack(alignment: .leading, spacing: 14) {
                        if !headBleeds { head(jump).padding(.bottom, 6) }
                        ForEach(PulseGroup.allCases) { group in
                            PulseTintedCard(group: group, context: context).id(group)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}

// MARK: - Strip over cards

struct PulseStripCardsSections: View {
    let context: PulseContext
    let showsHeader: Bool

    var body: some View {
        PulseTintedCardsScroll(context: context) { jump in
            VStack(alignment: .leading, spacing: 16) {
                if showsHeader { PulseHeader(project: context.project) }
                PulseSummaryStrip(context: context, jump: jump)
            }
        }
    }
}

// MARK: - Status band

/// A slim band tinted by the loudest state, extending under the Sidebar and Inspector. It carries the
/// name and the one line of overall status, and optionally the summary strip.
private struct PulseStatusBand<Below: View>: View {
    let context: PulseContext
    let showsName: Bool
    @ViewBuilder let below: Below
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        let mood = PulseMood(pulse: context.pulse, palette: palette)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: mood.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(mood.color.gradient, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    if showsName {
                        Text(context.project.name).font(.title.bold()).lineLimit(1)
                    }
                    Text(mood.line).font(showsName ? .callout : .title3.weight(.semibold))
                        .foregroundStyle(showsName ? .secondary : .primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(context.project.repos.count == 1 ? "1 Repo" : "\(context.project.repos.count) Repos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            below
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [mood.color.opacity(0.26), mood.color.opacity(0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .backgroundExtensionEffect()
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(mood.color.opacity(0.25)).frame(height: 1)
        }
    }
}

struct PulseBandCardsSections: View {
    let context: PulseContext
    let showsHeader: Bool

    var body: some View {
        PulseTintedCardsScroll(context: context, headBleeds: true) { _ in
            PulseStatusBand(context: context, showsName: showsHeader) { EmptyView() }
        }
    }
}

struct PulseBandStripCardsSections: View {
    let context: PulseContext
    let showsHeader: Bool

    var body: some View {
        PulseTintedCardsScroll(context: context, headBleeds: true) { jump in
            PulseStatusBand(context: context, showsName: showsHeader) {
                PulseSummaryStrip(context: context, background: .material, jump: jump)
            }
        }
    }
}

// MARK: - Status pill

/// The name with a pill tinted by the loudest state, over a strip whose figures wear their cards' tints.
struct PulsePillCardsSections: View {
    let context: PulseContext
    let showsHeader: Bool
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        PulseTintedCardsScroll(context: context) { jump in
            VStack(alignment: .leading, spacing: 16) {
                if showsHeader { head } else { pill }
                PulseSummaryStrip(context: context, background: .tinted, jump: jump)
            }
        }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(context.project.name).font(.largeTitle.bold()).lineLimit(2)
            HStack(spacing: 8) {
                pill
                Text(context.project.repos.count == 1 ? "1 Repo" : "\(context.project.repos.count) Repos")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pill: some View {
        let mood = PulseMood(pulse: context.pulse, palette: palette)
        return Label {
            Text(mood.line).fontWeight(.medium)
        } icon: {
            Image(systemName: mood.symbol).foregroundStyle(mood.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(mood.color.opacity(0.14), in: .capsule)
        .overlay(Capsule().strokeBorder(mood.color.opacity(0.35)))
    }
}

#endif
