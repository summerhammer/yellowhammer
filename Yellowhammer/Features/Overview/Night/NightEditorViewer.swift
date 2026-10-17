import Domain
import Pulse
import SwiftUI

/// The viewer at the top of the editor: the Night's title and state, the clock, one tile for each Act, and
/// the Night's log around the playhead.
///
/// The title and the clock share a row while they fit, and stack when they do not; the tiles wrap the same
/// way, so nothing overflows the narrowest the main area can be.
struct NightEditorViewer: View {
    let moment: NightMoment
    @Binding var playhead: Date

    private var account: NightAccount { moment.timeline.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(moment.acts) { NightActTile(state: $0) }
            }
            NightLog(moment: moment, playhead: $playhead)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titleAndState
                Spacer(minLength: 8)
                clock
            }
            VStack(alignment: .leading, spacing: 8) {
                titleAndState
                clock
            }
        }
    }

    private var titleAndState: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Night of \(account.nightStart)")
                .font(.title2.bold())
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("night-account-title")
            HStack(spacing: 6) {
                PulseCountBadge(text: account.state.rawValue, style: account.state.style)
                if account.mode == .rehearsal {
                    PulseCountBadge(text: "rehearsal", style: .secondary)
                }
            }
            .fixedSize()
        }
    }

    private var clock: some View {
        Text(moment.time.nightClock)
            .font(.system(size: 44, weight: .light, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("night-account-clock")
    }
}

/// What one Act was doing at the playhead's moment, as the account knows it: inside a run, or between
/// runs. Never "running": a run's last entry is all the account knows of it.
struct NightActTile: View {
    let state: NightMoment.ActState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(state.style).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(state.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(state.isInside ? "in a run" : "between runs")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(state.style.opacity(state.isInside ? 0.2 : 0.08), in: .capsule)
            }
            Text(state.words)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(state.style.opacity(state.isInside ? 0.1 : 0.04), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(state.style.opacity(state.isInside ? 0.6 : 0.2))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("night-account-act-\(state.id)")
    }
}
