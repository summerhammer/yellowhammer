import Pulse
import SwiftUI

/// The entries either side of the playhead as a log, the playhead a row of its own. The entries up to the
/// playhead read in full, the ones after it dimmed.
struct NightLog: View {
    let moment: NightMoment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(moment.before(6)) { NightLogRow(item: $0, isAfter: false) }
            playheadRow
            ForEach(moment.after(4)) { NightLogRow(item: $0, isAfter: true) }
        }
        .font(.system(.callout, design: .monospaced))
        .background(.surface, in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var playheadRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill")
                .font(.caption2)
                .accessibilityHidden(true)
            Text(moment.time.nightClock).monospacedDigit()
            Text("playhead")
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.accentColor)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("night-account-log-playhead")
    }
}

/// One entry: the time, the run's Act, a problem mark, the headline over the detail. A problem carries the
/// warning mark, and its headline says what happened, so colour is never the only signal.
struct NightLogRow: View {
    let item: NightTimeline.Item
    let isAfter: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.entry.occurredAt.nightClock)
                .foregroundStyle(.secondary)
            Text((item.run.act ?? "none").uppercased())
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(item.run.outcome.style)
                .frame(width: 52, alignment: .leading)
            problemMark
            VStack(alignment: .leading, spacing: 1) {
                Text(item.entry.headline)
                if let detail = item.entry.detail {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(isAfter ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("night-account-entry-\(item.entry.id)")
    }

    /// Always laid out, so the headlines line up; only a problem's is shown and read.
    @ViewBuilder private var problemMark: some View {
        if item.entry.isProblem {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.warning)
                .accessibilityLabel("Problem")
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}
