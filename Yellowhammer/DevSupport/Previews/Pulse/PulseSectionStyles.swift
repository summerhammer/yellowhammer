#if DEBUG
import Domain
import SwiftUI

// The ways the main area can lay out the five groups. Every style keeps the ruled order
// (Needs you → Now → Feature → Tonight / last Night → Health), heads the area with the Project's name,
// and reuses `PulseGroupRows`, so only the container and the emphasis change between styles.

enum PulseSectionStyle: String, CaseIterable {
    /// A grouped `Form`, like System Settings.
    case grouped
    /// Needs you full width, the other four as tiles in an adaptive grid.
    case dashboard
    /// Each group a softly tinted card with a System Settings–style icon.
    case tinted
    /// An inset `List` with section headers, like Mail or Reminders.
    case list
    /// A strip of five figures on top that scroll to the detail below.
    case summaryStrip
    /// Collapsible disclosure groups whose labels carry the group's summary.
    case disclosure
    /// A tinted banner that extends under the sidebar and inspector, and a Needs you callout.
    case hero
    /// A vertical rail with a coloured node per group.
    case rail
    /// The summary strip over tinted cards.
    case stripCards
    /// A slim band tinted by the loudest state over tinted cards.
    case bandCards
    /// The slim band carrying the summary strip, over tinted cards.
    case bandStripCards
    /// A status pill beside the name and a tinted strip, over tinted cards.
    case pillCards
}

struct PulseSectionsView: View {
    let context: PulseContext
    let style: PulseSectionStyle
    var showsHeader = true

    var body: some View {
        switch style {
        case .grouped: PulseGroupedSections(context: context, showsHeader: showsHeader)
        case .dashboard: PulseDashboardSections(context: context, showsHeader: showsHeader)
        case .tinted: PulseTintedSections(context: context, showsHeader: showsHeader)
        case .list: PulseListSections(context: context, showsHeader: showsHeader)
        case .summaryStrip: PulseSummaryStripSections(context: context, showsHeader: showsHeader)
        case .disclosure: PulseDisclosureSections(context: context, showsHeader: showsHeader)
        case .hero: PulseHeroSections(context: context)
        case .rail: PulseRailSections(context: context, showsHeader: showsHeader)
        case .stripCards: PulseStripCardsSections(context: context, showsHeader: showsHeader)
        case .bandCards: PulseBandCardsSections(context: context, showsHeader: showsHeader)
        case .bandStripCards: PulseBandStripCardsSections(context: context, showsHeader: showsHeader)
        case .pillCards: PulsePillCardsSections(context: context, showsHeader: showsHeader)
        }
    }
}

/// A group's rows stacked, for the styles that are not a `Form` or `List`.
struct PulseGroupStack: View {
    let group: PulseGroup
    let context: PulseContext
    var spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            PulseGroupRows(group: group, context: context)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Grouped form

private struct PulseGroupedSections: View {
    let context: PulseContext
    let showsHeader: Bool

    var body: some View {
        Form {
            if showsHeader {
                Section { PulseHeader(project: context.project) }
            }
            ForEach(PulseGroup.allCases) { group in
                Section {
                    PulseGroupRows(group: group, context: context)
                } header: {
                    PulseGroupLabel(group: group, font: .headline)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dashboard

private struct PulseDashboardSections: View {
    let context: PulseContext
    let showsHeader: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if showsHeader { PulseHeader(project: context.project).padding(.bottom, 8) }
                tile(.needsYou)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach([PulseGroup.now, .feature, .night, .health]) { tile($0) }
                }
            }
            .padding(20)
        }
    }

    private func tile(_ group: PulseGroup) -> some View {
        PulseTile(group: group, summary: group.summary(of: context.project)) {
            PulseGroupStack(group: group, context: context)
        }
    }
}

private struct PulseTile<Content: View>: View {
    let group: PulseGroup
    let summary: String
    @ViewBuilder let content: Content
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PulseGroupLabel(group: group)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(palette.surface, in: .rect(cornerRadius: 12))
    }
}

// MARK: - Tinted cards

private struct PulseTintedSections: View {
    let context: PulseContext
    let showsHeader: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if showsHeader { PulseHeader(project: context.project).padding(.bottom, 6) }
                ForEach(PulseGroup.allCases) { group in
                    PulseTintedCard(group: group, context: context)
                }
            }
            .padding(20)
        }
    }
}

/// One group as a softly tinted card with a System Settings–style icon.
struct PulseTintedCard: View {
    let group: PulseGroup
    let context: PulseContext
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        let color = palette.color(for: group)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: group.systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(color.gradient, in: .rect(cornerRadius: 6))
                Text(group.title).font(.headline)
                Spacer()
                Text(group.summary(of: context.project)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            PulseGroupStack(group: group, context: context)
        }
        .padding(14)
        .background(color.opacity(0.07), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.22)))
    }
}

