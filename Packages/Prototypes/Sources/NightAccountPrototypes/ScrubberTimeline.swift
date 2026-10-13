#if DEBUG
import Pulse
import SwiftUI

// C · Scrubber. The strip as a consumer-app scrubber, the way Photos and Podcasts scrub a clip: a track
// with a Liquid Glass thumb that carries the time, filled up to the playhead, with problems as marks on
// the track; under it the Acts as three thin ribbons, labelled lightly, and the Night's start and end at
// the corners with the hours between. Drag anywhere. Nothing is ringed: the needle alone says where you are.

struct ScrubberTimeline: View {
    let timeline: NightTimeline
    @Binding var playhead: Date

    private let labelWidth: CGFloat = 56
    private let thumbRowHeight: CGFloat = 34
    private let ribbonHeight: CGFloat = 10
    private let ribbonSpacing: CGFloat = 6
    private let axisHeight: CGFloat = 16
    private let thumbHalfWidth: CGFloat = 38

    private var scale: NightTimeScale { timeline.scale }
    private var lanes: [String?] { timeline.account.lanes }
    private var totalHeight: CGFloat {
        thumbRowHeight + CGFloat(lanes.count) * (ribbonHeight + ribbonSpacing) + axisHeight
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            labels
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        track(width: width)
                        ForEach(lanes, id: \.self) { act in
                            ribbon(act, width: width).padding(.bottom, ribbonSpacing)
                        }
                        axis(width: width)
                    }
                    needle(width: width)
                    thumb(width: width)
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        playhead = scale.date(at: drag.location.x, length: width)
                    }
                )
            }
        }
        .frame(height: totalHeight)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.background.secondary)
        .nightPlayheadAccessibility(timeline: timeline, playhead: $playhead)
    }

    private var labels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Color.clear.frame(height: thumbRowHeight)
            ForEach(lanes, id: \.self) { act in
                Text(NightAccount.laneLabel(act))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: ribbonHeight)
                    .padding(.bottom, ribbonSpacing)
            }
        }
        .frame(width: labelWidth, alignment: .trailing)
    }

    // MARK: Track, ribbons, axis

    private func track(width: CGFloat) -> some View {
        let mark = scale.position(playhead, length: width)
        return ZStack(alignment: .leading) {
            Capsule().fill(.quaternary).frame(height: 4)
            Capsule().fill(NightTheme.accent.opacity(0.55)).frame(width: max(mark, 0), height: 4)
            ForEach(Array(timeline.problemTimes.enumerated()), id: \.offset) { problem in
                Circle()
                    .fill(NightTheme.warning)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .offset(x: scale.position(problem.element, length: width) - 4.5)
            }
        }
        .frame(width: width, height: thumbRowHeight, alignment: .leading)
    }

    private func ribbon(_ act: String?, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(NightTheme.surface).frame(height: ribbonHeight)
            ForEach(timeline.runs(in: act, within: scale)) { run in
                let left = scale.position(run.startedAt, length: width)
                Capsule()
                    .fill(run.outcome.tint.opacity(run.outcome.isQuiet ? 0.4 : 0.9))
                    .frame(
                        width: max(ribbonHeight, scale.position(run.lastAt, length: width) - left), height: ribbonHeight
                    )
                    .overlay(Capsule().strokeBorder(NightTheme.warning, lineWidth: run.hasProblem ? 2 : 0))
                    .help("\(run.title) \u{2014} \(run.outcome.words)")
                    .offset(x: left)
            }
        }
        .frame(width: width, height: ribbonHeight, alignment: .leading)
    }

    private func axis(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(scale.ticks, id: \.self) { tick in
                let mark = scale.position(tick, length: width)
                if mark > 40, mark < width - 40 {
                    Text(tick.shortClock)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: mark, y: axisHeight / 2 + 1)
                }
            }
            Text(scale.start.shortClock)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(y: 2)
            Text(timeline.account.completedAt == nil ? "open" : scale.end.shortClock)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: width, alignment: .trailing)
                .offset(y: 2)
        }
        .frame(width: width, height: axisHeight, alignment: .topLeading)
    }

    // MARK: Needle and thumb

    private func needle(width: CGFloat) -> some View {
        Rectangle()
            .fill(NightTheme.accent)
            .frame(width: 1.5, height: totalHeight - axisHeight - thumbRowHeight / 2)
            .offset(x: scale.position(playhead, length: width) - 0.75, y: thumbRowHeight / 2)
            .allowsHitTesting(false)
    }

    /// The glass thumb, kept inside the strip while the needle keeps the true time.
    private func thumb(width: CGFloat) -> some View {
        let mark = scale.position(playhead, length: width)
        let centre = min(max(mark, thumbHalfWidth), max(width - thumbHalfWidth, thumbHalfWidth))
        return Text(playhead.clockTime)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .frame(width: thumbHalfWidth * 2, height: 24)
            .glassEffect(.regular.tint(NightTheme.accent.opacity(0.3)).interactive(), in: .capsule)
            .position(x: centre, y: thumbRowHeight / 2)
            .allowsHitTesting(false)
    }
}

#Preview("C · Scrubber") {
    NightTimelinePlayground(variant: "C \u{00B7} Scrubber")
}

#Preview("C · Scrubber, close up") {
    NightStripCloseUp(variant: "C \u{00B7} Scrubber")
}
#endif
