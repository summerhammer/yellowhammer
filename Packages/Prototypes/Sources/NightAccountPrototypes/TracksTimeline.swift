#if DEBUG
import Pulse
import SwiftUI

// A · Tracks. The strip as a pro-app track area, the way Instruments and Logic draw one: a header column
// names each track and sums it up, the ruler carries its own labels so there is one time axis, not two,
// the playhead wears a flag with the exact time, and problems are flagged on the ruler. Click or drag
// anywhere in the tracks to move the playhead; hovering shows a hairline with the time under the pointer.

struct TracksTimeline: View {
    let timeline: NightTimeline
    @Binding var playhead: Date
    @State private var hoverTime: Date?

    private let headerWidth: CGFloat = 124
    private let rulerHeight: CGFloat = 30
    private let trackHeight: CGFloat = 32
    private let flagWidth: CGFloat = 62

    private var scale: NightTimeScale { timeline.scale }
    private var lanes: [String?] { timeline.account.lanes }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            headers
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ruler(width: width)
                        ForEach(Array(lanes.enumerated()), id: \.offset) { index, act in
                            track(act, index: index, width: width)
                        }
                    }
                    if let hoverTime { hoverMark(hoverTime, width: width) }
                    playheadMark(width: width)
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        playhead = scale.date(at: drag.location.x, length: width)
                    }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverTime = scale.date(at: point.x, length: width)
                    case .ended: hoverTime = nil
                    }
                }
            }
        }
        .frame(height: rulerHeight + trackHeight * CGFloat(lanes.count))
        .background(.background)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.background.secondary)
        .nightPlayheadAccessibility(timeline: timeline, playhead: $playhead)
    }

    // MARK: Headers

    private var headers: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(scale.words)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .frame(width: headerWidth, height: rulerHeight, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
            ForEach(Array(lanes.enumerated()), id: \.offset) { index, act in
                header(act, index: index)
            }
        }
        .frame(width: headerWidth)
        .overlay(alignment: .trailing) { Rectangle().fill(.separator).frame(width: 1) }
    }

    private func header(_ act: String?, index: Int) -> some View {
        let runs = timeline.account.runs.filter { $0.act == act }
        let problems = runs.reduce(0) { $0 + $1.problemCount }
        return VStack(alignment: .leading, spacing: 1) {
            Text(NightAccount.laneLabel(act)).font(.callout.weight(.medium))
            Text(summary(runs: runs.count, problems: problems)).font(.caption2).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(width: headerWidth, height: trackHeight, alignment: .leading)
        .background(index.isMultiple(of: 2) ? Color.clear : NightTheme.surface)
    }

    private func summary(runs: Int, problems: Int) -> String {
        let runWords = runs == 1 ? "1 run" : "\(runs) runs"
        switch problems {
        case 0: return runWords
        case 1: return "\(runWords) \u{00B7} 1 problem"
        default: return "\(runWords) \u{00B7} \(problems) problems"
        }
    }

    // MARK: Ruler and tracks

    private func ruler(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(scale.quarterHours, id: \.self) { tick in
                let onHour = Calendar.current.component(.minute, from: tick) == 0
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 1, height: onHour ? 8 : 4)
                    .offset(x: scale.position(tick, length: width), y: rulerHeight - (onHour ? 8 : 4))
            }
            ForEach(scale.ticks, id: \.self) { tick in
                let mark = scale.position(tick, length: width)
                if mark < width - 44 {
                    Text(tick.shortClock)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: mark + 4, y: 15)
                }
            }
            ForEach(Array(timeline.problemTimes.enumerated()), id: \.offset) { problem in
                NightProblemMark(size: 10)
                    .offset(x: scale.position(problem.element, length: width) - 6, y: 3)
            }
        }
        .frame(width: width, height: rulerHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
    }

    private func track(_ act: String?, index: Int, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(timeline.runs(in: act, within: scale)) { run in
                bar(run, width: width)
            }
        }
        .frame(width: width, height: trackHeight, alignment: .leading)
        .background(index.isMultiple(of: 2) ? Color.clear : NightTheme.surface)
        .clipped()
    }

    private func bar(_ run: NightAccount.ActRun, width: CGFloat) -> some View {
        let quiet = run.outcome.isQuiet
        let left = scale.position(run.startedAt, length: width)
        let barWidth = max(quiet ? 6 : 10, scale.position(run.lastAt, length: width) - left)
        let height: CGFloat = quiet ? 8 : 20
        let radius: CGFloat = quiet ? 2 : 4
        return RoundedRectangle(cornerRadius: radius)
            .fill(run.outcome.tint.opacity(quiet ? 0.45 : run.contains(playhead) ? 1 : 0.85))
            .frame(width: barWidth, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(NightTheme.warning, lineWidth: run.hasProblem ? 2 : 0)
            )
            .overlay(alignment: .leading) {
                if barWidth >= 56, !quiet {
                    Text(run.outcome.shortWords)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
            }
            .help("\(run.title) \u{2014} \(run.outcome.words)")
            .offset(x: left)
    }

    // MARK: Marks

    private func playheadMark(width: CGFloat) -> some View {
        let mark = scale.position(playhead, length: width)
        let flagOnLeft = mark + flagWidth + 2 > width
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(NightTheme.accent)
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .offset(x: mark - 0.75)
            Text(playhead.clockTime)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: flagWidth, height: 14)
                .background(
                    NightTheme.accent,
                    in: .rect(
                        topLeadingRadius: flagOnLeft ? 4 : 0,
                        bottomLeadingRadius: flagOnLeft ? 4 : 0,
                        bottomTrailingRadius: flagOnLeft ? 0 : 4,
                        topTrailingRadius: flagOnLeft ? 0 : 4
                    )
                )
                .offset(x: flagOnLeft ? mark - flagWidth : mark, y: 2)
        }
        .frame(width: width, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func hoverMark(_ time: Date, width: CGFloat) -> some View {
        let mark = scale.position(time, length: width)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.secondary.opacity(0.5))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .offset(x: mark)
            Text(time.shortClock)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.background, in: .rect(cornerRadius: 3))
                .offset(x: mark + 3, y: rulerHeight + 3)
        }
        .frame(width: width, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

#Preview("A · Tracks") {
    NightTimelinePlayground(variant: "A \u{00B7} Tracks")
}

#Preview("A · Tracks, close up") {
    NightStripCloseUp(variant: "A \u{00B7} Tracks")
}
#endif