// MARK: - List

private struct PulseListSections: View {
    let context: PulseContext
    let showsHeader: Bool

    var body: some View {
        List {
            if showsHeader {
                PulseHeader(project: context.project)
                    .padding(.vertical, 8)
                    .listRowSeparator(.hidden)
            }
            ForEach(PulseGroup.allCases) { group in
                Section {
                    PulseGroupRows(group: group, context: context)
                } header: {
                    HStack {
                        PulseGroupLabel(group: group, font: .subheadline.weight(.semibold))
                        Spacer()
                        Text(group.summary(of: context.project)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - Summary strip

private struct PulseSummaryStripSections: View {
    let context: PulseContext
    let showsHeader: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if showsHeader { PulseHeader(project: context.project) }
                    PulseSummaryStrip(context: context) { group in
                        withAnimation { proxy.scrollTo(group, anchor: .top) }
                    }
                    ForEach(PulseGroup.allCases) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title).font(.title3.weight(.semibold))
                            PulseGroupStack(group: group, context: context)
                        }
                        .id(group)
                        if group != .health { Divider() }
                    }
                }
                .padding(20)
            }
        }
    }
}

/// How a summary strip's figures are drawn.
enum PulseFigureBackground {
    /// The neutral surface.
    case surface
    /// A wash of the group's colour, matching the tinted cards.
    case tinted
    /// Glass-like material, for a strip laid over a coloured band.
    case material
}

/// Five figures, one per group, each a button that jumps to the group's detail.
struct PulseSummaryStrip: View {
    let context: PulseContext
    var background: PulseFigureBackground = .surface
    let jump: (PulseGroup) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PulseGroup.allCases) { group in
                Button { jump(group) } label: {
                    PulseSummaryFigure(group: group, context: context, background: background)
                }
                .buttonStyle(.plain)
                .help("Jump to \(group.title)")
            }
        }
    }
}

struct PulseSummaryFigure: View {
    let group: PulseGroup
    let context: PulseContext
    var background: PulseFigureBackground = .surface
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        let (value, caption) = Self.text(group, pulse: context.pulse)
        let color = palette.color(for: group)
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(group == .night ? "Night" : group.title)
            } icon: {
                Image(systemName: group.systemImage).foregroundStyle(color)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        // A zero minimum width: a scaling or unbounded minimum here makes the split view renegotiate
        // the detail column's minimum size without end.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background { backgroundShape(color) }
        .contentShape(.rect)
    }

    @ViewBuilder
    private func backgroundShape(_ color: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        switch background {
        case .surface: shape.fill(palette.surface)
        case .tinted: shape.fill(color.opacity(0.09)).overlay(shape.strokeBorder(color.opacity(0.22)))
        case .material: shape.fill(.regularMaterial)
        }
    }

    static func text(_ group: PulseGroup, pulse: PulseSnapshot) -> (String, String) {
        switch group {
        case .needsYou:
            let caption = pulse.needsYou.cards.isEmpty ? "nothing needs you" : "Cards need you"
            return ("\(pulse.needsYou.cards.count)", caption)
        case .now:
            if pulse.now.attempts.isEmpty {
                return (pulse.now.status.rawValue, PulseFormat.nextAct(pulse.now) ?? "no Act scheduled")
            }
            return ("\(pulse.now.attempts.count)", "Attempts running")
        case .feature:
            guard let feature = pulse.feature else { return ("—", "no Feature in flight") }
            let progress = PulseFormat.cardProgress(feature)
            return ("\(progress.done)/\(progress.total)", "Cards · \(feature.rollupState.rawValue)")
        case .night:
            guard let night = pulse.night else { return ("—", "no Night yet") }
            return (night.state.rawValue, "started \(PulseFormat.time(night.startedAt))")
        case .health:
            return pulse.health.isEmpty ? ("OK", "doctor raised nothing") : ("\(pulse.health.count)", "doctor flags")
        }
    }
}

// MARK: - Disclosure

private struct PulseDisclosureSections: View {
    let context: PulseContext
    let showsHeader: Bool
    @State private var expanded = Set(PulseGroup.allCases)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if showsHeader { PulseHeader(project: context.project).padding(.bottom, 4) }
                ForEach(PulseGroup.allCases) { group in
                    DisclosureGroup(isExpanded: isExpanded(group)) {
                        PulseGroupStack(group: group, context: context)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    } label: {
                        HStack {
                            PulseGroupLabel(group: group)
                            Spacer()
                            Text(group.summary(of: context.project)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
            }
            .padding(20)
        }
    }

    private func isExpanded(_ group: PulseGroup) -> Binding<Bool> {
        Binding {
            expanded.contains(group)
        } set: { isOn in
            if isOn { expanded.insert(group) } else { expanded.remove(group) }
        }
    }
}
#endif
