#if DEBUG
import Pulse
import SwiftUI

// The shipped Night Editor around a Timeline design: the Project's name, the viewer, the transport, then the
// strip under test. The viewer and transport are the app's, so a design is judged on its strip alone.

/// The editor with `strip` docked at the bottom, inside the main window.
struct NightEditorFrame<Strip: View>: View {
    let timeline: NightTimeline
    @Binding var playhead: Date
    @ViewBuilder let strip: () -> Strip

    private var moment: NightMoment { timeline.moment(at: playhead) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Yellowhammer")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            ScrollView {
                NightViewer(moment: moment)
                    .padding([.horizontal, .bottom], 20)
                    .padding(.top, 6)
            }
            Divider()
            NightTransport(moment: moment, playhead: $playhead)
            Divider()
            strip()
        }
    }
}

// MARK: - Viewer

/// The app's `NightEditorViewer`: the Night's title and state, the clock, one tile per Act, and the log.
struct NightViewer: View {
    let moment: NightMoment

    private var account: NightAccount { moment.timeline.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(account.title).font(.title2.bold()).lineLimit(1)
                NightStateBadges(account: account)
                Spacer(minLength: 8)
                Text(moment.time.clockTime)
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(moment.acts) { NightActTile(state: $0) }
            }
            NightLog(moment: moment)
        }
    }
}

struct NightActTile: View {
    let state: NightMoment.ActState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(state.tint).frame(width: 8, height: 8)
                Text(state.name).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Text(state.isInside ? "in a run" : "between runs")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(state.tint.opacity(state.isInside ? 0.2 : 0.08), in: .capsule)
            }
            Text(state.words)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(state.tint.opacity(state.isInside ? 0.1 : 0.04), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(state.tint.opacity(state.isInside ? 0.6 : 0.2)))
    }
}

struct NightLog: View {
    let moment: NightMoment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(moment.before(6)) { row($0, isAfter: false) }
            HStack(spacing: 8) {
                Image(systemName: "play.fill").font(.caption2)
                Text(moment.time.clockTime).monospacedDigit()
                Text("playhead")
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(NightTheme.accent)
            ForEach(moment.after(4)) { row($0, isAfter: true) }
        }
        .font(.system(.callout, design: .monospaced))
        .background(NightTheme.surface, in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func row(_ item: NightTimeline.Item, isAfter: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.entry.occurredAt.clockTime).foregroundStyle(.secondary)
            Text((item.run.act ?? "none").uppercased())
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(item.run.outcome.tint)
                .frame(width: 52, alignment: .leading)
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(NightTheme.warning)
                .opacity(item.entry.isProblem ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.entry.headline)
                if let detail = item.entry.detail { Text(detail).foregroundStyle(.secondary) }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(isAfter ? 0.5 : 1)
    }
}

// MARK: - Transport

/// The app's `NightEditorTransport`: five minutes or a problem at a time, beside the count and the span.
struct NightTransport: View {
    let moment: NightMoment
    @Binding var playhead: Date

    var body: some View {
        HStack(spacing: 14) {
            Button("Previous problem", systemImage: "backward.end.fill") { go(to: moment.previousProblem) }
                .disabled(moment.previousProblem == nil)
            Button("Back 5 minutes", systemImage: "gobackward.5") { playhead = moment.moved(by: -300) }
            Button("Forward 5 minutes", systemImage: "goforward.5") { playhead = moment.moved(by: 300) }
            Button("Next problem", systemImage: "forward.end.fill") { go(to: moment.nextProblem) }
                .disabled(moment.nextProblem == nil)
            Spacer(minLength: 8)
            Text(problemCount).lineLimit(1).fixedSize().foregroundStyle(.secondary)
            Text(moment.timeline.scale.words).monospacedDigit().lineLimit(1).fixedSize().foregroundStyle(.secondary)
        }
        .font(.title3)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func go(to time: Date?) {
        if let time { playhead = time }
    }

    private var problemCount: String {
        switch moment.timeline.problemTimes.count {
        case 0: "No problems"
        case 1: "1 problem"
        case let count: "\(count) problems"
        }
    }
}
#endif
