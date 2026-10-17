#if DEBUG
import Pulse
import SwiftUI

// A · Tracks. The strip as a pro-app track area, the way Instruments and Logic draw one: a header column
// names each track and sums it up, the ruler carries its own labels so there is one time axis, not two,
// the playhead wears a flag with the exact time, and problems are flagged on the ruler. Click or drag
// anywhere in the tracks to move the playhead; hovering shows a hairline with the time under the pointer.

// Throwaway studies derived from A. Keep A unchanged as the comparison baseline.
enum TrackStudy: String, CaseIterable {
    case compact, expanded, grid, outline, entries, problems, focus, bottomRuler, inlineProblems
}

struct TracksStudyTimeline: View {
    let study: TrackStudy
    @State private var focusedAct = "build"
    let timeline: NightTimeline
    @Binding var playhead: Date
    @State private var hoverTime: Date?
    @State private var selectedRun: NightAccount.ActRun?

    private var isInline: Bool { study == .inlineProblems }

    private var headerWidth: CGFloat { study == .compact ? 100 : 150 }
    private let rulerHeight: CGFloat = 30
    private var trackHeight: CGFloat {
        switch study {
        case .compact: 24
        case .expanded, .entries: 52
        case .focus: 44
        default: 32
        }
    }
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
                        if study != .bottomRuler { ruler(width: width) }
                        ForEach(Array(lanes.enumerated()), id: \.offset) { index, act in
                            track(act, index: index, width: width)
                        }
                        if study == .bottomRuler { ruler(width: width) }
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
        .clipShape(.rect(cornerRadius: isInline ? 0 : 8))
        .overlay {
            if !isInline { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
        }
        .padding(.horizontal, isInline ? 0 : 20)
        .padding(.vertical, isInline ? 0 : 12)
        .background(.background.secondary)
        .nightPlayheadAccessibility(timeline: timeline, playhead: $playhead)
    }

    // MARK: Headers

    private var headers: some View {
        VStack(alignment: .leading, spacing: 0) {
            if study != .bottomRuler { headerRuler }
            ForEach(Array(lanes.enumerated()), id: \.offset) { index, act in
                if study == .focus {
                    Button { focusedAct = act ?? "none" } label: { header(act, index: index) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(focusedAct == (act ?? "none") ? .isSelected : [])
                } else {
                    header(act, index: index)
                }
            }
            if study == .bottomRuler { headerRuler }
        }
        .frame(width: headerWidth)
        .overlay(alignment: .trailing) { Rectangle().fill(.separator).frame(width: 1) }
    }

    private var headerRuler: some View {
        Text(scale.words)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .frame(width: headerWidth, height: rulerHeight, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
    }

    private func header(_ act: String?, index: Int) -> some View {
        let runs = timeline.account.runs.filter { $0.act == act }
        let problems = runs.reduce(0) { $0 + $1.problemCount }
        return VStack(alignment: .leading, spacing: 1) {
            Text(NightAccount.laneLabel(act)).font(.callout.weight(.medium))
            if study != .compact {
                Text(summary(runs: runs.count, problems: problems)).font(.caption2).foregroundStyle(.secondary)
            }
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
            if study == .grid {
                ForEach(scale.quarterHours, id: \.self) { tick in
                    Rectangle().fill(.separator.opacity(0.5))
                        .frame(width: 1, height: trackHeight)
                        .offset(x: scale.position(tick, length: width))
                }
            }
            if study == .outline {
                Rectangle().fill(.separator).frame(height: 1)
            }
            ForEach(timeline.runs(in: act, within: scale)) { run in
                bar(run, width: width)
                    .opacity((study == .problems || isInline) && !run.hasProblem
                        && !(isInline && selectedRun?.id == run.id) ? 0.22 : 1)
                    .opacity(study == .focus && (act ?? "none") != focusedAct ? 0.2 : 1)
            }
        }
        .frame(width: width, height: trackHeight, alignment: .leading)
        .background(index.isMultiple(of: 2) ? Color.clear : NightTheme.surface)
        .clipped()
    }

    private func bar(_ run: NightAccount.ActRun, width: CGFloat) -> some View {
        let quiet = run.outcome.isQuiet
        let left = scale.position(run.startedAt, length: width)
        let barWidth = max(isInline ? 12 : quiet ? 6 : 10, scale.position(run.lastAt, length: width) - left)
        let height: CGFloat = isInline ? trackHeight - 4
            : quiet ? 6 : study == .expanded ? 34 : study == .compact ? 12 : 20
        let radius: CGFloat = quiet ? 2 : 4
        return RoundedRectangle(cornerRadius: radius)
            .fill(isInline ? inlineTint(run)
                : run.outcome.tint.opacity(study == .outline ? 0.08 : quiet ? 0.45 : run.contains(playhead) ? 1 : 0.85))
            .frame(width: barWidth, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        isInline ? NightTheme.accent : run.hasProblem ? NightTheme.warning : run.outcome.tint,
                        lineWidth: isInline ? (selectedRun?.id == run.id ? 2 : 0)
                            : run.hasProblem || study == .outline ? 2 : 0
                    )
            )
            .overlay(alignment: .leading) {
                if barWidth >= 56, !quiet, study != .compact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.outcome.shortWords)
                        if study == .expanded {
                            Text("\(run.startedAt.shortClock) – \(run.lastAt.shortClock)")
                                .font(.caption2).monospacedDigit()
                        }
                    }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isInline && run.hasProblem ? Color.black
                            : study == .outline ? run.outcome.tint : .white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
            }
            .overlay(alignment: .topLeading) {
                if study == .entries {
                    ForEach(run.entries) { entry in
                        Circle()
                            .fill(entry.isProblem ? NightTheme.warning : run.outcome.tint)
                            .frame(width: 5, height: 5)
                            .offset(x: scale.position(entry.occurredAt, length: width) - left, y: 25)
                            .help(entry.headline)
                    }
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                if isInline { selectedRun = run }
            })
            .help("\(run.title) \u{2014} \(run.outcome.words)")
            .offset(x: left)
    }

    // Failure takes precedence over warning when a run has both.
    private func inlineTint(_ run: NightAccount.ActRun) -> Color {
        if case .incomplete = run.outcome { return NightTheme.error }
        return run.hasProblem ? NightTheme.warning : run.outcome.tint
    }
}

private extension TracksStudyTimeline {
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
                .offset(x: flagOnLeft ? mark - flagWidth : mark,
                        y: study == .bottomRuler ? trackHeight * CGFloat(lanes.count) + 2 : 2)
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

#Preview("J · Inline problems") {
    NightTimelinePlayground(variant: "J · Inline problems")
}

#Preview("J · Inline problems, close up") {
    NightStripCloseUp(variant: "J · Inline problems")
}
#endif
