import Domain
import Pulse
import SwiftUI

/// The Pulse's Tonight / last Night group: `verdict_line`, `cards_by_disposition` counts, and the
/// Night's state (running / done / halted / starved). Opens the Night Card — the decision itself stays in
/// Linear. Per the spec story `app/land-on-the-sidebar-and-pulse`, every Pulse element opens its selection
/// in the Inspector, so a second link selects the Night's account (OQ158 ruling item 14): its Journal events,
/// along a playhead, take the Pulse's place in the main area, and the Inspector shows the Night's facts and
/// its way out to the Night Card.
///
/// The Journal read supplies a factual failure count; a full Night Summary remains unknown. Under the verdict,
/// each Failure Notice no later run recovered gets a line that opens the Night's account at the notice's first
/// event (spec: morning-report/disclose-a-failure).
struct NightGroup: View {
    let night: NightPulse?
    /// The window Config schedules; what an absent Night says instead of a bare "No Night yet".
    var scheduled: ScheduledNight?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        PulseCard(group: .night, summary: PulseGroup.summary(of: night, scheduled: scheduled)) {
            if let night {
                if let link = night.nightCard {
                    Button { openDestination(.nightCard(link.url)) } label: {
                        HStack {
                            Text(night.displayVerdict).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(link.identifier) in Linear")
                    .accessibilityIdentifier("night-card-link")
                } else {
                    // No recorded link yet: the verdict is plain content, never a way out that goes nowhere.
                    HStack {
                        Text(night.displayVerdict).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                    }
                    .help("The Night Card's link is recorded when the engine next reads the board")
                    .accessibilityIdentifier("night-card-verdict")
                }
                ForEach(night.failureNotices.filter { !$0.isRecovered }) { notice in
                    Button {
                        openDestination(.nightAccount(night.id, at: notice.firstOccurredAt))
                    } label: {
                        Label(notice.displayLine, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Show it in the Night\u{2019}s account")
                    .accessibilityIdentifier("night-failure-notice")
                }
                if let skip = night.stackFullSkip {
                    StackFullSkipRow(night: night.id, skip: skip)
                }
                HStack(spacing: 8) {
                    PulseCountBadge(text: night.state.rawValue, style: night.state.style)
                    Text("started \(night.startedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("night-state")
                if night.cardsByDisposition.isEmpty {
                    Text(night.cardsAbsence).foregroundStyle(.secondary)
                } else {
                    NightDispositionCounts(counts: night.cardsByDisposition)
                }
                Button("Show the Night\u{2019}s account") {
                    openDestination(.inspector(.night(night.id)))
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("night-account-link")
            } else {
                Label("No Night yet", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("night-absence")
                if scheduled?.isOpen == true {
                    // The window is open but nothing is recorded: the account has no Journal id to open, so
                    // the Inspector shows the schedule and says so.
                    Button("Show the Night\u{2019}s account") {
                        openDestination(.inspector(.scheduledNight))
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("night-account-link")
                }
            }
            if let scheduled {
                if night?.state != .running {
                    Label(scheduled.detailLine, systemImage: "clock")
                        .accessibilityIdentifier("night-scheduled")
                }
                if let notice = scheduled.schedulerNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("night-scheduler-notice")
                }
            }
        }
        .accessibilityIdentifier("pulse-night")
    }
}

/// An author firing that authored nothing because the unmerged Feature stack was full (proposed amendment,
/// yellowhammer-spec#132). It opens the Night's account at the skip; it is a quiet Night, not a failure, so it
/// wears no warning symbol and never stands in for `cardsAbsence`.
private struct StackFullSkipRow: View {
    let night: Int64
    let skip: StackFullSkip
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        Button { openDestination(.nightAccount(night, at: skip.at)) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(line, systemImage: "square.stack.3d.up")
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                Text("\(skip.features.joined(separator: ", ")) await merge. A quiet Night, not a failure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show it in the Night\u{2019}s account")
        .accessibilityIdentifier("night-stack-full-skip")
    }

    /// `Authored nothing — … is full (2 of 2) · 03:10`, with `· 3 times` when several firings skipped.
    private var line: String {
        let time = skip.at.formatted(date: .omitted, time: .shortened)
        let times = skip.count > 1 ? " \u{00B7} \(skip.count) times" : ""
        let stack = "\(skip.features.count) of \(skip.unmergedFeaturesMax)"
        return "\(StackFullSkip.headline) (\(stack)) \u{00B7} \(time)\(times)"
    }
}

/// Cards touched this Night, counted by disposition, in the order the read already ranks them.
private struct NightDispositionCounts: View {
    let counts: [DispositionCount]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(counts) { entry in
                Label {
                    Text(entry.displayCount).monospacedDigit()
                } icon: {
                    Circle().fill(entry.disposition.style).frame(width: 7, height: 7)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("night-dispositions")
    }
}

// MARK: For display

private extension NightPulse {
    /// `verdict_line`, or a stated unknown while it is nil (only Engine's `NightSummary` computes it).
    var displayVerdict: String { verdictLine ?? "verdict unknown" }
}

private extension FailureNotice {
    /// `Authoring “X” failed: over the description budget`, with `· 5 times, 14:00–14:21` when the notice
    /// folds more than one run.
    var displayLine: String {
        guard count > 1 else { return headline }
        let first = firstOccurredAt.formatted(date: .omitted, time: .shortened)
        let last = lastOccurredAt.formatted(date: .omitted, time: .shortened)
        return "\(headline) · \(count) times, \(first)\u{2013}\(last)"
    }
}

private extension DispositionCount {
    /// `6 Done`, its count and disposition.
    var displayCount: String { "\(count) \(disposition.rawValue)" }
}
