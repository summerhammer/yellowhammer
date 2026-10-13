#if DEBUG
import Pulse
import SwiftUI

// B · Navigator. Two scales, the way Final Cut pairs its timeline with a navigator: a strip of the whole
// Night above, with a framed window over the stretch in view, and the lanes drawn at the window's scale
// below, close enough that every entry shows as a tick on its run's bar. A segmented control picks the
// window's span; drag the frame to pan. The window follows the playhead when a step leaves it behind.

enum NavigatorZoom: String, CaseIterable, Identifiable {
    case night = "Night"
    case twoHours = "2 h"
    case halfHour = "30 min"

    var id: Self { self }

    /// The window's span; nil for the whole Night.
    var span: TimeInterval? {
        switch self {
        case .night: nil
        case .twoHours: 2 * 3_600
        case .halfHour: 30 * 60
        }
    }
}

struct NavigatorTimeline: View {
    let timeline: NightTimeline
    @Binding var playhead: Date
    @State private var zoom: NavigatorZoom
    @State private var windowStart: Date

    private let labelWidth: CGFloat = 64
    private let laneHeight: CGFloat = 26
    private let rulerHeight: CGFloat = 24
    private let overviewHeight: CGFloat = 26

    init(timeline: NightTimeline, playhead: Binding<Date>, zoom: NavigatorZoom = .twoHours) {
        self.timeline = timeline
        _playhead = playhead
        _zoom = State(initialValue: zoom)
        _windowStart = State(
            initialValue: Self.start(centredOn: playhead.wrappedValue, span: zoom.span, in: timeline.scale)
        )
    }

    private var night: NightTimeScale { timeline.scale }

    /// The window's span, or nil when the zoom shows the whole Night anyway.
    private var windowSpan: TimeInterval? {
        guard let span = zoom.span, span < night.span else { return nil }
        return span
    }

    private var window: NightTimeScale {
        guard let span = windowSpan else { return night }
        return NightTimeScale(start: windowStart, end: windowStart.addingTimeInterval(span))
    }

    /// Whether the window is close enough to tell a run's entries apart.
    private var showsEntries: Bool { window.span <= 2 * 3_600 }

    private static func start(centredOn time: Date, span: TimeInterval?, in night: NightTimeScale) -> Date {
        guard let span, span < night.span else { return night.start }
        return clamp(time.addingTimeInterval(-span / 2), span: span, in: night)
    }

    private static func clamp(_ start: Date, span: TimeInterval, in night: NightTimeScale) -> Date {
        min(max(start, night.start), night.end.addingTimeInterval(-span))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                overview.frame(height: overviewHeight)
                Picker("Zoom", selection: $zoom) {
                    ForEach(NavigatorZoom.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.leading, labelWidth)
            VStack(alignment: .leading, spacing: 2) {
                ruler.padding(.leading, labelWidth)
                ForEach(timeline.account.lanes, id: \.self) { lane($0) }
            }
            .overlay { playheadLine }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.background.secondary)
        .onChange(of: zoom) { _, _ in
            windowStart = Self.start(centredOn: playhead, span: windowSpan, in: night)
        }
        .onChange(of: playhead) { _, time in
            guard let span = windowSpan, !window.contains(time) else { return }
            windowStart = Self.clamp(time.addingTimeInterval(-span / 2), span: span, in: night)
        }
        .nightPlayheadAccessibility(timeline: timeline, playhead: $playhead)
    }

    // MARK: Overview

