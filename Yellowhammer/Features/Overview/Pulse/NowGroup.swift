import Domain
import Pulse
import SwiftUI

/// The Pulse's Now group: the Project's `idle`/`working` status, the next scheduled Act, and the running
/// Attempts with a one-line status each. An Attempt opens in the Inspector.
///
/// Neither the next Act nor an Attempt's status line is in the Journal, so a snapshot read from it
/// leaves both nil. The group says so rather than inventing one; it never fills them from app-side
/// state.
struct NowGroup: View {
    let now: Now
    let asOf: Date
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                NowStatusLine(status: now.status, nextAct: now.nextAct)
                if now.attempts.isEmpty {
                    Label("No Attempt running", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("now-absence")
                } else {
                    ForEach(now.attempts) { attempt in
                        Button { openDestination(.inspector(.attempt(attempt.id))) } label: {
                            RunningAttemptRow(attempt: attempt, asOf: asOf)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("now-attempt-\(attempt.id)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Now", systemImage: "clock")
        }
        .accessibilityIdentifier("pulse-now")
    }
}

/// `idle — next Act author 01:30`; without a scheduled Act the line says it is unknown.
private struct NowStatusLine: View {
    let status: ProjectStatus
    let nextAct: ScheduledAct?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status == .working ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(status.rawValue).fontWeight(.medium)
            Text("\u{2014}").foregroundStyle(.secondary)
            if let next = nextAct {
                Text("next Act \(next.act.rawValue) \(next.at.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            } else {
                Text("next Act unknown").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("now-status")
    }
}

/// One running Attempt with its one-line status. Elapsed time is measured to `asOf`, not to the clock.
private struct RunningAttemptRow: View {
    let attempt: RunningAttempt
    let asOf: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.2.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(attempt.cardID)  \(attempt.cardTitle)").lineLimit(1)
                Text(attempt.detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(attempt.elapsed(asOf: asOf)).monospacedDigit()
                Text("Round \(attempt.round)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

// MARK: For display

private extension RunningAttempt {
    /// The Repo, route and one-line status the Attempt has, in that order.
    var detailLine: String {
        [repo, route, status].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// Time since the Attempt started, measured to `asOf`, not to the clock.
    func elapsed(asOf: Date) -> String {
        Duration.seconds(max(0, asOf.timeIntervalSince(startedAt)))
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}
