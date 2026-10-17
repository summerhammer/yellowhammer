import Pulse
import SwiftUI

/// The Night's tracks docked flush at the bottom of the editor: a header column names each Act and sums it
/// up, a ruler over the tracks carries the time labels and flags each problem, and the playhead is a line
/// through the tracks wearing a flag with the exact time. Click or drag anywhere in the tracks to move the
/// playhead; hovering shows a hairline with the time under the pointer. The ruler is also an adjustable
/// element for VoiceOver, five minutes a step.
struct NightEditorTimeline: View {
    let timeline: NightTimeline
    @Binding var playhead: Date
    @State private var hoverTime: Date?
    private let rulerTicks: [RulerTick]
    private let axisTicks: [Date]
    private let headers: [Header]

    private let headerWidth: CGFloat = 150
    private let rulerHeight: CGFloat = 30
    private let trackHeight: CGFloat = 32
    private let flagWidth: CGFloat = 62

    /// A tick on the ruler: taller on the hour.
    private struct RulerTick: Identifiable {
        let date: Date
        let isOnHour: Bool
        var id: Date { date }
    }

    /// An Act's header: its name, and how many runs and problems it had.
    private struct Header: Identifiable {
        let act: String?
        let summary: String
        var id: String { act ?? "" }
    }

    /// The ticks and headers depend on the Night alone, never on the playhead: worked out here, once per pass.
    init(timeline: NightTimeline, playhead: Binding<Date>) {
        self.timeline = timeline
        _playhead = playhead
        rulerTicks = timeline.scale.quarterHours.map {
            RulerTick(date: $0, isOnHour: Calendar.current.component(.minute, from: $0) == 0)
        }
        axisTicks = timeline.scale.ticks
        headers = timeline.account.lanes.map { act in
            let runs = timeline.account.runs.filter { $0.act == act }
            let problems = runs.reduce(0) { $0 + $1.problemCount }
            return Header(act: act, summary: Self.summary(runs: runs.count, problems: problems))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            headerColumn
            GeometryReader { geometry in
                let width = geometry.size.width
                let scale = timeline.scale
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ruler(width: width)
                        NightLanes(
                            timeline: timeline,
                            selection: timeline.moment(at: playhead).runUnderPlayhead?.id,
                            trackHeight: trackHeight,
                            width: width,
                            select: { playhead = $0.startedAt }
                        )
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
        .frame(height: rulerHeight + trackHeight * CGFloat(headers.count))
        .background(.background.secondary)
    }

    // MARK: Headers

    private var headerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(timeline.scale.words)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .frame(width: headerWidth, height: rulerHeight, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
            ForEach(Array(headers.enumerated()), id: \.element.id) { index, header in
                VStack(alignment: .leading, spacing: 1) {
                    Text(header.act.map { $0.capitalized } ?? "No Act").font(.callout.weight(.medium))
                    Text(header.summary).font(.caption2).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(width: headerWidth, height: trackHeight, alignment: .leading)
                .background(index.isMultiple(of: 2) ? AnyShapeStyle(.clear) : AnyShapeStyle(.surface))
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: headerWidth)
        .overlay(alignment: .trailing) { Rectangle().fill(.separator).frame(width: 1) }
    }

    private static func summary(runs: Int, problems: Int) -> String {
        let runWords = runs == 1 ? "1 run" : "\(runs) runs"
        switch problems {
        case 0: return runWords
        case 1: return "\(runWords) \u{00B7} 1 problem"
        default: return "\(runWords) \u{00B7} \(problems) problems"
        }
    }

    // MARK: Ruler

    private func ruler(width: CGFloat) -> some View {
        let scale = timeline.scale
        return ZStack(alignment: .topLeading) {
            ForEach(rulerTicks) { tick in
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 1, height: tick.isOnHour ? 8 : 4)
                    .offset(x: scale.position(tick.date, length: width), y: rulerHeight - (tick.isOnHour ? 8 : 4))
            }
            ForEach(axisTicks, id: \.self) { tick in
                let mark = scale.position(tick, length: width)
                if mark < width - 44 {
                    Text(tick.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: mark + 4, y: 15)
                }
            }
            ForEach(Array(timeline.problemTimes.enumerated()), id: \.offset) { problem in
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black.opacity(0.75), .warning)
                    .offset(x: scale.position(problem.element, length: width) - 6, y: 3)
            }
        }
        .frame(width: width, height: rulerHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue(playhead.formatted(.dateTime.hour().minute()))
        .accessibilityAdjustableAction { direction in
            playhead = timeline.moment(at: playhead).moved(by: direction == .increment ? 300 : -300)
        }
        .accessibilityIdentifier("night-account-playhead")
    }

    // MARK: Marks

    /// The playhead through the ruler and the tracks, its flag on the ruler, turned to the left of the line
    /// when there is no room for it on the right.
    private func playheadMark(width: CGFloat) -> some View {
        let mark = timeline.scale.position(playhead, length: width)
        let flagOnLeft = mark + flagWidth + 2 > width
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.accent)
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .offset(x: mark - 0.75)
            Text(playhead.nightClock)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: flagWidth, height: 14)
                .background(
                    .accent,
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
        .accessibilityHidden(true)
    }

    /// A hairline at the time under the pointer, labelled just under the ruler.
    private func hoverMark(_ time: Date, width: CGFloat) -> some View {
        let mark = timeline.scale.position(time, length: width)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.secondary.opacity(0.5))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .offset(x: mark)
            Text(time.formatted(.dateTime.hour().minute()))
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
        .accessibilityHidden(true)
    }
}
