import Pulse
import SwiftUI

/// Every entry of the Night as a log that fills the height it is given and scrolls on its own, the playhead a
/// row of its own among them. The entries up to the playhead read in full, the ones after it dimmed. The log
/// keeps the playhead row in view as the playhead moves; choosing an entry moves the playhead to it and marks
/// the entry as chosen.
struct NightLog: View {
    let moment: NightMoment
    @Binding var playhead: Date
    /// The entry last chosen in the log. Shown as chosen only while the playhead stays on its time.
    @State private var chosen: (id: NightTimeline.Item.ID, at: Date)?

    private static let playheadID = "night-log-playhead"

    private var items: [NightTimeline.Item] { moment.timeline.items }

    /// The chosen entry, while the playhead is still on it.
    private var selection: NightTimeline.Item.ID? {
        guard let chosen, chosen.at == moment.time else { return nil }
        return chosen.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(moment.before(items.count)) { row($0, isAfter: false) }
                    playheadRow.id(Self.playheadID)
                    ForEach(moment.after(items.count)) { row($0, isAfter: true) }
                }
            }
            .onAppear { proxy.scrollTo(Self.playheadID, anchor: .center) }
            .onChange(of: moment.time) {
                // An entry chosen here is already in view: recentring would move it out from under the pointer.
                if selection == nil { proxy.scrollTo(Self.playheadID, anchor: .center) }
            }
        }
        .frame(minHeight: 160, maxHeight: .infinity)
        .font(.system(.callout, design: .monospaced))
        .background(.surface, in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func row(_ item: NightTimeline.Item, isAfter: Bool) -> some View {
        Button {
            chosen = (item.id, item.entry.occurredAt)
            playhead = item.entry.occurredAt
        } label: {
            NightLogRow(item: item, isAfter: isAfter)
        }
        .buttonStyle(NightLogRowStyle(isSelected: selection == item.id))
        .accessibilityAddTraits(selection == item.id ? .isSelected : [])
        .accessibilityIdentifier("night-account-entry-\(item.entry.id)")
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

/// A log row as a button: the whole row takes the click, a chosen row is tinted in the accent, and a row
/// being pressed is shaded.
private struct NightLogRowStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .background {
                if isSelected {
                    Color.accentColor.opacity(0.18)
                } else if configuration.isPressed {
                    Color.primary.opacity(0.06)
                }
            }
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
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(isAfter ? 0.5 : 1)
        .accessibilityElement(children: .combine)
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
