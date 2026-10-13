#if DEBUG
import Pulse
import SwiftUI

// The Night's lanes, which every playhead design draws: one per Act, each run a bar from its first entry to
// its last, coloured by how it ended, problems ringed.

/// What a bar's colour and ring mean.
struct NightLaneLegend: View {
    private static let outcomes: [NightAccount.RunOutcome] = [
        .ended, .idle(reason: ""), .stoodDown, .incomplete(reason: ""), .notEnded
    ]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Self.outcomes, id: \.words) { outcome in
                item(outcome.shortWords, systemImage: "circle.fill", tint: outcome.tint)
            }
            item("problem", systemImage: "circle", tint: NightTheme.attention)
        }
        .font(.caption)
    }

    private func item(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).imageScale(.small).foregroundStyle(tint)
            Text(title)
        }
    }
}

/// Lanes for Author, Build and Land, and one for unstamped events when there are any, under a time axis.
/// Each run is a bar from its first entry to its last, coloured by how it ended, problems ringed. Every
/// timeline variant draws these, at its own size and over its own stretch of the Night.
struct NightLanes: View {
    let account: NightAccount
    @Binding var selection: NightAccount.ActRun.ID?
    var scale: NightTimeScale
    var laneHeight: CGFloat
    var labelWidth: CGFloat
    /// Marks every entry on its run's bar, for a scale short enough to tell them apart.
    var showsEntries: Bool

    init(
        account: NightAccount,
        selection: Binding<NightAccount.ActRun.ID?>,
        scale: NightTimeScale? = nil,
        laneHeight: CGFloat = 34,
        labelWidth: CGFloat = 64,
        showsEntries: Bool = false
    ) {
        self.account = account
        _selection = selection
        self.scale = scale ?? NightTimeScale(account: account)
        self.laneHeight = laneHeight
        self.labelWidth = labelWidth
        self.showsEntries = showsEntries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(account.lanes, id: \.self) { act in
                HStack(spacing: 0) {
                    // A design that draws the lanes as a thin picture gives them no labels.
                    if labelWidth > 0 {
                        Text(act.map { $0.capitalized } ?? "No Act")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .leading)
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.separator).frame(height: 1)
                            ForEach(account.runs.filter { $0.act == act && scale.overlaps($0) }) { run in
                                bar(run, width: geometry.size.width)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: laneHeight)
                    // A zoomed scale cuts the runs that reach past it at its edges.
                    .clipped()
                }
            }
            axis.padding(.leading, labelWidth)
        }
    }

    private func bar(_ run: NightAccount.ActRun, width: CGFloat) -> some View {
        let left = scale.position(run.startedAt, length: width)
        let barWidth = max(10, scale.position(run.lastAt, length: width) - left)
        let isSelected = selection == run.id
        let height: CGFloat = run.outcome.isQuiet ? 10 : showsEntries ? 20 : 16
        return Button {
            selection = run.id
        } label: {
            Capsule()
                .fill(run.outcome.tint.opacity(run.outcome.isQuiet ? 0.45 : 0.9))
                .overlay(Capsule().strokeBorder(NightTheme.attention, lineWidth: run.hasProblem ? 2.5 : 0))
                .overlay(alignment: .leading) {
                    if showsEntries { entryMarks(run, left: left, width: width) }
                }
                .overlay(Capsule().strokeBorder(.primary, lineWidth: isSelected ? 2 : 0).padding(-3))
                .frame(width: barWidth, height: height)
        }
        .buttonStyle(.plain)
        .help("\(run.title) \u{2014} \(run.outcome.words)")
        .accessibilityLabel("\(run.title), \(run.outcome.words)\(run.hasProblem ? ", has a problem" : "")")
        .offset(x: left)
    }

    /// A dot for every entry, a warning sign for a problem, placed at its time along the bar.
    private func entryMarks(_ run: NightAccount.ActRun, left: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(run.entries) { entry in
                Group {
                    if entry.isProblem {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white, NightTheme.attention)
                    } else {
                        Circle().fill(.white.opacity(0.85)).frame(width: 4, height: 4)
                    }
                }
                .frame(width: 12)
                .offset(x: scale.position(entry.occurredAt, length: width) - left - 6)
                .help("\(entry.time) \u{2014} \(entry.headline)")
            }
        }
    }

    private var axis: some View {
        GeometryReader { geometry in
            ForEach(scale.ticks, id: \.self) { tick in
                Text(tick.formatted(.dateTime.hour().minute()))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: scale.position(tick, length: geometry.size.width), y: 6)
            }
        }
        .frame(height: 14)
    }
}

#endif