    private var overview: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let lanes = timeline.account.lanes
            let rowHeight = (overviewHeight - 8) / CGFloat(lanes.count)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(NightTheme.surface)
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, act in
                    ForEach(timeline.runs(in: act, within: night)) { run in
                        let left = night.position(run.startedAt, length: width)
                        Capsule()
                            .fill(run.outcome.tint.opacity(run.outcome.isQuiet ? 0.4 : 0.85))
                            .frame(
                                width: max(3, night.position(run.lastAt, length: width) - left), height: rowHeight - 1
                            )
                            .offset(x: left, y: 4 + CGFloat(index) * rowHeight)
                    }
                }
                ForEach(Array(timeline.problemTimes.enumerated()), id: \.offset) { problem in
                    Rectangle()
                        .fill(NightTheme.warning)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .offset(x: night.position(problem.element, length: width) - 1)
                }
                if windowSpan != nil {
                    let left = night.position(window.start, length: width)
                    let right = night.position(window.end, length: width)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(NightTheme.accent.opacity(0.1))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(NightTheme.accent, lineWidth: 1.5))
                        .frame(width: max(right - left, 8))
                        .frame(maxHeight: .infinity)
                        .offset(x: left)
                }
                Rectangle()
                    .fill(NightTheme.accent)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .offset(x: night.position(playhead, length: width) - 0.75)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let time = night.date(at: drag.location.x, length: width)
                    if let span = windowSpan {
                        windowStart = Self.clamp(time.addingTimeInterval(-span / 2), span: span, in: night)
                    } else {
                        playhead = time
                    }
                }
            )
        }
    }

    // MARK: Detail

    private var minorTicks: [Date] {
        window.marks(every: window.span > 2 * 3_600 ? 900 : 300)
    }

    private var ruler: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(minorTicks, id: \.self) { tick in
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 1, height: 4)
                        .offset(x: window.position(tick, length: width), y: rulerHeight - 4)
                }
                ForEach(window.ticks, id: \.self) { tick in
                    let mark = window.position(tick, length: width)
                    Rectangle().fill(.secondary).frame(width: 1, height: 8).offset(x: mark, y: rulerHeight - 8)
                    if mark < width - 40 {
                        Text(tick.shortClock)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: mark + 3, y: 0)
                    }
                }
                ForEach(Array(timeline.problemTimes.enumerated()), id: \.offset) { problem in
                    if window.contains(problem.element) {
                        Circle()
                            .fill(NightTheme.warning)
                            .frame(width: 6, height: 6)
                            .offset(x: window.position(problem.element, length: width) - 3, y: rulerHeight - 7)
                    }
                }
                if window.contains(playhead) {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(NightTheme.accent)
                        .offset(x: window.position(playhead, length: width) - 5.5, y: rulerHeight - 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(.rect)
            .gesture(scrub(width: width))
        }
        .frame(height: rulerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
    }

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { drag in
            playhead = window.date(at: drag.location.x, length: width)
        }
    }

    private func lane(_ act: String?) -> some View {
        HStack(spacing: 0) {
            Text(NightAccount.laneLabel(act))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(.separator).frame(height: 1)
                    ForEach(timeline.runs(in: act, within: window)) { run in
                        bar(run, width: width)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(scrub(width: width))
            }
            .frame(height: laneHeight)
            .clipped()
        }
    }

    private func bar(_ run: NightAccount.ActRun, width: CGFloat) -> some View {
        let quiet = run.outcome.isQuiet
        let left = window.position(run.startedAt, length: width)
        let barWidth = max(10, window.position(run.lastAt, length: width) - left)
        let height: CGFloat = quiet ? 10 : 18
        return Capsule()
            .fill(run.outcome.tint.opacity(quiet ? 0.45 : 0.9))
            .frame(width: barWidth, height: height)
            .overlay {
                if showsEntries, !quiet {
                    ForEach(run.entries) { entry in
                        let mark = window.position(entry.occurredAt, length: width) - left
                        if mark > 3, mark < barWidth - 3 {
                            Rectangle()
                                .fill(.white.opacity(0.85))
                                .frame(width: 1.5, height: height - 8)
                                .position(x: mark, y: height / 2)
                        }
                    }
                }
            }
            .overlay(Capsule().strokeBorder(NightTheme.warning, lineWidth: run.hasProblem ? 2.5 : 0))
            .overlay(
                Capsule().strokeBorder(NightTheme.accent, lineWidth: run.contains(playhead) ? 2 : 0).padding(-3)
            )
            .help("\(run.title) \u{2014} \(run.outcome.words)")
            .offset(x: left)
    }

    private var playheadLine: some View {
        GeometryReader { geometry in
            if window.contains(playhead) {
                Rectangle()
                    .fill(NightTheme.accent)
                    .frame(width: 1.5, height: max(geometry.size.height - rulerHeight, 0))
                    .offset(
                        x: labelWidth + window.position(playhead, length: geometry.size.width - labelWidth) - 0.75,
                        y: rulerHeight
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview("B · Navigator") {
    NightTimelinePlayground(variant: "B \u{00B7} Navigator")
}

#Preview("B · Navigator, close up") {
    NightStripCloseUp(variant: "B \u{00B7} Navigator")
}
#endif
