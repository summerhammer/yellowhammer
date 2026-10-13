#if DEBUG
import Pulse
import SwiftUI

// Editor. Laid out like a video editor: the moment is the viewer at the top — a large clock, the three
// Acts as tiles, the entries either side as a log — a transport bar under it, and the Night's lanes docked at
// the bottom under a ruler with a triangular playhead head. Drag on the ruler to scrub; the transport steps
// five minutes or a problem at a time.

struct NightEditorVariant: View {
    let account: NightAccount
    @State private var playhead: Date

    private let labelWidth: CGFloat = 64

    init(account: NightAccount) {
        self.account = account
        _playhead = State(initialValue: NightMoment.opening(of: account))
    }

    private var moment: NightMoment { NightMoment(account: account, time: playhead) }

    var body: some View {
        NightAccountStage {
            VStack(spacing: 0) {
                ScrollView { viewer.padding(24) }
                Divider()
                transport
                Divider()
                timeline
            }
        } inspector: {
            NightFactsInspector(account: account)
        }
    }

    // MARK: Viewer

    private var viewer: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(account.title).font(.title2.bold())
                NightStateBadges(account: account)
                Spacer()
                Text(playhead.clockTime)
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(moment.acts) { tile($0) }
            }
            log
        }
    }

    private func tile(_ state: NightMoment.ActState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(state.tint).frame(width: 8, height: 8)
                Text(state.name).font(.headline)
                Spacer()
                Text(state.isInside ? "in a run" : "between runs")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(state.tint.opacity(state.isInside ? 0.2 : 0.08), in: .capsule)
            }
            Text(state.words).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(state.tint.opacity(state.isInside ? 0.1 : 0.04), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(state.tint.opacity(state.isInside ? 0.6 : 0.2))
        )
    }

    /// The entries either side of the playhead as a log, the playhead a row of its own.
    private var log: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(moment.before(6)) { row($0, isAfter: false) }
            HStack(spacing: 8) {
                Image(systemName: "play.fill").font(.caption2)
                Text(playhead.clockTime).monospacedDigit()
                Text("playhead")
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(NightTheme.accent)
            ForEach(moment.after(4)) { row($0, isAfter: true) }
        }
        .font(.system(.callout, design: .monospaced))
        .background(NightTheme.surface)
        .clipShape(.rect(cornerRadius: 10))
    }

    private func row(_ item: NightMoment.Item, isAfter: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.entry.time).foregroundStyle(.secondary)
            Text((item.run.act ?? "none").uppercased())
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(item.run.outcome.tint)
                .frame(width: 52, alignment: .leading)
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(NightTheme.attention)
                .opacity(item.entry.isProblem ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.entry.headline)
                if let detail = item.entry.detail { Text(detail).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(isAfter ? 0.5 : 1)
        .textSelection(.enabled)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 14) {
            Button("Previous problem", systemImage: "backward.end.fill") {
                moment.previousProblem.map { playhead = $0 }
            }
            .disabled(moment.previousProblem == nil)
            Button("Back 5 minutes", systemImage: "gobackward.5") { playhead = moment.moved(by: -300) }
            Button("Forward 5 minutes", systemImage: "goforward.5") { playhead = moment.moved(by: 300) }
            Button("Next problem", systemImage: "forward.end.fill") { moment.nextProblem.map { playhead = $0 } }
                .disabled(moment.nextProblem == nil)
            Spacer()
            Text(moment.problemTimes.isEmpty ? "No problems" : "\(moment.problemTimes.count) problems")
                .foregroundStyle(.secondary)
            Text(account.span).monospacedDigit().foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 2) {
            ruler
            NightLanes(
                account: account,
                selection: Binding(
                    get: { moment.runUnderPlayhead?.id },
                    set: { id in account.runs.first { $0.id == id }.map { playhead = $0.startedAt } }
                ),
                laneHeight: 28,
                labelWidth: labelWidth
            )
            .overlay { playheadLine.allowsHitTesting(false) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.background.secondary)
    }

    /// A tick every quarter hour, taller on the hour, and the playhead's triangular head.
    private var ruler: some View {
        GeometryReader { geometry in
            let length = geometry.size.width
            let scale = moment.scale
            ZStack(alignment: .topLeading) {
                ForEach(quarterHours(scale), id: \.self) { tick in
                    let onHour = Calendar.current.component(.minute, from: tick) == 0
                    Rectangle().fill(.secondary)
                        .frame(width: 1, height: onHour ? 10 : 5)
                        .offset(x: scale.position(tick, length: length), y: onHour ? 8 : 13)
                }
                ForEach(moment.problemTimes, id: \.self) { time in
                    Circle().fill(NightTheme.attention).frame(width: 5, height: 5)
                        .offset(x: scale.position(time, length: length) - 2.5, y: 2)
                }
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(NightTheme.accent)
                    .offset(x: scale.position(playhead, length: length) - 6.5, y: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    playhead = scale.date(at: drag.location.x, length: length)
                }
            )
        }
        .frame(height: 20)
        .padding(.leading, labelWidth)
        .nightPlayheadAccessibility(account: account, playhead: $playhead)
    }

    private func quarterHours(_ scale: NightTimeScale) -> [Date] {
        var tick = Calendar.current.dateInterval(of: .hour, for: scale.start)?.start ?? scale.start
        var ticks: [Date] = []
        while tick < scale.end {
            if tick > scale.start { ticks.append(tick) }
            tick = tick.addingTimeInterval(900)
        }
        return ticks
    }

    private var playheadLine: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(NightTheme.accent)
                .frame(width: 1.5, height: geometry.size.height - 14)
                .offset(x: labelWidth + moment.scale.position(playhead, length: geometry.size.width - labelWidth))
        }
    }
}

#Preview("Editor") {
    NightAccountPlayground(variant: "Editor")
}
#endif
